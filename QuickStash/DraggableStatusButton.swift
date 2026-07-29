import Cocoa

class DraggableStatusButton: NSView {
    private(set) var isDropEnabled = true
    var onFilesDropped: (([URL]) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private let imageView = NSImageView()
    private var acceptsCurrentDrag = false
    private var hoverGate = StatusItemHoverGate()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: "QuickStash")
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true

        imageView.image = configured
        imageView.imageScaling = .scaleNone
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        registerForDraggedTypes([.fileURL])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverGate.shouldPresentOnEnter(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else { return }
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        hoverGate.pointerExited()
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }

    func setDropEnabled(_ enabled: Bool) {
        guard isDropEnabled != enabled else { return }
        isDropEnabled = enabled
        if !enabled {
            resetDragState()
        }
    }

    func suppressHoverUntilPointerExit() {
        hoverGate.suppressUntilPointerExit()
    }

    // MARK: - Dragging Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isDropEnabled else { return [] }
        acceptsCurrentDrag = sender.draggingPasteboard.availableType(from: [.fileURL]) != nil
        if acceptsCurrentDrag {
            imageView.contentTintColor = .systemBlue
            DispatchQueue.main.async { [weak self] in
                guard self?.acceptsCurrentDrag == true else { return }
                self?.onDragEntered?()
            }
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropEnabled && acceptsCurrentDrag ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        resetDragState()
        DispatchQueue.main.async { [weak self] in
            guard self?.acceptsCurrentDrag == false else { return }
            self?.onDragExited?()
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isDropEnabled else {
            resetDragState()
            return false
        }
        let urls = DragPasteboardReader.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        resetDragState()
        DispatchQueue.main.async { [weak self] in
            self?.onFilesDropped?(urls)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        resetDragState()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        resetDragState()
        DispatchQueue.main.async { [weak self] in
            guard self?.acceptsCurrentDrag == false else { return }
            self?.onDragExited?()
        }
    }

    private func resetDragState() {
        acceptsCurrentDrag = false
        imageView.contentTintColor = nil
    }
}
