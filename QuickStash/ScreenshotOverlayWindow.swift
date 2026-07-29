@preconcurrency import AppKit
import CoreGraphics

struct ScreenshotCanvasSnapshot: @unchecked Sendable {
    let source: CGImage
    let crop: PixelRect
    let annotations: [ScreenshotAnnotation]
    let cornerRadius: Int
    let displayID: CGDirectDisplayID
    let generation: UInt64

    init(
        source: CGImage,
        crop: PixelRect,
        annotations: [ScreenshotAnnotation],
        cornerRadius: Int = 0,
        displayID: CGDirectDisplayID,
        generation: UInt64
    ) {
        self.source = source
        self.crop = crop
        self.annotations = annotations
        self.cornerRadius = ScreenshotCropStylePolicy.clampedCornerRadius(
            cornerRadius,
            for: crop
        )
        self.displayID = displayID
        self.generation = generation
    }

    // Compatibility names keep rendering call sites explicit without duplicating state.
    var sourceImage: CGImage { source }
    var cropRect: PixelRect { crop }

    var isValid: Bool {
        !crop.isEmpty
            && crop.minX >= 0
            && crop.minY >= 0
            && crop.maxX <= source.width
            && crop.maxY <= source.height
    }
}

@MainActor
protocol ScreenshotCanvasDelegate: AnyObject {
    func screenshotCanvasDidActivate(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot?
    )
    func screenshotCanvasDidMutate(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot?
    )
    func screenshotCanvasDidRequestCancel(
        canvas: ScreenshotCanvasView,
        generation: UInt64
    )
    func screenshotCanvasDidRequestCopy(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot
    )
    func screenshotCanvasDidRequestSave(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot,
        format: ScreenshotOutputFormat
    )
}

@MainActor
final class ScreenshotOverlayController {
    let window: ScreenshotOverlayWindow
    let canvas: ScreenshotCanvasView

    init(
        capture: CapturedDisplay,
        screen: NSScreen,
        generation: UInt64,
        delegate: any ScreenshotCanvasDelegate
    ) {
        canvas = ScreenshotCanvasView(
            source: capture.image,
            displayID: capture.displayID,
            generation: generation,
            windowRegions: capture.windowRegions,
            delegate: delegate
        )
        window = ScreenshotOverlayWindow(screen: screen, canvas: canvas)
    }

    func show(makeKey: Bool) {
        window.setFrame(window.targetScreen.frame, display: true)
        if makeKey {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(canvas)
        } else {
            window.orderFrontRegardless()
        }
    }

    func close() {
        canvas.finishEditingBeforeDismissal()
        window.orderOut(nil)
        window.close()
    }

    func setActive(_ active: Bool) {
        canvas.setDisplayActive(active)
    }
}

@MainActor
final class ScreenshotOverlayWindow: NSPanel {
    let targetScreen: NSScreen

    init(screen: NSScreen, canvas: ScreenshotCanvasView) {
        targetScreen = screen
        // NSWindow's screen-specific initializer is a convenience initializer that re-enters
        // the subclass designated initializer and traps when this stored property is present.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        contentView = canvas
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ScreenshotCanvasView: NSView, NSTextViewDelegate {
    private enum Interaction {
        case none
        case pendingWindowSelection(
            anchorView: CGPoint,
            anchorPixel: PixelPoint,
            candidate: ScreenshotWindowRegion
        )
        case pendingOutsideCompletion(anchorView: CGPoint, anchorPixel: PixelPoint)
        case selectingCrop(anchor: PixelPoint)
        case movingCrop(anchor: PixelPoint, original: PixelRect)
        case resizingCrop(handle: ScreenshotResizeHandle, original: PixelRect)
        case drawingAnnotation(kind: ScreenshotAnnotationKind, anchor: PixelPoint)
        case movingAnnotation(id: UUID, anchor: PixelPoint, original: ScreenshotAnnotation)
        case resizingAnnotation(
            id: UUID,
            handle: ScreenshotResizeHandle,
            original: ScreenshotAnnotation
        )
        case movingArrowEndpoint(
            id: UUID,
            isStart: Bool,
            original: ScreenshotAnnotation
        )
    }

    private struct TextEditingState {
        let annotationID: UUID
        let original: ScreenshotAnnotation?
    }

    private let source: CGImage
    private let displayID: CGDirectDisplayID
    private let windowRegions: [ScreenshotWindowRegion]
    let generation: UInt64
    private weak var delegate: (any ScreenshotCanvasDelegate)?
    private let sourceImage: NSImage
    private var mosaicPreviewImage: NSImage?
    private var mosaicPreviewTask: Task<Void, Never>?
    private var mosaicPreviewRevision: UInt64 = 0
    private let toolbar = ScreenshotToolbarView()

    private var history = ScreenshotEditHistory(maximumDepth: 100)
    private var crop: PixelRect = .zero
    private var cropLocked = false
    private var selectedAnnotationID: UUID?
    private var tool: ScreenshotTool = .select
    private var color: ScreenshotColor = .red
    private var lineWidth = ScreenshotAnnotationStylePolicy.defaultLineWidth
    private var lineWidthAdjustment: ScreenshotLineWidthAdjustment?
    private var cornerRadiusAdjustment: ScreenshotCornerRadiusAdjustment?
    private var interaction: Interaction = .none
    private var workingAnnotations: [ScreenshotAnnotation]?
    private var draftAnnotation: ScreenshotAnnotation?
    private var textEditor: NSTextView?
    private var textEditingState: TextEditingState?
    private var isFinishingTextEditing = false
    private var suppressMutationNotifications = false
    private var isDisplayActive = true
    private var pointerPixel: PixelPoint?
    private var hoveredWindowRegion: ScreenshotWindowRegion?
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var snapshot: ScreenshotCanvasSnapshot {
        ScreenshotCanvasSnapshot(
            source: source,
            crop: crop,
            annotations: displayedAnnotations,
            cornerRadius: displayedCornerRadius,
            displayID: displayID,
            generation: generation
        )
    }

    private var imageSize: PixelSize {
        PixelSize(width: source.width, height: source.height)
    }

    private var displayedAnnotations: [ScreenshotAnnotation] {
        lineWidthAdjustment?.previewAnnotations ?? workingAnnotations ?? history.annotations
    }

    private var displayedCornerRadius: Int {
        ScreenshotCropStylePolicy.clampedCornerRadius(
            cornerRadiusAdjustment?.previewCornerRadius ?? history.cornerRadius,
            for: crop
        )
    }

    init(
        source: CGImage,
        displayID: CGDirectDisplayID,
        generation: UInt64,
        windowRegions: [ScreenshotWindowRegion] = [],
        delegate: any ScreenshotCanvasDelegate
    ) {
        self.source = source
        self.displayID = displayID
        self.generation = generation
        self.windowRegions = windowRegions.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.windowID < rhs.windowID
        }
        self.delegate = delegate
        sourceImage = NSImage(
            cgImage: source,
            size: NSSize(width: source.width, height: source.height)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        toolbar.canvas = self
        updateToolbar()
        let initialToolbarSize = toolbar.fittingSize
        toolbar.frame = NSRect(
            x: 0,
            y: 0,
            width: max(44, initialToolbarSize.width),
            height: max(42, initialToolbarSize.height)
        ).integral
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

#if DEBUG
    func installTestingState(
        crop: PixelRect,
        annotations: [ScreenshotAnnotation],
        selectedAnnotationID: UUID?,
        tool: ScreenshotTool = .select,
        cornerRadius: Int = 0
    ) {
        self.crop = crop
        cropLocked = !annotations.isEmpty
        history = ScreenshotEditHistory(maximumDepth: 100)
        history.reset(
            annotations: annotations,
            cornerRadius: ScreenshotCropStylePolicy.clampedCornerRadius(cornerRadius, for: crop)
        )
        self.selectedAnnotationID = selectedAnnotationID
        self.tool = tool
        lineWidthAdjustment = nil
        cornerRadiusAdjustment = nil
        workingAnnotations = nil
        repairSelection()
        synchronizeStyleWithSelection()
        updateInterface()
    }

    var testingLineWidth: Int { lineWidth }
    var testingUndoDepth: Int { history.undoStack.count }
    var testingIsAdjustingLineWidth: Bool { lineWidthAdjustment != nil }
    var testingCornerRadius: Int { displayedCornerRadius }
    var testingIsAdjustingCornerRadius: Bool { cornerRadiusAdjustment != nil }
    var testingSelectedAnnotationID: UUID? { selectedAnnotationID }
    var testingIsDisplayActive: Bool { isDisplayActive }
    var testingIsToolbarHidden: Bool { toolbar.isHidden }
#endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        layoutToolbar()
        layoutTextEditor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !bounds.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()

        let visibleCrop = crop.isEmpty ? hoveredWindowRegion?.pixelRect ?? .zero : crop
        let visibleCornerRadius = crop.isEmpty
            ? hoveredWindowRegion?.cornerRadius ?? 0
            : displayedCornerRadius
        drawMask(selection: visibleCrop, cornerRadius: visibleCornerRadius)
        guard !visibleCrop.isEmpty else { return }

        if crop.isEmpty {
            let previewRect = viewRect(from: visibleCrop).insetBy(dx: 1, dy: 1)
            let preview = roundedPath(
                rect: previewRect,
                cornerRadius: max(0, viewCornerRadius(visibleCornerRadius) - 1)
            )
            preview.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            preview.stroke()
            return
        }

        let cropRect = viewRect(from: crop)
        NSGraphicsContext.saveGraphicsState()
        roundedPath(
            rect: cropRect,
            cornerRadius: viewCornerRadius(displayedCornerRadius)
        ).addClip()
        for annotation in displayedAnnotations {
            draw(annotation)
        }
        if let draftAnnotation {
            draw(draftAnnotation)
        }
        NSGraphicsContext.restoreGraphicsState()

        drawCropBorder(cropRect, cornerRadius: displayedCornerRadius)
        drawMeasurementBadge(near: cropRect)
        if let selected = selectedAnnotation {
            drawSelection(for: selected)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerPixel = pixelPoint(for: event)
        if crop.isEmpty, let pointerPixel {
            hoveredWindowRegion = windowRegion(at: pointerPixel)
        } else {
            hoveredWindowRegion = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerPixel = nil
        hoveredWindowRegion = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let wasDisplayActive = isDisplayActive
        let stylePopoverWasShown = toolbar.isStylePopoverShown
        toolbar.dismissStylePopover()
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        let viewLocation = convert(event.locationInWindow, from: nil)
        let point = pixelPoint(for: event)
        delegate?.screenshotCanvasDidActivate(canvas: self, snapshot: snapshot)
        guard !stylePopoverWasShown else {
            updateInterface()
            return
        }

        if crop.isEmpty {
            selectedAnnotationID = nil
            if let candidate = windowRegion(at: point) {
                interaction = .pendingWindowSelection(
                    anchorView: viewLocation,
                    anchorPixel: point,
                    candidate: candidate
                )
            } else {
                interaction = .selectingCrop(anchor: point)
                crop = PixelRect(x: point.x, y: point.y, width: 0, height: 0)
                resetCornerRadiusForCropChange(0)
            }
            updateInterface()
            return
        }

        if tool == .select,
           event.clickCount >= 2,
           containsCropContent(point),
           hitTestAnnotation(at: point) == nil {
            requestCopy()
            return
        }

        if let selected = selectedAnnotation,
           let isStart = arrowEndpoint(at: event.locationInWindow, for: selected) {
            interaction = .movingArrowEndpoint(id: selected.id, isStart: isStart, original: selected)
            workingAnnotations = history.annotations
            return
        }

        if let selected = selectedAnnotation,
           selected.kind != .arrow,
           let handle = annotationHandle(at: event.locationInWindow, for: selected) {
            interaction = .resizingAnnotation(id: selected.id, handle: handle, original: selected)
            workingAnnotations = history.annotations
            return
        }

        if tool == .select,
           !cropLocked,
           let handle = cropHandle(at: event.locationInWindow) {
            interaction = .resizingCrop(handle: handle, original: crop)
            return
        }

        if !containsCropContent(point) {
            // Switching back to a display must not reuse that activation click as a
            // destructive outside-click completion for its existing crop.
            guard wasDisplayActive else {
                updateInterface()
                return
            }
            interaction = .pendingOutsideCompletion(
                anchorView: viewLocation,
                anchorPixel: point
            )
            updateInterface()
            return
        }

        switch tool {
        case .select:
            handleSelectionMouseDown(event: event, point: point)
        case .text:
            guard containsCropContent(point) else { return }
            if let hit = hitTestAnnotation(at: point), hit.kind == .text {
                adoptStyle(of: hit)
                selectedAnnotationID = hit.id
                beginTextEditing(hit)
            } else {
                selectedAnnotationID = nil
                beginNewTextEditing(at: point)
            }
        case .arrow, .rectangle, .mosaic, .freehand:
            guard containsCropContent(point), let kind = annotationKind(for: tool) else { return }
            selectedAnnotationID = nil
            interaction = .drawingAnnotation(kind: kind, anchor: point)
            draftAnnotation = makeAnnotation(kind: kind, start: point, end: point)
            updateInterface()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewLocation = convert(event.locationInWindow, from: nil)
        let point = pixelPoint(for: event)
        switch interaction {
        case .none:
            return
        case let .pendingWindowSelection(anchorView, anchorPixel, _):
            guard !ScreenshotGeometry.isClickGesture(from: anchorView, to: viewLocation) else { return }
            selectedAnnotationID = nil
            hoveredWindowRegion = nil
            interaction = .selectingCrop(anchor: anchorPixel)
            crop = PixelRect(from: anchorPixel, to: point)
            resetCornerRadiusForCropChange(0)
        case let .pendingOutsideCompletion(anchorView, anchorPixel):
            guard !ScreenshotGeometry.isClickGesture(from: anchorView, to: viewLocation) else { return }
            guard !cropLocked else {
                interaction = .none
                return
            }
            selectedAnnotationID = nil
            interaction = .selectingCrop(anchor: anchorPixel)
            crop = PixelRect(from: anchorPixel, to: point)
            resetCornerRadiusForCropChange(0)
        case let .selectingCrop(anchor):
            crop = PixelRect(from: anchor, to: point)
        case let .movingCrop(anchor, original):
            crop = original.translated(
                dx: point.x - anchor.x,
                dy: point.y - anchor.y,
                within: imageSize
            )
        case let .resizingCrop(handle, original):
            crop = ScreenshotGeometry.resizing(
                original,
                handle: handle,
                to: point,
                within: imageSize,
                minimumSize: 2
            )
        case let .drawingAnnotation(kind, anchor):
            let endpoint = clampedToCrop(point)
            if kind == .freehand {
                appendFreehandPoint(endpoint)
            } else {
                draftAnnotation = makeAnnotation(kind: kind, start: anchor, end: endpoint)
            }
        case let .movingAnnotation(id, anchor, original):
            replaceWorkingAnnotation(
                id: id,
                with: original.translated(
                    dx: point.x - anchor.x,
                    dy: point.y - anchor.y,
                    within: crop
                )
            )
        case let .resizingAnnotation(id, handle, original):
            replaceWorkingAnnotation(
                id: id,
                with: resizedAnnotation(original, handle: handle, to: clampedToCrop(point))
            )
        case let .movingArrowEndpoint(id, isStart, original):
            var updated = original
            if isStart {
                updated.start = clampedToCrop(point)
            } else {
                updated.end = clampedToCrop(point)
            }
            replaceWorkingAnnotation(id: id, with: updated)
        }
        updateInterface()
    }

    override func mouseUp(with event: NSEvent) {
        let completedInteraction = interaction
        interaction = .none
        let viewLocation = convert(event.locationInWindow, from: nil)
        let point = pixelPoint(for: event)

        switch completedInteraction {
        case .none:
            return
        case let .pendingWindowSelection(anchorView, _, candidate):
            guard ScreenshotGeometry.isClickGesture(from: anchorView, to: viewLocation),
                  ScreenshotGeometry.roundedRectContains(
                      point,
                      rect: candidate.pixelRect,
                      cornerRadius: candidate.cornerRadius
                  ) else { break }
            crop = candidate.pixelRect.clamped(to: imageSize)
            resetCornerRadiusForCropChange(candidate.cornerRadius)
            hoveredWindowRegion = nil
            selectedAnnotationID = nil
            notifyMutation()
        case let .pendingOutsideCompletion(anchorView, _):
            if ScreenshotGeometry.isClickGesture(from: anchorView, to: viewLocation),
               !containsCropContent(point) {
                requestCopy()
            }
        case .selectingCrop:
            if crop.width < 2 || crop.height < 2 {
                crop = .zero
            }
            notifyMutation()
        case .movingCrop:
            notifyMutation()
        case .resizingCrop:
            resetCornerRadiusForCropChange(displayedCornerRadius)
            notifyMutation()
        case let .drawingAnnotation(kind, _):
            if kind == .freehand {
                appendFreehandPoint(clampedToCrop(point), force: true)
            }
            if let annotation = draftAnnotation, isUsable(annotation) {
                commitAnnotations(history.annotations + [annotation], selecting: annotation.id)
            }
            draftAnnotation = nil
        case .movingAnnotation, .resizingAnnotation, .movingArrowEndpoint:
            if let workingAnnotations {
                commitAnnotations(workingAnnotations, selecting: selectedAnnotationID)
            }
            self.workingAnnotations = nil
        }
        updateInterface()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command), characters == "z" {
            flags.contains(.shift) ? redo() : undo()
            return
        }
        if flags.contains(.command), characters == "y" {
            redo()
            return
        }
        if flags.contains(.command), characters == "c" {
            requestCopy()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return
        }
        if event.keyCode == 53 {
            requestCancel()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            requestCopy()
            return
        }
        super.keyDown(with: event)
    }

    func setDisplayActive(_ active: Bool) {
        guard isDisplayActive != active else { return }
        if !active {
            cancelLineWidthAdjustment()
            cancelCornerRadiusAdjustment()
            toolbar.dismissStylePopover()
            suppressMutationNotifications = true
            finishTextEditing(commit: true)
            suppressMutationNotifications = false
            interaction = .none
            workingAnnotations = nil
            draftAnnotation = nil
            hoveredWindowRegion = nil
        }
        isDisplayActive = active
        toolbar.isHidden = !active
        updateInterface()
    }

    func finishEditingBeforeDismissal() {
        cancelLineWidthAdjustment()
        cancelCornerRadiusAdjustment()
        toolbar.dismissStylePopover()
        finishTextEditing(commit: false)
        cancelMosaicPreview(releasingImage: true)
        interaction = .none
        workingAnnotations = nil
        draftAnnotation = nil
        hoveredWindowRegion = nil
    }

    func chooseTool(_ newTool: ScreenshotTool) {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        let isCurrentTool = newTool == tool
        tool = newTool
        if newTool == .mosaic {
            ensureMosaicPreview()
        }
        if !isCurrentTool {
            selectedAnnotationID = nil
        }
        updateInterface()
        window?.makeFirstResponder(self)
        toolbar.presentStylePopover(for: newTool)
    }

    func chooseColor(_ newColor: ScreenshotColor) {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        color = newColor
        mutateSelectedAnnotation { annotation in
            guard ScreenshotAnnotationStylePolicy.supportsColor(annotation.kind) else { return }
            annotation.color = newColor
        }
        updateInterface()
    }

    func chooseLineWidth(_ newWidth: Int) {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        lineWidth = ScreenshotAnnotationStylePolicy.clampedLineWidth(newWidth)
        mutateSelectedAnnotation { annotation in
            guard ScreenshotAnnotationStylePolicy.supportsLineWidth(annotation.kind) else { return }
            annotation.lineWidth = lineWidth
        }
        updateInterface()
    }

    func beginLineWidthAdjustment() {
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        guard lineWidthAdjustment == nil else { return }
        lineWidthAdjustment = ScreenshotLineWidthAdjustment(
            annotations: history.annotations,
            selectedAnnotationID: selectedAnnotationID,
            lineWidth: lineWidth
        )
        // Invalidate any copy/save already rendering before the first slider preview.
        notifyMutation()
    }

    func previewLineWidth(_ newWidth: Int) {
        guard var adjustment = lineWidthAdjustment else { return }
        adjustment.preview(newWidth)
        lineWidth = adjustment.previewLineWidth
        lineWidthAdjustment = adjustment
        updateInterface()
    }

    func endLineWidthAdjustment() {
        guard let adjustment = lineWidthAdjustment else { return }
        lineWidthAdjustment = nil
        lineWidth = adjustment.previewLineWidth
        if adjustment.hasAnnotationChange {
            commitAnnotations(
                adjustment.previewAnnotations,
                selecting: adjustment.selectedAnnotationID,
                notify: false
            )
        } else {
            updateInterface()
        }
    }

    func chooseCornerRadius(_ newRadius: Int) {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        let normalized = ScreenshotCropStylePolicy.clampedCornerRadius(newRadius, for: crop)
        guard normalized != history.cornerRadius else { return }
        history.commit(history.annotations, cornerRadius: normalized)
        notifyMutation()
        updateInterface()
    }

    func beginCornerRadiusAdjustment() {
        endLineWidthAdjustment()
        finishTextEditing(commit: true)
        guard cornerRadiusAdjustment == nil, !crop.isEmpty else { return }
        cornerRadiusAdjustment = ScreenshotCornerRadiusAdjustment(
            cornerRadius: history.cornerRadius,
            cropRect: crop
        )
        // The preview belongs to a new revision even before mouse-up commits history.
        notifyMutation()
    }

    func previewCornerRadius(_ newRadius: Int) {
        guard var adjustment = cornerRadiusAdjustment else { return }
        adjustment.preview(newRadius)
        cornerRadiusAdjustment = adjustment
        updateInterface()
    }

    func endCornerRadiusAdjustment() {
        guard let adjustment = cornerRadiusAdjustment else { return }
        cornerRadiusAdjustment = nil
        if adjustment.hasChange {
            history.commit(
                history.annotations,
                cornerRadius: adjustment.previewCornerRadius
            )
        }
        updateInterface()
    }

    func undo() {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        guard history.undo() else { return }
        repairSelection()
        synchronizeStyleWithSelection()
        notifyMutation()
        updateInterface()
    }

    func redo() {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        guard history.redo() else { return }
        repairSelection()
        synchronizeStyleWithSelection()
        notifyMutation()
        updateInterface()
    }

    func deleteSelection() {
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        if textEditor != nil {
            finishTextEditing(commit: false)
        }
        guard let selectedAnnotationID else { return }
        let updated = history.annotations.filter { $0.id != selectedAnnotationID }
        commitAnnotations(updated, selecting: nil)
    }

    func requestCopy() {
        toolbar.dismissStylePopover()
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        guard snapshot.isValid else {
            NSSound.beep()
            return
        }
        delegate?.screenshotCanvasDidRequestCopy(canvas: self, snapshot: snapshot)
    }

    func requestSave(format: ScreenshotOutputFormat) {
        toolbar.dismissStylePopover()
        endLineWidthAdjustment()
        endCornerRadiusAdjustment()
        finishTextEditing(commit: true)
        guard snapshot.isValid else {
            NSSound.beep()
            return
        }
        delegate?.screenshotCanvasDidRequestSave(
            canvas: self,
            snapshot: snapshot,
            format: format
        )
    }

    func requestCancel() {
        cancelLineWidthAdjustment()
        cancelCornerRadiusAdjustment()
        toolbar.dismissStylePopover()
        if textEditor != nil {
            finishTextEditing(commit: false)
        }
        delegate?.screenshotCanvasDidRequestCancel(canvas: self, generation: generation)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            // The first Enter confirms an IME marked range. A later Enter commits the annotation.
            guard ScreenshotTextCommandPolicy.shouldCommitReturn(
                hasMarkedText: textView.hasMarkedText()
            ) else { return false }
            finishTextEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishTextEditing(commit: false)
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !isFinishingTextEditing else { return }
        finishTextEditing(commit: true)
    }

    private func handleSelectionMouseDown(event: NSEvent, point: PixelPoint) {
        if let hit = hitTestAnnotation(at: point) {
            adoptStyle(of: hit)
            selectedAnnotationID = hit.id
            if event.clickCount >= 2, hit.kind == .text {
                beginTextEditing(hit)
            } else {
                interaction = .movingAnnotation(id: hit.id, anchor: point, original: hit)
                workingAnnotations = history.annotations
            }
            updateInterface()
            return
        }

        selectedAnnotationID = nil
        if !cropLocked,
           let handle = cropHandle(at: event.locationInWindow) {
            interaction = .resizingCrop(handle: handle, original: crop)
        } else if !cropLocked, containsCropContent(point) {
            interaction = .movingCrop(anchor: point, original: crop)
        } else if !cropLocked {
            interaction = .selectingCrop(anchor: point)
            crop = PixelRect(x: point.x, y: point.y, width: 0, height: 0)
            resetCornerRadiusForCropChange(0)
        }
        updateInterface()
    }

    private var selectedAnnotation: ScreenshotAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return displayedAnnotations.first { $0.id == selectedAnnotationID }
    }

    private func containsCropContent(_ point: PixelPoint) -> Bool {
        ScreenshotGeometry.roundedRectContains(
            point,
            rect: crop,
            cornerRadius: displayedCornerRadius
        )
    }

    private func annotationKind(for tool: ScreenshotTool) -> ScreenshotAnnotationKind? {
        switch tool {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .mosaic: return .mosaic
        case .freehand: return .freehand
        case .select, .text: return nil
        }
    }

    private func makeAnnotation(
        kind: ScreenshotAnnotationKind,
        start: PixelPoint,
        end: PixelPoint
    ) -> ScreenshotAnnotation {
        ScreenshotAnnotation(
            kind: kind,
            start: start,
            end: end,
            color: color,
            lineWidth: lineWidth,
            points: kind == .freehand ? [start] : []
        )
    }

    private func appendFreehandPoint(_ point: PixelPoint, force: Bool = false) {
        guard var annotation = draftAnnotation,
              annotation.kind == .freehand else { return }
        let endpoint = clampedToCrop(point)
        let threshold = max(1, annotation.lineWidth / 4)
        if let last = annotation.points.last {
            let dx = endpoint.x - last.x
            let dy = endpoint.y - last.y
            if !force, dx * dx + dy * dy < threshold * threshold { return }
            if endpoint == last { return }
        }
        if annotation.points.count < 50_000 {
            annotation.points.append(endpoint)
        } else if !annotation.points.isEmpty {
            annotation.points[annotation.points.count - 1] = endpoint
        }
        annotation.start = annotation.points.first ?? endpoint
        annotation.end = annotation.points.last ?? endpoint
        draftAnnotation = annotation
    }

    private func adoptStyle(of annotation: ScreenshotAnnotation) {
        if ScreenshotAnnotationStylePolicy.supportsColor(annotation.kind) {
            color = annotation.color
        }
        if ScreenshotAnnotationStylePolicy.supportsLineWidth(annotation.kind) {
            lineWidth = ScreenshotAnnotationStylePolicy.clampedLineWidth(annotation.lineWidth)
        }
    }

    private func synchronizeStyleWithSelection() {
        guard let selected = selectedAnnotation else { return }
        adoptStyle(of: selected)
    }

    private func cancelLineWidthAdjustment() {
        guard let adjustment = lineWidthAdjustment else { return }
        lineWidthAdjustment = nil
        lineWidth = adjustment.originalLineWidth
        synchronizeStyleWithSelection()
        updateInterface()
    }

    private func cancelCornerRadiusAdjustment() {
        guard cornerRadiusAdjustment != nil else { return }
        cornerRadiusAdjustment = nil
        updateInterface()
    }

    private func resetCornerRadiusForCropChange(_ value: Int) {
        cornerRadiusAdjustment = nil
        history.reset(
            annotations: history.annotations,
            cornerRadius: ScreenshotCropStylePolicy.clampedCornerRadius(value, for: crop)
        )
    }

    private func isUsable(_ annotation: ScreenshotAnnotation) -> Bool {
        switch annotation.kind {
        case .arrow:
            let dx = annotation.end.x - annotation.start.x
            let dy = annotation.end.y - annotation.start.y
            return dx * dx + dy * dy >= 4
        case .rectangle, .mosaic:
            return annotation.bounds.width >= 2 && annotation.bounds.height >= 2
        case .text:
            return !annotation.text.isEmpty
        case .freehand:
            return !annotation.points.isEmpty
        }
    }

    private func commitAnnotations(
        _ annotations: [ScreenshotAnnotation],
        selecting id: UUID?,
        notify: Bool = true
    ) {
        history.commit(annotations)
        workingAnnotations = nil
        selectedAnnotationID = id
        if !annotations.isEmpty {
            // Crop locking is deliberately monotonic for the lifetime of this display session.
            cropLocked = true
        }
        repairSelection()
        if notify {
            notifyMutation()
        }
        updateInterface()
    }

    private func mutateSelectedAnnotation(
        _ mutation: (inout ScreenshotAnnotation) -> Void
    ) {
        guard let selectedAnnotationID,
              let index = history.annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else {
            return
        }
        var annotations = history.annotations
        mutation(&annotations[index])
        guard annotations != history.annotations else { return }
        commitAnnotations(annotations, selecting: selectedAnnotationID)
    }

    private func replaceWorkingAnnotation(id: UUID, with annotation: ScreenshotAnnotation) {
        guard var annotations = workingAnnotations,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index] = annotation
        workingAnnotations = annotations
    }

    private func resizedAnnotation(
        _ annotation: ScreenshotAnnotation,
        handle: ScreenshotResizeHandle,
        to point: PixelPoint
    ) -> ScreenshotAnnotation {
        let originalBounds = annotation.bounds
        let resizedBounds = ScreenshotGeometry.resizing(
            originalBounds,
            handle: handle,
            to: point,
            within: imageSize,
            minimumSize: 2
        )

        func transform(_ sourcePoint: PixelPoint) -> PixelPoint {
            let xRatio = CGFloat(sourcePoint.x - originalBounds.minX)
                / CGFloat(max(1, originalBounds.width))
            let yRatio = CGFloat(sourcePoint.y - originalBounds.minY)
                / CGFloat(max(1, originalBounds.height))
            return PixelPoint(
                x: resizedBounds.minX + Int((xRatio * CGFloat(resizedBounds.width)).rounded()),
                y: resizedBounds.minY + Int((yRatio * CGFloat(resizedBounds.height)).rounded())
            )
        }

        var result = annotation
        if annotation.kind == .text {
            result.start = PixelPoint(x: resizedBounds.minX, y: resizedBounds.minY)
            result.end = PixelPoint(x: resizedBounds.maxX, y: resizedBounds.maxY)
            let scale = CGFloat(resizedBounds.height) / CGFloat(max(1, originalBounds.height))
            result.fontSize = min(160, max(8, Int((CGFloat(annotation.fontSize) * scale).rounded())))
        } else if annotation.kind == .freehand {
            result.points = annotation.points.map(transform)
            result.start = result.points.first ?? transform(annotation.start)
            result.end = result.points.last ?? transform(annotation.end)
        } else {
            result.start = transform(annotation.start)
            result.end = transform(annotation.end)
        }
        return clampedAnnotation(result)
    }

    private func clampedAnnotation(_ annotation: ScreenshotAnnotation) -> ScreenshotAnnotation {
        let bounds = annotation.bounds
        let dx: Int
        if bounds.minX < crop.minX {
            dx = crop.minX - bounds.minX
        } else if bounds.maxX > crop.maxX {
            dx = crop.maxX - bounds.maxX
        } else {
            dx = 0
        }
        let dy: Int
        if bounds.minY < crop.minY {
            dy = crop.minY - bounds.minY
        } else if bounds.maxY > crop.maxY {
            dy = crop.maxY - bounds.maxY
        } else {
            dy = 0
        }
        var result = annotation
        result.start.x += dx
        result.start.y += dy
        result.end.x += dx
        result.end.y += dy
        result.points = result.points.map {
            PixelPoint(x: $0.x + dx, y: $0.y + dy)
        }
        return result
    }

    private func repairSelection() {
        guard let selectedAnnotationID else { return }
        if !history.annotations.contains(where: { $0.id == selectedAnnotationID }) {
            self.selectedAnnotationID = nil
        }
    }

    private func notifyMutation() {
        guard !suppressMutationNotifications else { return }
        delegate?.screenshotCanvasDidMutate(canvas: self, snapshot: snapshot)
    }

    private func beginNewTextEditing(at point: PixelPoint) {
        let pixelWidth = max(80, pixelDistance(forViewDistance: 220))
        let pixelHeight = max(24, pixelDistance(forViewDistance: 38))
        let annotation = ScreenshotAnnotation(
            kind: .text,
            start: point,
            end: PixelPoint(
                x: min(crop.maxX, point.x + pixelWidth),
                y: min(crop.maxY, point.y + pixelHeight)
            ),
            color: color,
            lineWidth: lineWidth,
            fontSize: max(16, pixelDistance(forViewDistance: 20))
        )
        beginTextEditing(annotation, original: nil)
    }

    private func beginTextEditing(_ annotation: ScreenshotAnnotation) {
        beginTextEditing(annotation, original: annotation)
    }

    private func beginTextEditing(
        _ annotation: ScreenshotAnnotation,
        original: ScreenshotAnnotation?
    ) {
        finishTextEditing(commit: true)
        selectedAnnotationID = annotation.id
        textEditingState = TextEditingState(
            annotationID: annotation.id,
            original: original
        )

        let editor = NSTextView(frame: editorFrame(for: annotation))
        editor.delegate = self
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = false
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100_000, height: editor.bounds.height)
        editor.textContainerInset = NSSize(width: 5, height: 4)
        editor.font = NSFont(name: "PingFang SC", size: viewFontSize(for: annotation))
            ?? NSFont.systemFont(ofSize: viewFontSize(for: annotation))
        editor.textColor = nsColor(for: annotation.color)
        editor.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        editor.insertionPointColor = .white
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.55),
            .foregroundColor: NSColor.white
        ]
        editor.string = annotation.text
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 4
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(editor, positioned: .above, relativeTo: toolbar)
        textEditor = editor
        window?.makeFirstResponder(editor)
        if !editor.string.isEmpty {
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        }
        updateInterface()
    }

    private func finishTextEditing(commit: Bool) {
        guard !isFinishingTextEditing,
              let editor = textEditor,
              let state = textEditingState else { return }
        isFinishingTextEditing = true
        if editor.hasMarkedText() {
            editor.unmarkText()
        }

        let rawText = editor.string.replacingOccurrences(of: "\r\n", with: "\n")
        let text = rawText.trimmingCharacters(in: .newlines)
        editor.delegate = nil
        editor.removeFromSuperview()
        textEditor = nil
        textEditingState = nil
        window?.makeFirstResponder(self)

        if commit {
            var annotations = history.annotations
            if let index = annotations.firstIndex(where: { $0.id == state.annotationID }) {
                if text.isEmpty {
                    annotations.remove(at: index)
                    selectedAnnotationID = nil
                } else {
                    annotations[index].text = text
                    annotations[index].color = color
                    selectedAnnotationID = state.annotationID
                }
            } else if !text.isEmpty {
                var annotation = state.original ?? ScreenshotAnnotation(
                    id: state.annotationID,
                    kind: .text,
                    start: pixelPoint(fromViewPoint: editor.frame.origin),
                    end: pixelPoint(
                        fromViewPoint: CGPoint(x: editor.frame.maxX, y: editor.frame.maxY)
                    ),
                    color: color,
                    lineWidth: lineWidth,
                    text: text,
                    fontSize: max(16, pixelDistance(forViewDistance: 20))
                )
                annotation.text = text
                annotation.color = color
                annotations.append(clampedAnnotation(annotation))
                selectedAnnotationID = annotation.id
            }
            commitAnnotations(annotations, selecting: selectedAnnotationID)
        }

        isFinishingTextEditing = false
        updateInterface()
    }

    private func layoutTextEditor() {
        guard let editor = textEditor,
              let state = textEditingState else { return }
        let annotation = state.original
            ?? ScreenshotAnnotation(
                id: state.annotationID,
                kind: .text,
                start: pixelPoint(fromViewPoint: editor.frame.origin),
                end: pixelPoint(fromViewPoint: CGPoint(x: editor.frame.maxX, y: editor.frame.maxY)),
                color: color,
                lineWidth: lineWidth
            )
        editor.frame = editorFrame(for: annotation)
    }

    private func editorFrame(for annotation: ScreenshotAnnotation) -> NSRect {
        var rect = viewRect(from: annotation.bounds)
        let cropRect = viewRect(from: crop).insetBy(dx: 4, dy: 4)
        rect.size.width = min(max(34, cropRect.width), max(180, rect.width))
        rect.size.height = min(max(24, cropRect.height), max(34, rect.height))
        rect.origin.x = min(max(cropRect.minX, rect.minX), max(cropRect.minX, cropRect.maxX - rect.width))
        rect.origin.y = min(max(cropRect.minY, rect.minY), max(cropRect.minY, cropRect.maxY - rect.height))
        return rect.integral
    }

    private func viewFontSize(for annotation: ScreenshotAnnotation) -> CGFloat {
        guard source.height > 0 else { return CGFloat(annotation.fontSize) }
        return max(1, CGFloat(annotation.fontSize) / CGFloat(source.height) * bounds.height)
    }

    private func hitTestAnnotation(at point: PixelPoint) -> ScreenshotAnnotation? {
        let tolerance = pixelDistance(forViewDistance: 8)
        for annotation in displayedAnnotations.reversed() {
            let bounds = annotation.bounds
            let strokePadding = annotation.kind == .freehand
                ? Int(ceil(Double(max(1, annotation.lineWidth)) / 2))
                : 0
            let hitPadding = tolerance + strokePadding
            let expanded = PixelRect(
                x: bounds.x - hitPadding,
                y: bounds.y - hitPadding,
                width: bounds.width + hitPadding * 2,
                height: bounds.height + hitPadding * 2
            )
            guard expanded.contains(point) else { continue }
            if annotation.kind == .freehand {
                let strokeTolerance = Double(tolerance + max(1, annotation.lineWidth / 2))
                if freehandContains(annotation, point: point, tolerance: strokeTolerance) {
                    return annotation
                }
            } else if annotation.kind != .arrow
                || distanceFromPointToSegment(point, annotation.start, annotation.end) <= Double(tolerance) {
                return annotation
            }
        }
        return nil
    }

    private func freehandContains(
        _ annotation: ScreenshotAnnotation,
        point: PixelPoint,
        tolerance: Double
    ) -> Bool {
        let points = annotation.points
        guard let first = points.first else { return false }
        guard points.count > 1 else {
            return hypot(Double(point.x - first.x), Double(point.y - first.y)) <= tolerance
        }
        for index in 1..<points.count where distanceFromPointToSegment(
            point,
            points[index - 1],
            points[index]
        ) <= tolerance {
            return true
        }
        return false
    }

    private func distanceFromPointToSegment(
        _ point: PixelPoint,
        _ start: PixelPoint,
        _ end: PixelPoint
    ) -> Double {
        let px = Double(point.x)
        let py = Double(point.y)
        let x1 = Double(start.x)
        let y1 = Double(start.y)
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(px - x1, py - y1) }
        let projection = min(1, max(0, ((px - x1) * dx + (py - y1) * dy) / lengthSquared))
        return hypot(px - (x1 + projection * dx), py - (y1 + projection * dy))
    }

    private func cropHandle(at windowPoint: CGPoint) -> ScreenshotResizeHandle? {
        let point = convert(windowPoint, from: nil)
        return closestHandle(to: point, in: ScreenshotGeometry.handlePoints(for: crop))
    }

    private func annotationHandle(
        at windowPoint: CGPoint,
        for annotation: ScreenshotAnnotation
    ) -> ScreenshotResizeHandle? {
        let point = convert(windowPoint, from: nil)
        return closestHandle(to: point, in: ScreenshotGeometry.handlePoints(for: annotation.bounds))
    }

    private func arrowEndpoint(
        at windowPoint: CGPoint,
        for annotation: ScreenshotAnnotation
    ) -> Bool? {
        guard annotation.kind == .arrow else { return nil }
        let point = convert(windowPoint, from: nil)
        let startDistance = squaredDistance(point, viewPoint(from: annotation.start))
        let endDistance = squaredDistance(point, viewPoint(from: annotation.end))
        guard min(startDistance, endDistance) <= 100 else { return nil }
        return startDistance <= endDistance
    }

    private func closestHandle(
        to point: CGPoint,
        in handles: [ScreenshotResizeHandle: PixelPoint]
    ) -> ScreenshotResizeHandle? {
        var nearest: (handle: ScreenshotResizeHandle, distance: CGFloat)?
        for handle in ScreenshotResizeHandle.allCases {
            guard let handlePoint = handles[handle] else { continue }
            let distance = squaredDistance(point, viewPoint(from: handlePoint))
            if nearest == nil || distance < nearest!.distance {
                nearest = (handle, distance)
            }
        }
        guard let nearest, nearest.distance <= 100 else { return nil }
        return nearest.handle
    }

    private func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func windowRegion(at point: PixelPoint) -> ScreenshotWindowRegion? {
        ScreenshotGeometry.frontmostWindowRegion(at: point, in: windowRegions)
    }

    private func pixelPoint(for event: NSEvent) -> PixelPoint {
        pixelPoint(fromViewPoint: convert(event.locationInWindow, from: nil))
    }

    private func pixelPoint(fromViewPoint point: CGPoint) -> PixelPoint {
        ScreenshotGeometry.pixelPoint(
            fromViewPoint: point,
            viewSize: bounds.size,
            imageSize: imageSize,
            isViewFlipped: true
        )
    }

    private func viewPoint(from point: PixelPoint) -> CGPoint {
        ScreenshotGeometry.viewPoint(
            fromPixelPoint: point,
            viewSize: bounds.size,
            imageSize: imageSize,
            isViewFlipped: true
        )
    }

    private func viewRect(from rect: PixelRect) -> NSRect {
        let origin = viewPoint(from: PixelPoint(x: rect.minX, y: rect.minY))
        let end = viewPoint(from: PixelPoint(x: rect.maxX, y: rect.maxY))
        return NSRect(
            x: min(origin.x, end.x),
            y: min(origin.y, end.y),
            width: abs(end.x - origin.x),
            height: abs(end.y - origin.y)
        )
    }

    private func clampedToCrop(_ point: PixelPoint) -> PixelPoint {
        PixelPoint(
            x: min(max(crop.minX, point.x), crop.maxX),
            y: min(max(crop.minY, point.y), crop.maxY)
        )
    }

    private func pixelDistance(forViewDistance distance: CGFloat) -> Int {
        guard bounds.width > 0, bounds.height > 0 else { return Int(distance.rounded()) }
        let horizontal = distance / bounds.width * CGFloat(source.width)
        let vertical = distance / bounds.height * CGFloat(source.height)
        return max(1, Int(max(horizontal, vertical).rounded()))
    }

    private func viewCornerRadius(_ sourcePixelRadius: Int) -> CGFloat {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else {
            return 0
        }
        let horizontal = CGFloat(max(0, sourcePixelRadius)) / CGFloat(source.width) * bounds.width
        let vertical = CGFloat(max(0, sourcePixelRadius)) / CGFloat(source.height) * bounds.height
        return min(horizontal, vertical)
    }

    private func roundedPath(rect: NSRect, cornerRadius: CGFloat) -> NSBezierPath {
        let radius = min(
            max(0, cornerRadius),
            max(0, min(rect.width, rect.height) / 2)
        )
        return radius > 0
            ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            : NSBezierPath(rect: rect)
    }

    private func drawMask(selection: PixelRect, cornerRadius: Int) {
        let alpha: CGFloat = isDisplayActive ? 0.52 : 0.72
        guard !selection.isEmpty else {
            NSColor.black.withAlphaComponent(alpha).setFill()
            bounds.fill()
            return
        }

        let path = NSBezierPath(rect: bounds)
        path.append(roundedPath(
            rect: viewRect(from: selection),
            cornerRadius: viewCornerRadius(cornerRadius)
        ))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawCropBorder(_ rect: NSRect, cornerRadius: Int) {
        let radius = viewCornerRadius(cornerRadius)
        let border = roundedPath(
            rect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: max(0, radius - 0.5)
        )
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.92).setStroke()
        border.stroke()

        let accent = roundedPath(
            rect: rect.insetBy(dx: 1.5, dy: 1.5),
            cornerRadius: max(0, radius - 1.5)
        )
        accent.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        accent.stroke()

        guard !cropLocked else { return }
        drawHandles(ScreenshotGeometry.handlePoints(for: crop), accent: .controlAccentColor, size: 8)
    }

    private func drawMeasurementBadge(near cropRect: NSRect) {
        var value = "\(crop.width) × \(crop.height) px"
        if let pointerPixel {
            value += "  |  x:\(pointerPixel.x) y:\(pointerPixel.y)"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = value as NSString
        let textSize = text.size(withAttributes: attributes)
        let badgeSize = NSSize(width: textSize.width + 12, height: textSize.height + 7)
        var origin = NSPoint(x: cropRect.minX, y: cropRect.minY - badgeSize.height - 6)
        if origin.y < 6 {
            origin.y = min(bounds.maxY - badgeSize.height - 6, cropRect.minY + 6)
        }
        origin.x = min(max(6, origin.x), max(6, bounds.maxX - badgeSize.width - 6))
        let badgeRect = NSRect(origin: origin, size: badgeSize).integral
        let background = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.78).setFill()
        background.fill()
        text.draw(
            at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3),
            withAttributes: attributes
        )
    }

    private func drawSelection(for annotation: ScreenshotAnnotation) {
        let rect = viewRect(from: annotation.bounds).insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        if annotation.kind == .arrow {
            drawEndpoint(at: annotation.start, accent: .controlAccentColor, size: 7)
            drawEndpoint(at: annotation.end, accent: .controlAccentColor, size: 7)
        } else {
            drawHandles(
                ScreenshotGeometry.handlePoints(for: annotation.bounds),
                accent: .controlAccentColor,
                size: 7
            )
        }
    }

    private func drawHandles(
        _ handles: [ScreenshotResizeHandle: PixelPoint],
        accent: NSColor,
        size: CGFloat
    ) {
        for point in handles.values {
            let center = viewPoint(from: point)
            let rect = NSRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            let handle = NSBezierPath(ovalIn: rect)
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            accent.setStroke()
            handle.stroke()
        }
    }

    private func drawEndpoint(at point: PixelPoint, accent: NSColor, size: CGFloat) {
        let center = viewPoint(from: point)
        let rect = NSRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
        let handle = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        handle.fill()
        handle.lineWidth = 1.5
        accent.setStroke()
        handle.stroke()
    }

    private func draw(_ annotation: ScreenshotAnnotation) {
        let start = viewPoint(from: annotation.start)
        let end = viewPoint(from: annotation.end)
        let annotationColor = nsColor(for: annotation.color)
        let viewLineWidth = ScreenshotGeometry.viewLineWidth(
            sourcePixelWidth: annotation.lineWidth,
            sourceWidth: source.width,
            viewWidth: bounds.width,
            backingScaleFactor: window?.backingScaleFactor ?? 1
        )

        switch annotation.kind {
        case .arrow:
            let arrowViewWidth = ScreenshotGeometry.viewLineWidth(
                sourcePixelWidth: ScreenshotGeometry.arrowShaftPixelWidth(
                    lineWidth: annotation.lineWidth
                ),
                sourceWidth: source.width,
                viewWidth: bounds.width,
                backingScaleFactor: window?.backingScaleFactor ?? 1
            )
            drawArrow(
                from: start,
                to: end,
                color: annotationColor,
                viewWidth: arrowViewWidth,
                sourceLineWidth: annotation.lineWidth
            )
        case .rectangle:
            let path = NSBezierPath(rect: viewRect(from: annotation.bounds).insetBy(
                dx: viewLineWidth / 2,
                dy: viewLineWidth / 2
            ))
            path.lineWidth = viewLineWidth
            annotationColor.setStroke()
            path.stroke()
        case .mosaic:
            guard let mosaicPreviewImage else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: viewRect(from: annotation.bounds)).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            mosaicPreviewImage.draw(
                in: bounds,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            NSGraphicsContext.restoreGraphicsState()
        case .text:
            guard !annotation.text.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "PingFang SC", size: viewFontSize(for: annotation))
                    ?? NSFont.systemFont(ofSize: viewFontSize(for: annotation)),
                .foregroundColor: annotationColor
            ]
            (annotation.text as NSString).draw(
                in: viewRect(from: annotation.bounds),
                withAttributes: attributes
            )
        case .freehand:
            drawFreehand(
                annotation.points.map(viewPoint(from:)),
                color: annotationColor,
                width: viewLineWidth
            )
        }
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: NSColor,
        viewWidth: CGFloat,
        sourceLineWidth: Int
    ) {
        let coordinateScale = bounds.width / CGFloat(max(1, source.width))
        let geometry = ScreenshotGeometry.arrowGeometry(
            from: start,
            to: end,
            lineWidth: sourceLineWidth,
            coordinateScale: coordinateScale
        )
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: geometry.shaftEnd)
        path.lineWidth = viewWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()

        let head = NSBezierPath()
        head.move(to: geometry.tip)
        head.line(to: geometry.left)
        head.line(to: geometry.right)
        head.close()
        color.setFill()
        head.fill()
    }

    private func drawFreehand(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        color.setStroke()
        color.setFill()
        guard points.count > 1 else {
            NSBezierPath(ovalIn: NSRect(
                x: first.x - width / 2,
                y: first.y - width / 2,
                width: width,
                height: width
            )).fill()
            return
        }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func nsColor(for color: ScreenshotColor) -> NSColor {
        NSColor(cgColor: color.cgColor) ?? .systemRed
    }

    private func layoutToolbar() {
        let fitting = toolbar.fittingSize
        let width = min(max(44, fitting.width), max(44, bounds.width - 16))
        let height = max(42, fitting.height)
        var x = (bounds.width - width) / 2
        var y: CGFloat = 12

        if !crop.isEmpty {
            let selection = viewRect(from: crop)
            x = selection.midX - width / 2
            let below = selection.maxY + 10
            let above = selection.minY - height - 10
            y = below + height <= bounds.maxY - 8 ? below : max(8, above)
        }
        x = min(max(8, x), max(8, bounds.maxX - width - 8))
        y = min(max(8, y), max(8, bounds.maxY - height - 8))
        toolbar.frame = NSRect(x: x, y: y, width: width, height: height).integral
    }

    private func updateToolbar() {
        toolbar.update(
            tool: tool,
            color: color,
            lineWidth: lineWidth,
            cornerRadius: displayedCornerRadius,
            maximumCornerRadius: ScreenshotCropStylePolicy.maximumCornerRadius(for: crop),
            hasCrop: !crop.isEmpty,
            selectedAnnotationKind: selectedAnnotation?.kind,
            canUndo: history.canUndo,
            canRedo: history.canRedo
        )
    }

    private func updateInterface() {
        updateToolbar()
        if !bounds.isEmpty {
            layoutToolbar()
        }
        needsDisplay = true
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    private func ensureMosaicPreview() {
        guard mosaicPreviewImage == nil, mosaicPreviewTask == nil else { return }
        mosaicPreviewRevision &+= 1
        let expectedRevision = mosaicPreviewRevision
        let input = ScreenshotImageBox(image: source)
        let task = Task { [weak self] in
            let result = try? await ScreenshotRenderExecutor.shared.mosaicImage(for: input)
            guard !Task.isCancelled,
                  let self,
                  self.mosaicPreviewRevision == expectedRevision else { return }
            self.mosaicPreviewTask = nil
            if let image = result?.image {
                self.mosaicPreviewImage = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
                self.needsDisplay = true
            }
        }
        mosaicPreviewTask = task
    }

    private func cancelMosaicPreview(releasingImage: Bool) {
        mosaicPreviewRevision &+= 1
        mosaicPreviewTask?.cancel()
        mosaicPreviewTask = nil
        if releasingImage {
            mosaicPreviewImage = nil
        }
    }
}

@MainActor
final class ScreenshotToolbarView: NSVisualEffectView, NSPopoverDelegate {
    private enum Tag {
        static let toolBase = 100
        static let colorBase = 200
        static let style = 350
        static let cornerRadius = 351
        static let undo = 401
        static let redo = 402
        static let delete = 403
        static let copy = 404
        static let save = 405
        static let cancel = 406
        static let savePNG = 451
        static let saveJPEG = 452
    }

    weak var canvas: ScreenshotCanvasView?

    private let stack = NSStackView()
    private var toolButtons: [ScreenshotTool: NSButton] = [:]
    private var commandButtons: [Int: NSButton] = [:]
    private let styleButton = NSButton()
    private let stylePopover = NSPopover()
    private let styleStack = NSStackView()
    private let colorRow = NSStackView()
    private let widthRow = NSStackView()
    private var colorButtons: [ScreenshotColor: NSButton] = [:]
    private let widthSlider = ScreenshotTrackingSlider(
        value: Double(ScreenshotAnnotationStylePolicy.defaultLineWidth),
        minValue: Double(ScreenshotAnnotationStylePolicy.lineWidthRange.lowerBound),
        maxValue: Double(ScreenshotAnnotationStylePolicy.lineWidthRange.upperBound),
        target: nil,
        action: nil
    )
    private let widthValueLabel = NSTextField(labelWithString: "")
    private let cornerRadiusButton = NSButton()
    private let cornerRadiusPopover = NSPopover()
    private let cornerRadiusSlider = ScreenshotTrackingSlider(
        value: 0,
        minValue: 0,
        maxValue: Double(ScreenshotCropStylePolicy.maximumAdjustableCornerRadius),
        target: nil,
        action: nil
    )
    private let cornerRadiusValueLabel = NSTextField(labelWithString: "")
    private let saveMenu = NSMenu()
    private var popoverKeyMonitor: Any?
    private var currentTool: ScreenshotTool = .select
    private var currentColor: ScreenshotColor = .red
    private var currentLineWidth = ScreenshotAnnotationStylePolicy.defaultLineWidth
    private var currentCornerRadius = 0
    private var maximumCornerRadius = 0
    private var hasCrop = false
    private var selectedAnnotationKind: ScreenshotAnnotationKind?
    private var styleVisibility = ScreenshotStyleControlVisibility(
        showsColor: false,
        showsLineWidth: false
    )

    var isStylePopoverShown: Bool { stylePopover.isShown || cornerRadiusPopover.isShown }

#if DEBUG
    var testingColorButtons: [NSButton] {
        ScreenshotColor.allCases.compactMap { colorButtons[$0] }
    }

    var testingTextToolTooltip: String? { toolButtons[.text]?.toolTip }
    var testingFreehandToolTooltip: String? { toolButtons[.freehand]?.toolTip }
    var testingStyleButton: NSButton { styleButton }
    var testingLineWidthSlider: NSSlider { widthSlider }
    var testingLineWidthValueLabel: NSTextField { widthValueLabel }
    var testingCornerRadiusButton: NSButton { cornerRadiusButton }
    var testingCornerRadiusSlider: NSSlider { cornerRadiusSlider }
#endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        trailing.priority = NSLayoutConstraint.Priority(999)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom
        ])
        buildButtons()
        buildStylePopover()
        buildCornerRadiusPopover()
        buildSaveMenu()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(
        tool: ScreenshotTool,
        color: ScreenshotColor,
        lineWidth: Int,
        cornerRadius: Int,
        maximumCornerRadius: Int,
        hasCrop: Bool,
        selectedAnnotationKind: ScreenshotAnnotationKind?,
        canUndo: Bool,
        canRedo: Bool
    ) {
        currentTool = tool
        currentColor = color
        currentLineWidth = ScreenshotAnnotationStylePolicy.clampedLineWidth(lineWidth)
        self.maximumCornerRadius = max(0, maximumCornerRadius)
        currentCornerRadius = min(max(0, cornerRadius), self.maximumCornerRadius)
        self.hasCrop = hasCrop
        self.selectedAnnotationKind = selectedAnnotationKind
        styleVisibility = ScreenshotAnnotationStylePolicy.controls(
            for: tool,
            selectedAnnotationKind: selectedAnnotationKind
        )

        for (value, button) in toolButtons {
            let isSelected = value == tool
            let toolStyle = ScreenshotAnnotationStylePolicy.controls(
                for: value,
                selectedAnnotationKind: nil
            )
            button.state = isSelected ? .on : .off
            button.isEnabled = hasCrop || value == .select
            button.contentTintColor = isSelected && toolStyle.showsColor
                ? nsColor(color)
                : .labelColor
            if isSelected, !toolStyle.isEmpty {
                button.setAccessibilityValue(
                    "已选择，" + styleDescription(visibility: toolStyle)
                )
            } else {
                button.setAccessibilityValue(isSelected ? "已选择" : nil)
            }
        }

        styleButton.isHidden = tool != .select || styleVisibility.isEmpty || !hasCrop
        styleButton.isEnabled = !styleVisibility.isEmpty && hasCrop
        updateStyleButton()
        updateStylePopoverContent()
        updateCornerRadiusControl()

        commandButtons[Tag.undo]?.isEnabled = canUndo
        commandButtons[Tag.redo]?.isEnabled = canRedo
        commandButtons[Tag.delete]?.isEnabled = selectedAnnotationKind != nil
        commandButtons[Tag.copy]?.isEnabled = hasCrop
        commandButtons[Tag.save]?.isEnabled = hasCrop

        if styleVisibility.isEmpty || !hasCrop {
            if stylePopover.isShown {
                stylePopover.close()
            }
        }
        if !hasCrop, cornerRadiusPopover.isShown {
            cornerRadiusPopover.close()
        }
    }

    func presentStylePopover(for tool: ScreenshotTool) {
        guard tool == currentTool, let anchor = toolButtons[tool] else { return }
        presentStylePopover(relativeTo: anchor)
    }

    func dismissStylePopover() {
        stopPopoverKeyMonitor()
        saveMenu.cancelTracking()
        if stylePopover.isShown {
            stylePopover.close()
        }
        if cornerRadiusPopover.isShown {
            cornerRadiusPopover.close()
        }
    }

    private func buildButtons() {
        let tools: [(ScreenshotTool, String, String, String)] = [
            (.select, "cursorarrow", "选择、移动或缩放标注", "select"),
            (.arrow, "arrow.up.right", "箭头", "arrow"),
            (.rectangle, "rectangle", "矩形", "rectangle"),
            (.freehand, "pencil.and.scribble", "涂鸦", "freehand"),
            (.mosaic, "square.grid.3x3", "马赛克", "mosaic"),
            (.text, "character.cursor.ibeam", "文字", "text")
        ]
        for (tool, symbol, tooltip, identifier) in tools {
            let button = iconButton(
                symbol: symbol,
                tooltip: tooltip,
                tag: Tag.toolBase + tool.rawValue,
                isToggle: true,
                identifier: "screenshot.tool.\(identifier)"
            )
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }

        configureStyleButton()
        stack.addArrangedSubview(styleButton)
        configureCornerRadiusButton()
        stack.addArrangedSubview(cornerRadiusButton)
        addSeparator()
        addCommandButton(
            symbol: "arrow.uturn.backward",
            tooltip: "撤销 (Command-Z)",
            tag: Tag.undo,
            identifier: "screenshot.command.undo"
        )
        addCommandButton(
            symbol: "arrow.uturn.forward",
            tooltip: "重做 (Command-Shift-Z)",
            tag: Tag.redo,
            identifier: "screenshot.command.redo"
        )
        addCommandButton(
            symbol: "trash",
            tooltip: "删除所选标注",
            tag: Tag.delete,
            identifier: "screenshot.command.delete"
        )
        addSeparator()
        addCommandButton(
            symbol: "doc.on.doc",
            tooltip: "复制 PNG (Command-C)",
            tag: Tag.copy,
            identifier: "screenshot.command.copy"
        )
        addCommandButton(
            symbol: "square.and.arrow.down",
            tooltip: "另存为 PNG 或 JPEG",
            tag: Tag.save,
            identifier: "screenshot.command.save"
        )
        addCommandButton(
            symbol: "xmark",
            tooltip: "取消截图 (Escape)",
            tag: Tag.cancel,
            identifier: "screenshot.command.cancel"
        )
    }

    private func configureStyleButton() {
        styleButton.target = self
        styleButton.action = #selector(buttonPressed(_:))
        styleButton.tag = Tag.style
        styleButton.imagePosition = .imageOnly
        styleButton.bezelStyle = .accessoryBarAction
        styleButton.setButtonType(.momentaryPushIn)
        styleButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        styleButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        styleButton.setAccessibilityLabel("标注样式")
        styleButton.setAccessibilityIdentifier("screenshot.style.current")
        styleButton.isHidden = true
    }

    private func configureCornerRadiusButton() {
        cornerRadiusButton.image = NSImage(
            systemSymbolName: "rectangle.roundedtop",
            accessibilityDescription: "选区圆角"
        ) ?? NSImage(
            systemSymbolName: "rectangle",
            accessibilityDescription: "选区圆角"
        )
        cornerRadiusButton.target = self
        cornerRadiusButton.action = #selector(buttonPressed(_:))
        cornerRadiusButton.tag = Tag.cornerRadius
        cornerRadiusButton.imagePosition = .imageOnly
        cornerRadiusButton.bezelStyle = .accessoryBarAction
        cornerRadiusButton.setButtonType(.momentaryPushIn)
        cornerRadiusButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        cornerRadiusButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        cornerRadiusButton.setAccessibilityLabel("选区圆角")
        cornerRadiusButton.setAccessibilityIdentifier("screenshot.crop.corner-radius")
        cornerRadiusButton.isHidden = true
    }

    private func buildStylePopover() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 88))
        root.wantsLayer = true

        styleStack.orientation = .vertical
        styleStack.alignment = .centerX
        styleStack.spacing = 8
        styleStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        styleStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(styleStack)
        NSLayoutConstraint.activate([
            styleStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            styleStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            styleStack.topAnchor.constraint(equalTo: root.topAnchor),
            styleStack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 5
        for color in ScreenshotColor.allCases {
            let name = colorName(color)
            let button = NSButton(
                image: swatchImage(color: color, selected: false),
                target: self,
                action: #selector(colorPressed(_:))
            )
            button.tag = Tag.colorBase + color.rawValue
            button.title = ""
            button.alternateTitle = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.isBordered = false
            button.setButtonType(.toggle)
            button.toolTip = name
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setAccessibilityLabel(name)
            button.setAccessibilityIdentifier("screenshot.color.\(color.rawValue)")
            colorButtons[color] = button
            colorRow.addArrangedSubview(button)
        }
        styleStack.addArrangedSubview(colorRow)

        widthRow.orientation = .horizontal
        widthRow.alignment = .centerY
        widthRow.spacing = 7
        let lineImage = NSImageView(image: NSImage(
            systemSymbolName: "lineweight",
            accessibilityDescription: "线条粗细"
        ) ?? NSImage(size: NSSize(width: 16, height: 16)))
        lineImage.contentTintColor = .labelColor
        lineImage.setAccessibilityElement(false)
        lineImage.widthAnchor.constraint(equalToConstant: 18).isActive = true
        widthRow.addArrangedSubview(lineImage)

        widthSlider.target = self
        widthSlider.action = #selector(lineWidthChanged(_:))
        widthSlider.isContinuous = true
        widthSlider.numberOfTickMarks = 0
        widthSlider.allowsTickMarkValuesOnly = false
        widthSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        widthSlider.setAccessibilityLabel("线条粗细")
        widthSlider.setAccessibilityHelp("可在 1 到 24 像素之间连续调节")
        widthSlider.setAccessibilityIdentifier("screenshot.style.line-width")
        widthSlider.onTrackingBegan = { [weak self] in
            self?.canvas?.beginLineWidthAdjustment()
        }
        widthSlider.onTrackingEnded = { [weak self] in
            self?.canvas?.endLineWidthAdjustment()
        }
        widthRow.addArrangedSubview(widthSlider)

        widthValueLabel.alignment = .right
        widthValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        widthValueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        widthValueLabel.setAccessibilityIdentifier("screenshot.style.line-width-value")
        widthRow.addArrangedSubview(widthValueLabel)
        styleStack.addArrangedSubview(widthRow)

        let controller = NSViewController()
        controller.view = root
        stylePopover.contentViewController = controller
        stylePopover.behavior = .transient
        stylePopover.animates = false
        stylePopover.delegate = self
        stylePopover.contentSize = root.frame.size
    }

    private func buildCornerRadiusPopover() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 238, height: 50))
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.topAnchor.constraint(equalTo: root.topAnchor),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let radiusImage = NSImageView(image: NSImage(
            systemSymbolName: "rectangle.roundedtop",
            accessibilityDescription: "选区圆角"
        ) ?? NSImage(size: NSSize(width: 16, height: 16)))
        radiusImage.contentTintColor = .labelColor
        radiusImage.setAccessibilityElement(false)
        radiusImage.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(radiusImage)

        cornerRadiusSlider.target = self
        cornerRadiusSlider.action = #selector(cornerRadiusChanged(_:))
        cornerRadiusSlider.isContinuous = true
        cornerRadiusSlider.numberOfTickMarks = 0
        cornerRadiusSlider.allowsTickMarkValuesOnly = false
        cornerRadiusSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        cornerRadiusSlider.setAccessibilityLabel("选区圆角")
        cornerRadiusSlider.setAccessibilityHelp("拖动以调整截图四个角的圆角")
        cornerRadiusSlider.setAccessibilityIdentifier("screenshot.crop.corner-radius-slider")
        cornerRadiusSlider.onTrackingBegan = { [weak self] in
            self?.canvas?.beginCornerRadiusAdjustment()
        }
        cornerRadiusSlider.onTrackingEnded = { [weak self] in
            self?.canvas?.endCornerRadiusAdjustment()
        }
        row.addArrangedSubview(cornerRadiusSlider)

        cornerRadiusValueLabel.alignment = .right
        cornerRadiusValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        cornerRadiusValueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        cornerRadiusValueLabel.setAccessibilityIdentifier("screenshot.crop.corner-radius-value")
        row.addArrangedSubview(cornerRadiusValueLabel)

        let controller = NSViewController()
        controller.view = root
        cornerRadiusPopover.contentViewController = controller
        cornerRadiusPopover.behavior = .transient
        cornerRadiusPopover.animates = false
        cornerRadiusPopover.delegate = self
        cornerRadiusPopover.contentSize = root.frame.size
    }

    private func buildSaveMenu() {
        saveMenu.autoenablesItems = false
        saveMenu.addItem(saveMenuItem(
            title: "PNG",
            symbol: "doc.richtext",
            tag: Tag.savePNG
        ))
        saveMenu.addItem(saveMenuItem(
            title: "JPEG (质量 0.95)",
            symbol: "photo",
            tag: Tag.saveJPEG
        ))
    }

    private func saveMenuItem(title: String, symbol: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(saveMenuItemPressed(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func addCommandButton(
        symbol: String,
        tooltip: String,
        tag: Int,
        identifier: String
    ) {
        let button = iconButton(
            symbol: symbol,
            tooltip: tooltip,
            tag: tag,
            isToggle: false,
            identifier: identifier
        )
        commandButtons[tag] = button
        stack.addArrangedSubview(button)
    }

    private func iconButton(
        symbol: String,
        tooltip: String,
        tag: Int,
        isToggle: Bool,
        identifier: String
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let button = NSButton(image: image, target: self, action: #selector(buttonPressed(_:)))
        button.tag = tag
        button.toolTip = tooltip
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(isToggle ? .toggle : .momentaryPushIn)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.setAccessibilityLabel(tooltip)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    private func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(separator)
    }

    private func updateStyleButton() {
        styleButton.image = stylePreviewImage(
            color: currentColor,
            lineWidth: currentLineWidth,
            showsLineWidth: styleVisibility.showsLineWidth,
            mapsArrowShaftWidth: usesArrowLineWidthMapping
        )
        let value = styleDescription()
        styleButton.toolTip = "当前样式：\(value)"
        styleButton.setAccessibilityValue(value)
    }

    private func updateStylePopoverContent() {
        colorRow.isHidden = !styleVisibility.showsColor
        widthRow.isHidden = !styleVisibility.showsLineWidth

        for (color, button) in colorButtons {
            let selected = color == currentColor
            button.state = selected ? .on : .off
            button.image = swatchImage(color: color, selected: selected)
            button.setAccessibilityValue(selected ? "已选择" : "未选择")
        }

        widthSlider.integerValue = currentLineWidth
        let lineWidthText = displayedLineWidthText(currentLineWidth)
        let lineWidthDescription = lineWidthDescription(currentLineWidth)
        widthValueLabel.stringValue = lineWidthText
        widthValueLabel.setAccessibilityValue(lineWidthDescription)
        widthSlider.setAccessibilityValue(lineWidthDescription)
        widthSlider.setAccessibilityHelp(
            usesArrowLineWidthMapping
                ? "显示并调节最终箭杆的物理像素宽度"
                : "可在 1 到 24 像素之间连续调节"
        )
        stylePopover.contentSize = NSSize(
            width: 236,
            height: styleVisibility.showsColor && styleVisibility.showsLineWidth ? 88 : 50
        )
    }

    private func updateCornerRadiusControl() {
        cornerRadiusButton.isHidden = !hasCrop
        cornerRadiusButton.isEnabled = hasCrop && maximumCornerRadius > 0
        cornerRadiusButton.contentTintColor = currentCornerRadius > 0
            ? .controlAccentColor
            : .labelColor
        cornerRadiusButton.toolTip = "选区圆角：\(currentCornerRadius) px"
        cornerRadiusButton.setAccessibilityValue("\(currentCornerRadius) 像素")

        cornerRadiusSlider.maxValue = Double(max(1, maximumCornerRadius))
        cornerRadiusSlider.integerValue = currentCornerRadius
        cornerRadiusSlider.isEnabled = maximumCornerRadius > 0
        cornerRadiusValueLabel.stringValue = "\(currentCornerRadius) px"
        cornerRadiusSlider.setAccessibilityValue("\(currentCornerRadius) 像素")
    }

    private func presentStylePopover(relativeTo anchor: NSView) {
        guard hasCrop, !styleVisibility.isEmpty, anchor.window != nil else {
            dismissStylePopover()
            return
        }
        updateStylePopoverContent()
        if cornerRadiusPopover.isShown {
            cornerRadiusPopover.close()
        }
        if stylePopover.isShown {
            stylePopover.close()
        }
        stylePopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        startPopoverKeyMonitor()
        let focusTarget: NSView? = styleVisibility.showsLineWidth
            ? widthSlider
            : colorButtons[currentColor]
        if let popoverWindow = stylePopover.contentViewController?.view.window,
           let focusTarget {
            popoverWindow.makeFirstResponder(focusTarget)
            NSAccessibility.post(element: focusTarget, notification: .focusedUIElementChanged)
        } else if let contentView = stylePopover.contentViewController?.view {
            NSAccessibility.post(element: contentView, notification: .layoutChanged)
        }
    }

    private func presentCornerRadiusPopover(relativeTo anchor: NSView) {
        guard hasCrop, maximumCornerRadius > 0, anchor.window != nil else {
            dismissStylePopover()
            return
        }
        updateCornerRadiusControl()
        if stylePopover.isShown {
            stylePopover.close()
        }
        if cornerRadiusPopover.isShown {
            cornerRadiusPopover.close()
        }
        cornerRadiusPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        startPopoverKeyMonitor()
        if let popoverWindow = cornerRadiusPopover.contentViewController?.view.window {
            popoverWindow.makeFirstResponder(cornerRadiusSlider)
            NSAccessibility.post(
                element: cornerRadiusSlider,
                notification: .focusedUIElementChanged
            )
        }
    }

    private var usesArrowLineWidthMapping: Bool {
        selectedAnnotationKind == .arrow
            || (selectedAnnotationKind == nil && currentTool == .arrow)
    }

    private func displayedLineWidth(_ styleWidth: Int) -> CGFloat {
        usesArrowLineWidthMapping
            ? ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: styleWidth)
            : CGFloat(ScreenshotAnnotationStylePolicy.clampedLineWidth(styleWidth))
    }

    private func displayedLineWidthText(_ styleWidth: Int) -> String {
        let width = displayedLineWidth(styleWidth)
        if width.rounded() == width {
            return "\(Int(width)) px"
        }
        return String(format: "%.1f px", Double(width))
    }

    private func lineWidthDescription(_ styleWidth: Int) -> String {
        let prefix = usesArrowLineWidthMapping ? "箭杆" : "粗细"
        return "\(prefix) \(displayedLineWidthText(styleWidth))"
    }

    private func styleDescription() -> String {
        styleDescription(visibility: styleVisibility)
    }

    private func styleDescription(visibility: ScreenshotStyleControlVisibility) -> String {
        if visibility.showsLineWidth {
            return "\(colorName(currentColor))，\(lineWidthDescription(currentLineWidth))"
        }
        return colorName(currentColor)
    }

    func popoverDidClose(_ notification: Notification) {
        if let closedPopover = notification.object as? NSPopover,
           closedPopover === cornerRadiusPopover {
            canvas?.endCornerRadiusAdjustment()
        }
        if !stylePopover.isShown, !cornerRadiusPopover.isShown {
            stopPopoverKeyMonitor()
            canvas?.window?.makeFirstResponder(canvas)
        }
    }

    private func startPopoverKeyMonitor() {
        guard popoverKeyMonitor == nil else { return }
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.stylePopover.isShown || self.cornerRadiusPopover.isShown else { return event }
            return self.handlePopoverKeyDown(event)
        }
    }

    private func stopPopoverKeyMonitor() {
        guard let popoverKeyMonitor else { return }
        NSEvent.removeMonitor(popoverKeyMonitor)
        self.popoverKeyMonitor = nil
    }

    private func handlePopoverKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command), characters == "z" {
            flags.contains(.shift) ? canvas?.redo() : canvas?.undo()
            return nil
        }
        if flags.contains(.command), characters == "y" {
            canvas?.redo()
            return nil
        }
        if flags.contains(.command), characters == "c" {
            canvas?.requestCopy()
            return nil
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            canvas?.deleteSelection()
            return nil
        }
        if event.keyCode == 53 {
            canvas?.endCornerRadiusAdjustment()
            dismissStylePopover()
            return nil
        }
        return event
    }

    private func swatchImage(color: ScreenshotColor, selected: Bool) -> NSImage {
        let fillColor = nsColor(color)
        return NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let outer = rect.insetBy(dx: 1.5, dy: 1.5)
            if selected {
                NSColor.controlAccentColor.setStroke()
                let selectionRing = NSBezierPath(ovalIn: outer)
                selectionRing.lineWidth = 2.5
                selectionRing.stroke()
            }
            let swatchRect = outer.insetBy(dx: 3.5, dy: 3.5)
            fillColor.setFill()
            let swatch = NSBezierPath(ovalIn: swatchRect)
            swatch.fill()
            NSColor.separatorColor.setStroke()
            swatch.lineWidth = 1
            swatch.stroke()
            return true
        }
    }

    private func stylePreviewImage(
        color: ScreenshotColor,
        lineWidth: Int,
        showsLineWidth: Bool,
        mapsArrowShaftWidth: Bool
    ) -> NSImage {
        let strokeColor = nsColor(color)
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.windowBackgroundColor.withAlphaComponent(0.42).setFill()
            background.fill()
            NSColor.separatorColor.setStroke()
            background.lineWidth = 1
            background.stroke()

            if showsLineWidth {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 4, y: 5))
                path.line(to: NSPoint(x: 16, y: 15))
                path.lineCapStyle = .round
                let sourceWidth = mapsArrowShaftWidth
                    ? ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: lineWidth)
                    : CGFloat(ScreenshotAnnotationStylePolicy.clampedLineWidth(lineWidth))
                let maximumWidth = mapsArrowShaftWidth
                    ? ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 24)
                    : 24
                path.lineWidth = 1 + (sourceWidth - 1) / max(1, maximumWidth - 1) * 5
                strokeColor.setStroke()
                path.stroke()
            } else {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: strokeColor
                ]
                ("A" as NSString).draw(at: NSPoint(x: 5.5, y: 2.5), withAttributes: attributes)
            }
            return true
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let canvas else { return }
        switch sender.tag {
        case Tag.toolBase..<(Tag.toolBase + ScreenshotTool.allCases.count):
            guard let tool = ScreenshotTool(rawValue: sender.tag - Tag.toolBase) else { return }
            canvas.chooseTool(tool)
        case Tag.style:
            presentStylePopover(relativeTo: sender)
        case Tag.cornerRadius:
            presentCornerRadiusPopover(relativeTo: sender)
        case Tag.undo:
            canvas.undo()
        case Tag.redo:
            canvas.redo()
        case Tag.delete:
            canvas.deleteSelection()
        case Tag.copy:
            canvas.requestCopy()
        case Tag.save:
            saveMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        case Tag.cancel:
            canvas.requestCancel()
        default:
            break
        }
    }

    @objc private func colorPressed(_ sender: NSButton) {
        guard let color = ScreenshotColor(rawValue: sender.tag - Tag.colorBase) else { return }
        canvas?.chooseColor(color)
    }

    @objc private func lineWidthChanged(_ sender: NSSlider) {
        let value = ScreenshotAnnotationStylePolicy.clampedLineWidth(sender.integerValue)
        let description = lineWidthDescription(value)
        widthValueLabel.stringValue = displayedLineWidthText(value)
        widthValueLabel.setAccessibilityValue(description)
        widthSlider.setAccessibilityValue(description)
        if widthSlider.isTrackingWithMouse {
            canvas?.previewLineWidth(value)
        } else {
            canvas?.chooseLineWidth(value)
        }
    }

    @objc private func cornerRadiusChanged(_ sender: NSSlider) {
        let value = min(max(0, sender.integerValue), maximumCornerRadius)
        cornerRadiusValueLabel.stringValue = "\(value) px"
        if cornerRadiusSlider.isTrackingWithMouse {
            canvas?.previewCornerRadius(value)
        } else {
            canvas?.chooseCornerRadius(value)
        }
    }

    @objc private func saveMenuItemPressed(_ sender: NSMenuItem) {
        let format: ScreenshotOutputFormat
        switch sender.tag {
        case Tag.savePNG:
            format = .png
        case Tag.saveJPEG:
            format = .jpeg
        default:
            return
        }
        saveMenu.cancelTracking()
        DispatchQueue.main.async { [weak canvas] in
            canvas?.requestSave(format: format)
        }
    }

    private func colorName(_ color: ScreenshotColor) -> String {
        switch color {
        case .red: return "红色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .white: return "白色"
        case .black: return "黑色"
        }
    }

    private func nsColor(_ color: ScreenshotColor) -> NSColor {
        NSColor(cgColor: color.cgColor) ?? .systemRed
    }
}

@MainActor
private final class ScreenshotTrackingSlider: NSSlider {
    var onTrackingBegan: (() -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var isTrackingWithMouse = false

    override func mouseDown(with event: NSEvent) {
        isTrackingWithMouse = true
        onTrackingBegan?()
        super.mouseDown(with: event)
        onTrackingEnded?()
        isTrackingWithMouse = false
    }
}
