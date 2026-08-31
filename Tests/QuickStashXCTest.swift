import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import QuickStash

@MainActor
private final class ScreenshotEventTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class ScreenshotCanvasDelegateStub: ScreenshotCanvasDelegate {
    private(set) var activationCount = 0
    private(set) var mutationCount = 0
    private(set) var copyCount = 0

    func screenshotCanvasDidActivate(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot?
    ) {
        activationCount += 1
    }

    func screenshotCanvasDidMutate(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot?
    ) {
        mutationCount += 1
    }

    func screenshotCanvasDidRequestCancel(
        canvas: ScreenshotCanvasView,
        generation: UInt64
    ) {}

    func screenshotCanvasDidRequestCopy(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot
    ) {
        copyCount += 1
    }

    func screenshotCanvasDidRequestSave(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot,
        format: ScreenshotOutputFormat
    ) {}
}

@MainActor
private final class DraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 0 }
        set {}
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(
        atDestination dropDestination: URL
    ) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (
            NSDraggingItem,
            Int,
            UnsafeMutablePointer<ObjCBool>
        ) -> Void
    ) {}

    func resetSpringLoading() {}
}

final class QuickStashScreenshotXCTests: XCTestCase {
    @MainActor private static var retainedEventWindows: [NSWindow] = []

    @MainActor
    func testHostedAppSkipsProductionRuntimeUI() throws {
        XCTAssertEqual(ProcessInfo.processInfo.environment["QUICKSTASH_TEST_MODE"], "1")
        XCTAssertTrue(QuickStashApp.isRunningHostedTests)
        let appDelegate = try XCTUnwrap(NSApp.delegate as? QuickStashApp)
        XCTAssertNil(appDelegate.statusItem)
        XCTAssertNil(appDelegate.hoverWindow)
        XCTAssertNil(appDelegate.floatingWindow)
        XCTAssertNil(appDelegate.dropOverlayWindow)
    }

    @MainActor
    func testClipboardRealtimeTextLinkAndPreparedImageRecording() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let suite = "QuickStashXCTest.clipboard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        var received: [StashItem] = []
        let textExpectation = expectation(description: "plain clipboard text")
        let linkExpectation = expectation(description: "explicit clipboard URL")
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: SystemClipboardPasteboard(pasteboard: pasteboard),
            pollingInterval: 0.05,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/hosted-prepared-\(data.count)-\(UUID().uuidString).png",
                    preview: "hosted prepared image",
                    createdAt: observedAt,
                    managedOrigin: .imported
                )
            },
            imageDiscarder: { _ in }
        )
        monitor.onNewItem = { item in
            received.append(item)
            if item.content == "hosted clipboard text" {
                textExpectation.fulfill()
            } else if item.content == "https://example.com/hosted-url" {
                linkExpectation.fulfill()
            }
        }
        monitor.setConsent(.enabled)
        monitor.startMonitoring()
        addTeardownBlock { @MainActor in
            await monitor.shutdownAndDrain(waitForPayloadReads: true)
            defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("hosted clipboard text", forType: .string))
        await fulfillment(of: [textExpectation], timeout: 2)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("https://example.com/hosted-url", forType: .URL))
        await fulfillment(of: [linkExpectation], timeout: 2)

        monitor.setConsent(.disabled)
        let prepared = try await monitor.prepareImageRecord(data: Data([1, 2, 3]))
        let preparedDidCommit = await monitor.commitPreparedImageRecord(prepared)
        let preparedDidCommitAgain = await monitor.commitPreparedImageRecord(prepared)
        XCTAssertTrue(preparedDidCommit)
        XCTAssertFalse(preparedDidCommitAgain)

        XCTAssertEqual(received.map(\.type), [.text, .url, .image])
        XCTAssertTrue(received.allSatisfy { $0.managedOrigin == .clipboard })
    }

    @MainActor
    func testScreenshotOverlayWindowInitializesForEveryConnectedScreen() throws {
        let source = try makeSourceImage(width: 4, height: 4)
        let delegate = ScreenshotCanvasDelegateStub()

        XCTAssertFalse(NSScreen.screens.isEmpty)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                XCTFail("Connected screen did not expose NSScreenNumber")
                continue
            }

            let controller = ScreenshotOverlayController(
                capture: CapturedDisplay(
                    displayID: CGDirectDisplayID(number.uint32Value),
                    image: source
                ),
                screen: screen,
                generation: 1,
                delegate: delegate
            )
            XCTAssertTrue(controller.window.targetScreen === screen)
            XCTAssertEqual(controller.window.frame, screen.frame)
            XCTAssertTrue(controller.window.contentView === controller.canvas)
            controller.close()
        }
    }

    func testDragPresentationGateInvalidatesHideTokensAcrossSuspension() {
        var gate = DragPresentationGate()

        XCTAssertTrue(gate.showOverlay())
        let initialHideToken = gate.makeHideToken()
        XCTAssertTrue(gate.acceptsHideToken(initialHideToken))

        gate.setSuspended(true)
        XCTAssertTrue(gate.isSuspended)
        XCTAssertFalse(gate.isOverlayVisible)
        XCTAssertFalse(gate.acceptsHideToken(initialHideToken))
        XCTAssertFalse(gate.showOverlay())

        gate.setSuspended(false)
        XCTAssertTrue(gate.showOverlay())
        let resumedHideToken = gate.makeHideToken()
        XCTAssertTrue(gate.acceptsHideToken(resumedHideToken))
        XCTAssertFalse(gate.acceptsHideToken(initialHideToken))

        gate.invalidatePendingHide()
        XCTAssertFalse(gate.acceptsHideToken(resumedHideToken))
        XCTAssertTrue(gate.hideOverlay())
    }

    @MainActor
    func testDragProximityArmsInvisibleTargetUntilFileDragConfirmation() {
        var gate = DragPresentationGate()
        let window = DropOverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220))
        defer { window.close() }

        XCTAssertTrue(gate.armDropTarget())
        XCTAssertTrue(gate.isDropTargetArmed)
        XCTAssertFalse(gate.isOverlayVisible)
        XCTAssertFalse(window.isPresentationVisible)
        XCTAssertFalse(window.hasShadow)

        XCTAssertTrue(gate.showOverlay())
        window.setPresentationVisible(true)
        XCTAssertTrue(gate.isOverlayVisible)
        XCTAssertTrue(window.isPresentationVisible)
        XCTAssertTrue(window.hasShadow)

        XCTAssertTrue(gate.hideOverlay())
        window.setPresentationVisible(false)
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(window.isPresentationVisible)
        XCTAssertFalse(window.hasShadow)
    }

    @MainActor
    func testDropOverlayRejectsNonFileDragWithoutPresentation() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("not a file", forType: .string))

        let sender = DraggingInfoStub(pasteboard: pasteboard)
        let window = DropOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220)
        )
        defer { window.close() }
        let dropView = try XCTUnwrap(window.contentView)
        var enteredCount = 0
        var droppedCount = 0
        window.onDragEntered = {
            enteredCount += 1
            window.setPresentationVisible(true)
        }
        window.onFilesDropped = { _ in droppedCount += 1 }

        XCTAssertEqual(dropView.draggingEntered(sender), [])
        XCTAssertEqual(dropView.draggingUpdated(sender), [])
        XCTAssertFalse(dropView.performDragOperation(sender))
        await drainMainQueue()

        XCTAssertEqual(enteredCount, 0)
        XCTAssertEqual(droppedCount, 0)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.isPresentationVisible)
        XCTAssertFalse(window.hasShadow)
    }

    @MainActor
    func testDropOverlayFileDragPresentsAndDraggingEndedCleansUp() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let sourceURL = URL(fileURLWithPath: "/tmp/QuickStash-drop-test.txt")
        XCTAssertTrue(pasteboard.setString(sourceURL.absoluteString, forType: .fileURL))

        let sender = DraggingInfoStub(pasteboard: pasteboard)
        let window = DropOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220)
        )
        defer { window.close() }
        let dropView = try XCTUnwrap(window.contentView)
        var enteredCount = 0
        var exitedCount = 0
        window.onDragEntered = {
            enteredCount += 1
            window.setPresentationVisible(true)
        }
        window.onDragExited = {
            exitedCount += 1
            window.setPresentationVisible(false)
        }

        XCTAssertEqual(dropView.draggingEntered(sender), .copy)
        XCTAssertEqual(dropView.draggingUpdated(sender), .copy)
        await drainMainQueue()

        XCTAssertEqual(enteredCount, 1)
        XCTAssertTrue(window.isPresentationVisible)
        XCTAssertTrue(window.hasShadow)

        dropView.draggingEnded(sender)
        await drainMainQueue()

        XCTAssertEqual(exitedCount, 1)
        XCTAssertFalse(window.isPresentationVisible)
        XCTAssertFalse(window.hasShadow)
    }

    @MainActor
    func testInvisibleOverlayResetCancelsPendingFileDragPresentation() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let sourceURL = URL(fileURLWithPath: "/tmp/QuickStash-pending-drop-test.txt")
        XCTAssertTrue(pasteboard.setString(sourceURL.absoluteString, forType: .fileURL))

        let sender = DraggingInfoStub(pasteboard: pasteboard)
        let window = DropOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220)
        )
        defer { window.close() }
        let dropView = try XCTUnwrap(window.contentView)
        var enteredCount = 0
        window.onDragEntered = { enteredCount += 1 }

        XCTAssertEqual(dropView.draggingEntered(sender), .copy)
        XCTAssertTrue(window.hasActiveFileDrag)

        // Screenshot suspension can hide an already-invisible armed window before
        // the queued drag-enter callback runs. Hiding must invalidate that callback.
        window.setPresentationVisible(false)
        XCTAssertFalse(window.hasActiveFileDrag)
        await drainMainQueue()

        XCTAssertEqual(enteredCount, 0)
        XCTAssertFalse(window.isPresentationVisible)
        XCTAssertFalse(window.hasShadow)
    }

    func testStatusItemHoverIsSuppressedWhileAnyMouseButtonIsPressed() {
        XCTAssertTrue(StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 0))
        XCTAssertFalse(StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 1))
        XCTAssertFalse(StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 2))
        XCTAssertFalse(StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 3))
    }

    func testStatusItemHoverSuppressionSurvivesReleaseUntilPointerExit() {
        var gate = StatusItemHoverGate()

        XCTAssertFalse(gate.shouldPresentOnEnter(pressedMouseButtons: 1))
        XCTAssertTrue(gate.isSuppressedUntilPointerExit)
        XCTAssertFalse(gate.shouldPresentOnEnter(pressedMouseButtons: 0))

        gate.pointerExited()
        XCTAssertFalse(gate.isSuppressedUntilPointerExit)
        XCTAssertTrue(gate.shouldPresentOnEnter(pressedMouseButtons: 0))

        gate.suppressUntilPointerExit()
        XCTAssertFalse(gate.shouldPresentOnEnter(pressedMouseButtons: 0))
        gate.pointerExited()
    }

    @MainActor
    func testStatusItemTrackingAndArmedWatchdogPolicies() {
        let button = DraggableStatusButton(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
        button.updateTrackingAreas()
        XCTAssertTrue(
            button.trackingAreas.contains { $0.options.contains(.enabledDuringMouseDrag) }
        )

        XCTAssertTrue(
            ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: false,
                hasActiveFileDrag: false,
                pressedMouseButtons: 0
            )
        )
        XCTAssertFalse(
            ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: true,
                hasActiveFileDrag: false,
                pressedMouseButtons: 0
            )
        )
        XCTAssertFalse(
            ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: false,
                hasActiveFileDrag: false,
                pressedMouseButtons: 1
            )
        )
        XCTAssertFalse(
            ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: false,
                hasActiveFileDrag: true,
                pressedMouseButtons: 0
            )
        )
    }

    func testScreenshotGeometryMapsPhysicalPixelsAndProvidesEightHandles() {
        let imageSize = PixelSize(width: 1_500, height: 750)
        let pixel = ScreenshotGeometry.pixelPoint(
            fromViewPoint: CGPoint(x: 250, y: 125),
            viewSize: CGSize(width: 500, height: 250),
            imageSize: imageSize,
            isViewFlipped: true
        )
        XCTAssertEqual(pixel, PixelPoint(x: 750, y: 375))
        XCTAssertEqual(
            ScreenshotGeometry.viewPoint(
                fromPixelPoint: pixel,
                viewSize: CGSize(width: 500, height: 250),
                imageSize: imageSize,
                isViewFlipped: true
            ),
            CGPoint(x: 250, y: 125)
        )

        let rect = PixelRect(x: 20, y: 30, width: 40, height: 50)
        let handles = ScreenshotGeometry.handlePoints(for: rect)
        XCTAssertEqual(ScreenshotResizeHandle.allCases.count, 8)
        XCTAssertEqual(handles.count, 8)
        XCTAssertEqual(handles[.topLeft], PixelPoint(x: 20, y: 30))
        XCTAssertEqual(handles[.top], PixelPoint(x: 40, y: 30))
        XCTAssertEqual(handles[.topRight], PixelPoint(x: 60, y: 30))
        XCTAssertEqual(handles[.right], PixelPoint(x: 60, y: 55))
        XCTAssertEqual(handles[.bottomRight], PixelPoint(x: 60, y: 80))
        XCTAssertEqual(handles[.bottom], PixelPoint(x: 40, y: 80))
        XCTAssertEqual(handles[.bottomLeft], PixelPoint(x: 20, y: 80))
        XCTAssertEqual(handles[.left], PixelPoint(x: 20, y: 55))
    }

    func testScreenshotStyleControlsAreContextualAndAcceptNonPresetWidths() {
        XCTAssertEqual(ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 4), 4, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 8), 5.2, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 16), 7.6, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 24), 10, accuracy: 0.0001)
        XCTAssertEqual(ScreenshotAnnotationStylePolicy.clampedLineWidth(-1), 1)
        XCTAssertEqual(ScreenshotAnnotationStylePolicy.clampedLineWidth(7), 7)
        XCTAssertEqual(ScreenshotAnnotationStylePolicy.clampedLineWidth(100), 24)

        XCTAssertEqual(
            ScreenshotAnnotationStylePolicy.controls(for: .arrow, selectedAnnotationKind: nil),
            ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: true)
        )
        XCTAssertEqual(
            ScreenshotAnnotationStylePolicy.controls(for: .text, selectedAnnotationKind: nil),
            ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: false)
        )
        XCTAssertTrue(
            ScreenshotAnnotationStylePolicy.controls(for: .mosaic, selectedAnnotationKind: nil).isEmpty
        )
        XCTAssertEqual(
            ScreenshotAnnotationStylePolicy.controls(
                for: .select,
                selectedAnnotationKind: .rectangle
            ),
            ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: true)
        )
        XCTAssertTrue(
            ScreenshotAnnotationStylePolicy.controls(
                for: .select,
                selectedAnnotationKind: .mosaic
            ).isEmpty
        )
    }

    func testWindowCornerRadiusUsesPhysicalPixelsAndRejectsFalseFourCornerSlices() {
        let display = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let window = CGRect(x: 100, y: 120, width: 640, height: 480)
        XCTAssertEqual(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: window,
                displayFrame: display,
                imageSize: PixelSize(width: 1_920, height: 1_080),
                pixelRect: PixelRect(x: 100, y: 120, width: 640, height: 480)
            ),
            10
        )
        XCTAssertEqual(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: window,
                displayFrame: display,
                imageSize: PixelSize(width: 3_840, height: 2_160),
                pixelRect: PixelRect(x: 200, y: 240, width: 1_280, height: 960)
            ),
            20
        )
        XCTAssertEqual(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: CGRect(x: -100, y: 120, width: 640, height: 480),
                displayFrame: display,
                imageSize: PixelSize(width: 1_920, height: 1_080),
                pixelRect: PixelRect(x: 0, y: 120, width: 540, height: 480)
            ),
            0
        )
        XCTAssertEqual(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: display,
                displayFrame: display,
                imageSize: PixelSize(width: 1_920, height: 1_080),
                pixelRect: PixelRect(x: 0, y: 0, width: 1_920, height: 1_080)
            ),
            0
        )

        let roundedRect = PixelRect(x: 10, y: 20, width: 100, height: 80)
        XCTAssertFalse(ScreenshotGeometry.roundedRectContains(
            PixelPoint(x: 10, y: 20),
            rect: roundedRect,
            cornerRadius: 20
        ))
        XCTAssertTrue(ScreenshotGeometry.roundedRectContains(
            PixelPoint(x: 30, y: 20),
            rect: roundedRect,
            cornerRadius: 20
        ))
        XCTAssertTrue(ScreenshotGeometry.roundedRectContains(
            PixelPoint(x: 60, y: 60),
            rect: roundedRect,
            cornerRadius: 20
        ))
        XCTAssertTrue(ScreenshotGeometry.roundedRectContains(
            PixelPoint(x: 10, y: 20),
            rect: roundedRect,
            cornerRadius: 0
        ))
    }

    @MainActor
    func testScreenshotToolbarUsesTitlelessColorSwatchesAndClearTooltips() {
        let toolbar = ScreenshotToolbarView(frame: .zero)
        let colorButtons = toolbar.testingColorButtons

        XCTAssertEqual(colorButtons.count, ScreenshotColor.allCases.count)
        for button in colorButtons {
            XCTAssertTrue(button.title.isEmpty)
            XCTAssertTrue(button.alternateTitle.isEmpty)
            XCTAssertTrue(button.attributedTitle.string.isEmpty)
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertLessThanOrEqual(button.fittingSize.width, 28)
        }

        XCTAssertEqual(toolbar.testingTextToolTooltip, "文字")
        XCTAssertEqual(toolbar.testingFreehandToolTooltip, "涂鸦")
    }

    @MainActor
    func testScreenshotCanvasInstallsToolbarWithAUsableInitialSize() throws {
        let source = try makeSourceImage(width: 100, height: 80)
        let delegate = ScreenshotCanvasDelegateStub()
        let canvas = ScreenshotCanvasView(
            source: source,
            displayID: 1,
            generation: 1,
            delegate: delegate
        )

        let toolbar = try XCTUnwrap(
            canvas.subviews.first(where: { $0 is ScreenshotToolbarView })
                as? ScreenshotToolbarView
        )
        XCTAssertGreaterThanOrEqual(toolbar.frame.width, 44)
        XCTAssertGreaterThanOrEqual(toolbar.frame.height, 42)
        XCTAssertTrue(toolbar.testingCornerRadiusButton.isHidden)

        canvas.installTestingState(
            crop: PixelRect(x: 5, y: 5, width: 80, height: 60),
            annotations: [],
            selectedAnnotationID: nil,
            cornerRadius: 12
        )
        XCTAssertFalse(toolbar.testingCornerRadiusButton.isHidden)
        XCTAssertEqual(toolbar.testingCornerRadiusButton.toolTip, "选区圆角：12 px")
        XCTAssertEqual(toolbar.testingCornerRadiusSlider.maxValue, 30)
        XCTAssertEqual(toolbar.testingCornerRadiusSlider.integerValue, 12)

        toolbar.update(
            tool: .arrow,
            color: .red,
            lineWidth: 24,
            cornerRadius: 12,
            maximumCornerRadius: 30,
            hasCrop: true,
            selectedAnnotationKind: nil,
            canUndo: false,
            canRedo: false
        )
        XCTAssertEqual(toolbar.testingLineWidthValueLabel.stringValue, "10 px")
        XCTAssertTrue(toolbar.testingStyleButton.toolTip?.contains("箭杆 10 px") == true)
        XCTAssertEqual(toolbar.testingLineWidthSlider.accessibilityValue() as? String, "箭杆 10 px")
    }

    func testOutsideCompletionDistinguishesClicksFromDrags() {
        let anchor = CGPoint(x: 40, y: 30)

        XCTAssertTrue(ScreenshotGeometry.isClickGesture(from: anchor, to: anchor))
        XCTAssertTrue(ScreenshotGeometry.isClickGesture(
            from: anchor,
            to: CGPoint(x: 43, y: 30)
        ))
        XCTAssertTrue(ScreenshotGeometry.isClickGesture(
            from: anchor,
            to: CGPoint(x: 42, y: 32)
        ))
        XCTAssertFalse(ScreenshotGeometry.isClickGesture(
            from: anchor,
            to: CGPoint(x: 43, y: 31)
        ))
        XCTAssertFalse(ScreenshotGeometry.isClickGesture(
            from: anchor,
            to: CGPoint(x: 55, y: 30)
        ))
    }

    @MainActor
    func testCanvasWindowSnapOutsideCompletionAndInactiveDisplaySafety() throws {
        let source = try makeSourceImage(width: 100, height: 100)
        let delegate = ScreenshotCanvasDelegateStub()
        let snappedRegion = ScreenshotWindowRegion(
            windowID: 7,
            pixelRect: PixelRect(x: 10, y: 12, width: 55, height: 48),
            order: 0,
            cornerRadius: 12
        )
        let canvas = ScreenshotCanvasView(
            source: source,
            displayID: 1,
            generation: 1,
            windowRegions: [snappedRegion],
            delegate: delegate
        )
        let window = makeWindow(for: canvas, size: CGSize(width: 1_000, height: 700))

        sendMouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 20, y: 20), to: canvas, window: window)
        XCTAssertEqual(canvas.snapshot.crop, snappedRegion.pixelRect)
        XCTAssertEqual(canvas.snapshot.cornerRadius, 12)
        XCTAssertEqual(delegate.mutationCount, 1)

        let baselineUndoDepth = canvas.testingUndoDepth
        canvas.beginCornerRadiusAdjustment()
        XCTAssertEqual(delegate.mutationCount, 2)
        for radius in 13...20 {
            canvas.previewCornerRadius(radius)
        }
        XCTAssertEqual(canvas.snapshot.cornerRadius, 20)
        XCTAssertEqual(canvas.testingUndoDepth, baselineUndoDepth)
        XCTAssertEqual(delegate.mutationCount, 2)
        canvas.endCornerRadiusAdjustment()
        XCTAssertEqual(canvas.testingUndoDepth, baselineUndoDepth + 1)
        XCTAssertEqual(delegate.mutationCount, 2)
        canvas.undo()
        XCTAssertEqual(canvas.snapshot.cornerRadius, 12)
        canvas.redo()
        XCTAssertEqual(canvas.snapshot.cornerRadius, 20)

        sendMouse(.leftMouseDown, at: CGPoint(x: 12, y: 14), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 12, y: 14), to: canvas, window: window)
        XCTAssertEqual(delegate.copyCount, 1)

        sendMouse(.leftMouseDown, at: CGPoint(x: 90, y: 90), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 90, y: 90), to: canvas, window: window)
        XCTAssertEqual(delegate.copyCount, 2)

        canvas.setDisplayActive(false)
        sendMouse(.leftMouseDown, at: CGPoint(x: 90, y: 90), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 90, y: 90), to: canvas, window: window)
        XCTAssertEqual(delegate.activationCount, 4)
        XCTAssertEqual(delegate.copyCount, 2)
    }

    @MainActor
    func testCanvasOutsideDragDoesNotCopyAndFreehandUsesSelectedStyle() throws {
        let source = try makeSourceImage(width: 100, height: 100)
        let delegate = ScreenshotCanvasDelegateStub()
        let canvas = ScreenshotCanvasView(
            source: source,
            displayID: 1,
            generation: 1,
            delegate: delegate
        )
        let window = makeWindow(for: canvas, size: CGSize(width: 1_000, height: 700))
        canvas.installTestingState(
            crop: PixelRect(x: 10, y: 10, width: 70, height: 70),
            annotations: [],
            selectedAnnotationID: nil
        )

        sendMouse(.leftMouseDown, at: CGPoint(x: 90, y: 90), to: canvas, window: window)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 4, y: 4), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 4, y: 4), to: canvas, window: window)
        XCTAssertEqual(delegate.copyCount, 0)

        canvas.installTestingState(
            crop: PixelRect(x: 10, y: 10, width: 80, height: 80),
            annotations: [],
            selectedAnnotationID: nil,
            tool: .freehand
        )
        canvas.chooseColor(.blue)
        canvas.chooseLineWidth(12)
        sendMouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), to: canvas, window: window)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 35, y: 30), to: canvas, window: window)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 50, y: 24), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 60, y: 40), to: canvas, window: window)

        let freehand = try XCTUnwrap(canvas.snapshot.annotations.last)
        XCTAssertEqual(freehand.kind, .freehand)
        XCTAssertEqual(freehand.color, .blue)
        XCTAssertEqual(freehand.lineWidth, 12)
        XCTAssertGreaterThanOrEqual(freehand.points.count, 3)

        let thickFreehand = ScreenshotAnnotation(
            kind: .freehand,
            start: PixelPoint(x: 20, y: 50),
            end: PixelPoint(x: 80, y: 50),
            color: .green,
            lineWidth: 24,
            points: [PixelPoint(x: 20, y: 50), PixelPoint(x: 80, y: 50)]
        )
        canvas.installTestingState(
            crop: PixelRect(x: 10, y: 10, width: 80, height: 80),
            annotations: [thickFreehand],
            selectedAnnotationID: nil,
            tool: .select
        )
        sendMouse(.leftMouseDown, at: CGPoint(x: 50, y: 61), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 50, y: 61), to: canvas, window: window)
        XCTAssertEqual(canvas.testingSelectedAnnotationID, thickFreehand.id)
    }

    func testLineWidthAdjustmentTransactionAndPhysicalPixelPreview() {
        let rectangle = ScreenshotAnnotation(
            kind: .rectangle,
            start: PixelPoint(x: 10, y: 10),
            end: PixelPoint(x: 70, y: 50),
            color: .red,
            lineWidth: 4
        )
        var adjustment = ScreenshotLineWidthAdjustment(
            annotations: [rectangle],
            selectedAnnotationID: rectangle.id,
            lineWidth: rectangle.lineWidth
        )
        for width in [3, 7, 13, 21] {
            adjustment.preview(width)
        }
        XCTAssertEqual(adjustment.originalLineWidth, 4)
        XCTAssertEqual(adjustment.previewLineWidth, 21)
        XCTAssertEqual(adjustment.previewAnnotations.first?.lineWidth, 21)

        var history = ScreenshotEditHistory(maximumDepth: 100)
        history.commit([rectangle])
        let baselineUndoDepth = history.undoStack.count
        history.commit(adjustment.previewAnnotations)
        XCTAssertEqual(history.undoStack.count, baselineUndoDepth + 1)
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.annotations, [rectangle])

        var defaultOnlyAdjustment = ScreenshotLineWidthAdjustment(
            annotations: [rectangle],
            selectedAnnotationID: nil,
            lineWidth: 4
        )
        defaultOnlyAdjustment.preview(12)
        XCTAssertFalse(defaultOnlyAdjustment.hasAnnotationChange)
        XCTAssertEqual(defaultOnlyAdjustment.previewLineWidth, 12)
        XCTAssertEqual(
            ScreenshotGeometry.viewLineWidth(
                sourcePixelWidth: 1,
                sourceWidth: 2_000,
                viewWidth: 1_000,
                backingScaleFactor: 2
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ScreenshotGeometry.viewLineWidth(
                sourcePixelWidth: 13,
                sourceWidth: 2_000,
                viewWidth: 1_000,
                backingScaleFactor: 2
            ),
            6.5,
            accuracy: 0.0001
        )
    }

    @MainActor
    func testCanvasLineWidthPreviewResolvesAcrossUndoCancelDeleteAndToolClicks() throws {
        let source = try makeSourceImage(width: 100, height: 80)
        let delegate = ScreenshotCanvasDelegateStub()
        let canvas = ScreenshotCanvasView(
            source: source,
            displayID: 1,
            generation: 1,
            delegate: delegate
        )
        let rectangle = ScreenshotAnnotation(
            kind: .rectangle,
            start: PixelPoint(x: 10, y: 10),
            end: PixelPoint(x: 70, y: 50),
            color: .red,
            lineWidth: 4
        )
        let crop = PixelRect(x: 0, y: 0, width: 100, height: 80)
        canvas.installTestingState(
            crop: crop,
            annotations: [rectangle],
            selectedAnnotationID: rectangle.id,
            tool: .rectangle
        )

        let baselineUndoDepth = canvas.testingUndoDepth
        canvas.beginLineWidthAdjustment()
        XCTAssertEqual(delegate.mutationCount, 1)
        for width in 1...20 {
            canvas.previewLineWidth(width)
        }
        XCTAssertEqual(canvas.snapshot.annotations.first?.lineWidth, 20)
        XCTAssertEqual(canvas.testingUndoDepth, baselineUndoDepth)
        canvas.endLineWidthAdjustment()
        XCTAssertEqual(canvas.testingUndoDepth, baselineUndoDepth + 1)
        XCTAssertEqual(delegate.mutationCount, 1)
        canvas.undo()
        XCTAssertEqual(canvas.snapshot.annotations.first?.lineWidth, 4)
        XCTAssertEqual(canvas.testingLineWidth, 4)

        canvas.beginLineWidthAdjustment()
        canvas.previewLineWidth(12)
        canvas.setDisplayActive(false)
        XCTAssertFalse(canvas.testingIsAdjustingLineWidth)
        XCTAssertFalse(canvas.testingIsDisplayActive)
        XCTAssertTrue(canvas.testingIsToolbarHidden)
        XCTAssertEqual(canvas.snapshot.annotations.first?.lineWidth, 4)
        XCTAssertEqual(canvas.testingLineWidth, 4)
        canvas.setDisplayActive(true)
        XCTAssertTrue(canvas.testingIsDisplayActive)
        XCTAssertFalse(canvas.testingIsToolbarHidden)

        canvas.beginLineWidthAdjustment()
        canvas.previewLineWidth(9)
        canvas.undo()
        canvas.endLineWidthAdjustment()
        XCTAssertFalse(canvas.testingIsAdjustingLineWidth)
        XCTAssertEqual(canvas.snapshot.annotations.first?.lineWidth, 4)
        XCTAssertEqual(canvas.testingLineWidth, 4)

        canvas.beginLineWidthAdjustment()
        canvas.previewLineWidth(13)
        canvas.chooseColor(.blue)
        XCTAssertEqual(canvas.snapshot.annotations.first?.lineWidth, 13)
        XCTAssertEqual(canvas.snapshot.annotations.first?.color, .blue)

        canvas.chooseTool(.rectangle)
        XCTAssertEqual(canvas.testingSelectedAnnotationID, rectangle.id)
        canvas.chooseColor(.green)
        XCTAssertEqual(canvas.snapshot.annotations.first?.color, .green)

        canvas.beginLineWidthAdjustment()
        canvas.previewLineWidth(17)
        canvas.deleteSelection()
        canvas.previewLineWidth(23)
        canvas.endLineWidthAdjustment()
        XCTAssertTrue(canvas.snapshot.annotations.isEmpty)
        XCTAssertNil(canvas.testingSelectedAnnotationID)
    }

    @MainActor
    func testArrowEndpointResizePreservesSelectedWidth() throws {
        let source = try makeSourceImage(width: 120, height: 90)
        let delegate = ScreenshotCanvasDelegateStub()
        let canvas = ScreenshotCanvasView(
            source: source,
            displayID: 1,
            generation: 1,
            delegate: delegate
        )
        let arrow = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 20, y: 30),
            end: PixelPoint(x: 60, y: 30),
            color: .red,
            lineWidth: 24
        )
        let window = makeWindow(for: canvas, size: CGSize(width: 1_000, height: 700))
        canvas.installTestingState(
            crop: PixelRect(x: 0, y: 0, width: 120, height: 90),
            annotations: [arrow],
            selectedAnnotationID: arrow.id,
            tool: .select
        )

        sendMouse(.leftMouseDown, at: CGPoint(x: 60, y: 30), to: canvas, window: window)
        sendMouse(.leftMouseDragged, at: CGPoint(x: 100, y: 60), to: canvas, window: window)
        sendMouse(.leftMouseUp, at: CGPoint(x: 100, y: 60), to: canvas, window: window)

        let resized = try XCTUnwrap(canvas.snapshot.annotations.first)
        XCTAssertEqual(resized.start, arrow.start)
        XCTAssertEqual(resized.end, PixelPoint(x: 100, y: 60))
        XCTAssertEqual(resized.lineWidth, 24)
        XCTAssertEqual(
            ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: resized.lineWidth),
            10,
            accuracy: 0.0001
        )
    }

    @MainActor
    func testCornerRadiusRemainsEditableAfterCropLockAndUsesOneUndoStep() throws {
        let source = try makeSourceImage(width: 120, height: 90)
        let delegate = ScreenshotCanvasDelegateStub()
        let canvas = ScreenshotCanvasView(
            source: source,
            displayID: 1,
            generation: 1,
            delegate: delegate
        )
        let crop = PixelRect(x: 10, y: 10, width: 90, height: 60)
        let rectangle = ScreenshotAnnotation(
            kind: .rectangle,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 70, y: 50),
            lineWidth: 4
        )
        canvas.installTestingState(
            crop: crop,
            annotations: [rectangle],
            selectedAnnotationID: rectangle.id,
            cornerRadius: 8
        )

        let baselineDepth = canvas.testingUndoDepth
        canvas.beginCornerRadiusAdjustment()
        XCTAssertEqual(delegate.mutationCount, 1)
        for radius in 9...24 {
            canvas.previewCornerRadius(radius)
        }
        XCTAssertTrue(canvas.testingIsAdjustingCornerRadius)
        XCTAssertEqual(canvas.snapshot.cornerRadius, 24)
        XCTAssertEqual(canvas.testingUndoDepth, baselineDepth)
        canvas.endCornerRadiusAdjustment()
        XCTAssertFalse(canvas.testingIsAdjustingCornerRadius)
        XCTAssertEqual(canvas.testingUndoDepth, baselineDepth + 1)
        XCTAssertEqual(delegate.mutationCount, 1)
        XCTAssertEqual(canvas.snapshot.crop, crop)
        XCTAssertEqual(canvas.snapshot.annotations, [rectangle])

        canvas.undo()
        XCTAssertEqual(canvas.snapshot.cornerRadius, 8)
        XCTAssertEqual(canvas.snapshot.annotations, [rectangle])
        canvas.redo()
        XCTAssertEqual(canvas.snapshot.cornerRadius, 24)
    }

    func testScreenshotGeometryResizesFromEveryHandle() {
        let rect = PixelRect(x: 20, y: 30, width: 40, height: 50)
        let imageSize = PixelSize(width: 100, height: 100)
        let cases: [(ScreenshotResizeHandle, PixelPoint, PixelRect)] = [
            (.topLeft, PixelPoint(x: 10, y: 15), PixelRect(x: 10, y: 15, width: 50, height: 65)),
            (.top, PixelPoint(x: 50, y: 15), PixelRect(x: 20, y: 15, width: 40, height: 65)),
            (.topRight, PixelPoint(x: 80, y: 15), PixelRect(x: 20, y: 15, width: 60, height: 65)),
            (.right, PixelPoint(x: 80, y: 50), PixelRect(x: 20, y: 30, width: 60, height: 50)),
            (.bottomRight, PixelPoint(x: 80, y: 90), PixelRect(x: 20, y: 30, width: 60, height: 60)),
            (.bottom, PixelPoint(x: 50, y: 90), PixelRect(x: 20, y: 30, width: 40, height: 60)),
            (.bottomLeft, PixelPoint(x: 10, y: 90), PixelRect(x: 10, y: 30, width: 50, height: 60)),
            (.left, PixelPoint(x: 10, y: 50), PixelRect(x: 10, y: 30, width: 50, height: 50))
        ]

        for (handle, point, expected) in cases {
            XCTAssertEqual(
                ScreenshotGeometry.resizing(rect, handle: handle, to: point, within: imageSize),
                expected,
                "Unexpected resize result for \(handle)"
            )
        }

        XCTAssertEqual(
            ScreenshotGeometry.resizing(
                rect,
                handle: .topLeft,
                to: PixelPoint(x: 1_000, y: 1_000),
                within: imageSize,
                minimumSize: 2
            ),
            PixelRect(x: 58, y: 78, width: 2, height: 2)
        )
    }

    func testScreenshotSessionGateRejectsLateGenerationsAndRevisions() {
        var gate = ScreenshotSessionGate()
        let firstCapture = gate.begin()
        XCTAssertTrue(gate.accepts(firstCapture))

        let firstEdit = gate.mutate()
        XCTAssertFalse(gate.accepts(firstCapture))
        XCTAssertTrue(gate.accepts(firstEdit))

        gate.end()
        XCTAssertFalse(gate.accepts(firstEdit))
        XCTAssertFalse(gate.isActive)

        let secondCapture = gate.begin()
        XCTAssertNotEqual(secondCapture.generation, firstCapture.generation)
        XCTAssertEqual(secondCapture.revision, 0)
        XCTAssertFalse(gate.accepts(firstCapture))
        XCTAssertFalse(gate.accepts(firstEdit))
        XCTAssertTrue(gate.accepts(secondCapture))
    }

    func testScreenshotEditHistoryIsLimitedToOneHundredUndoSteps() {
        var history = ScreenshotEditHistory(maximumDepth: 100)
        for index in 1...120 {
            history.commit([makeAnnotation(index: index)])
        }

        XCTAssertEqual(history.undoStack.count, 100)
        var undoCount = 0
        while history.undo() {
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 100)
        XCTAssertEqual(history.annotations.first?.text, "annotation-20")
        XCTAssertFalse(history.canUndo)

        var redoCount = 0
        while history.redo() {
            redoCount += 1
        }
        XCTAssertEqual(redoCount, 100)
        XCTAssertEqual(history.annotations.first?.text, "annotation-120")
        XCTAssertFalse(history.canRedo)

        XCTAssertTrue(history.undo())
        history.commit([makeAnnotation(index: 999)])
        XCTAssertFalse(history.canRedo)
    }

    func testFirstAnnotationLocksCropEvenAfterUndo() {
        let initialCrop = PixelRect(x: 5, y: 5, width: 80, height: 60)
        var editor = ScreenshotEditorState(cropRect: initialCrop)

        XCTAssertTrue(editor.setCropRect(PixelRect(x: 10, y: 10, width: 70, height: 50)))
        editor.commitAnnotations([])
        XCTAssertFalse(editor.cropLocked)

        editor.commitAnnotations([makeAnnotation(index: 1)])
        XCTAssertTrue(editor.cropLocked)
        let lockedCrop = editor.cropRect
        XCTAssertFalse(editor.setCropRect(PixelRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(editor.cropRect, lockedCrop)

        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.history.annotations.isEmpty)
        XCTAssertTrue(editor.cropLocked)
        XCTAssertTrue(editor.redo())
    }

    func testScreenshotRendererEncodesPNGAndJPEGAtCropDimensions() throws {
        let source = try makeSourceImage(width: 80, height: 60)
        let crop = PixelRect(x: 8, y: 6, width: 48, height: 36)
        let rendered = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: [
                ScreenshotAnnotation(
                    kind: .rectangle,
                    start: PixelPoint(x: 12, y: 10),
                    end: PixelPoint(x: 42, y: 28),
                    color: .red,
                    lineWidth: 2
                )
            ]
        ))
        XCTAssertEqual(rendered.width, 48)
        XCTAssertEqual(rendered.height, 36)

        let png = try ScreenshotRenderer.encode(rendered, format: .png)
        let jpeg = try ScreenshotRenderer.encode(rendered, format: .jpeg)
        XCTAssertTrue(png.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertTrue(jpeg.prefix(2).elementsEqual([0xFF, 0xD8]))
        XCTAssertTrue(jpeg.suffix(2).elementsEqual([0xFF, 0xD9]))
        assertDecodedSize(png, width: 48, height: 36)
        assertDecodedSize(jpeg, width: 48, height: 36)
    }

    func testRoundedCropPreservesPNGAlphaAndUsesWhiteJPEGCorners() throws {
        let source = try makeSourceImage(width: 80, height: 60)
        let crop = PixelRect(x: 8, y: 6, width: 48, height: 36)
        let cornerMark = ScreenshotAnnotation(
            kind: .freehand,
            start: PixelPoint(x: crop.minX, y: crop.minY),
            end: PixelPoint(x: crop.midX, y: crop.midY),
            color: .black,
            lineWidth: 24,
            points: [
                PixelPoint(x: crop.minX, y: crop.minY),
                PixelPoint(x: crop.midX, y: crop.midY)
            ]
        )
        let rendered = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: [cornerMark],
            cornerRadius: 12
        ))
        XCTAssertEqual(try rgbaPixel(in: rendered, x: 0, y: 0)[3], 0)
        XCTAssertEqual(
            try rgbaPixel(in: rendered, x: rendered.width / 2, y: rendered.height / 2)[3],
            255
        )

        let png = try ScreenshotRenderer.encode(rendered, format: .png)
        let decodedPNG = try decodedRGBAImage(png)
        XCTAssertEqual(try rgbaPixel(in: decodedPNG, x: 0, y: 0)[3], 0)

        let jpeg = try ScreenshotRenderer.encode(rendered, format: .jpeg)
        let decodedJPEG = try decodedRGBAImage(jpeg)
        let corner = try rgbaPixel(in: decodedJPEG, x: 0, y: 0)
        XCTAssertGreaterThanOrEqual(corner[0], 240)
        XCTAssertGreaterThanOrEqual(corner[1], 240)
        XCTAssertGreaterThanOrEqual(corner[2], 240)
        XCTAssertEqual(corner[3], 255)
    }

    func testScreenshotRendererPreservesTopLeftPixelRowsForNonzeroCrop() throws {
        let source = try makeCoordinateImage(width: 8, height: 6)
        let crop = PixelRect(x: 2, y: 1, width: 4, height: 3)
        let rendered = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: []
        ))

        for outputY in 0..<crop.height {
            for outputX in 0..<crop.width {
                XCTAssertEqual(
                    try rgbaPixel(in: rendered, x: outputX, y: outputY),
                    coordinatePixel(x: crop.x + outputX, y: crop.y + outputY),
                    "Pixel orientation changed at output (\(outputX), \(outputY))"
                )
            }
        }
    }

    func testOutputCommitGateRejectsCancelledAndStaleSaves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashOutputGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = ScreenshotOutputCommitGate()
        let token = ScreenshotSessionToken(generation: 41, revision: 3)
        gate.activate(token)

        let firstTemporary = root.appendingPathComponent("first.tmp")
        let firstDestination = root.appendingPathComponent("first.png")
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        try payload.write(to: firstTemporary)
        try await gate.commitTemporaryFile(
            at: firstTemporary,
            to: firstDestination,
            token: token
        )
        XCTAssertEqual(try Data(contentsOf: firstDestination), payload)

        let newerToken = ScreenshotSessionToken(generation: 41, revision: 4)
        gate.activate(newerToken)
        let newerTemporary = root.appendingPathComponent("newer.tmp")
        let newerDestination = root.appendingPathComponent("newer.png")
        try payload.write(to: newerTemporary)
        try await gate.commitTemporaryFile(
            at: newerTemporary,
            to: newerDestination,
            token: newerToken
        )
        XCTAssertEqual(try Data(contentsOf: newerDestination), payload)

        let oldRevisionTemporary = root.appendingPathComponent("old-revision.tmp")
        let oldRevisionDestination = root.appendingPathComponent("old-revision.png")
        try payload.write(to: oldRevisionTemporary)
        do {
            try await gate.commitTemporaryFile(
                at: oldRevisionTemporary,
                to: oldRevisionDestination,
                token: token
            )
            XCTFail("Older revision committed after a newer output token")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldRevisionTemporary.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldRevisionDestination.path))
        }

        let cancelledTemporary = root.appendingPathComponent("cancelled.tmp")
        let cancelledDestination = root.appendingPathComponent("cancelled.png")
        try payload.write(to: cancelledTemporary)
        let cancelledCommit = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await gate.commitTemporaryFile(
                at: cancelledTemporary,
                to: cancelledDestination,
                token: newerToken
            )
        }
        do {
            try await cancelledCommit.value
            XCTFail("Pre-cancelled output committed a file")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledTemporary.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledDestination.path))
        }

        gate.invalidate(generation: token.generation)
        let staleTemporary = root.appendingPathComponent("stale.tmp")
        let staleDestination = root.appendingPathComponent("stale.png")
        try payload.write(to: staleTemporary)
        do {
            try await gate.commitTemporaryFile(
                at: staleTemporary,
                to: staleDestination,
                token: token
            )
            XCTFail("Stale save token committed a file")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemporary.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleDestination.path))
        }
    }

    func testOutputCommitInvalidationDoesNotWaitForFileSystemCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashOutputLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let releaseCommit = DispatchSemaphore(value: 0)
        defer {
            releaseCommit.signal()
            try? FileManager.default.removeItem(at: root)
        }

        let commitStarted = expectation(description: "file commit started")
        let gate = ScreenshotOutputCommitGate { temporaryURL, destinationURL in
            commitStarted.fulfill()
            _ = releaseCommit.wait(timeout: .now() + 2)
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        let token = ScreenshotSessionToken(generation: 52, revision: 7)
        gate.activate(token)

        let temporaryURL = root.appendingPathComponent("pending.tmp")
        let destinationURL = root.appendingPathComponent("committed.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: temporaryURL)
        let commitTask = Task.detached {
            try await gate.commitTemporaryFile(
                at: temporaryURL,
                to: destinationURL,
                token: token
            )
        }

        await fulfillment(of: [commitStarted], timeout: 1)
        let invalidationDuration = await MainActor.run {
            let startedAt = ProcessInfo.processInfo.systemUptime
            gate.invalidate(generation: token.generation)
            return ProcessInfo.processInfo.systemUptime - startedAt
        }
        XCTAssertLessThan(
            invalidationDuration,
            0.1,
            "MainActor waited for the blocked file-system commit"
        )

        releaseCommit.signal()
        try await commitTask.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testNSTextViewMarkedTextLifecycleUsesIMEState() async {
        await MainActor.run {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
            editor.setMarkedText(
                "拼音",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertFalse(ScreenshotTextCommandPolicy.shouldCommitReturn(
                hasMarkedText: editor.hasMarkedText()
            ))
            editor.unmarkText()
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertTrue(ScreenshotTextCommandPolicy.shouldCommitReturn(
                hasMarkedText: editor.hasMarkedText()
            ))
        }
    }

    private func makeAnnotation(index: Int) -> ScreenshotAnnotation {
        ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: index % 40, y: index % 30),
            end: PixelPoint(x: index % 40 + 30, y: index % 30 + 20),
            color: .red,
            text: "annotation-\(index)",
            fontSize: 14
        )
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeSourceImage(width: Int, height: Int) throws -> CGImage {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(red: 0.12, green: 0.22, blue: 0.38, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private func makeWindow(for canvas: ScreenshotCanvasView, size: CGSize) -> NSWindow {
        let window = ScreenshotEventTestWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.layoutSubtreeIfNeeded()
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        // XCTest's next async waiter flushes AppKit transactions. Keep these invisible event
        // windows alive until the hosted process exits so that flush cannot race deallocation.
        Self.retainedEventWindows.append(window)
        return window
    }

    @MainActor
    private func sendMouse(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        to canvas: ScreenshotCanvasView,
        window: NSWindow
    ) {
        let source = canvas.snapshot.source
        let viewLocation = ScreenshotGeometry.viewPoint(
            fromPixelPoint: PixelPoint(
                x: Int(location.x.rounded()),
                y: Int(location.y.rounded())
            ),
            viewSize: canvas.bounds.size,
            imageSize: PixelSize(width: source.width, height: source.height),
            isViewFlipped: true
        )
        let windowLocation = canvas.convert(viewLocation, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowLocation,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            XCTFail("Could not construct mouse event")
            return
        }
        switch type {
        case .leftMouseDown:
            canvas.mouseDown(with: event)
        case .leftMouseDragged:
            canvas.mouseDragged(with: event)
        case .leftMouseUp:
            canvas.mouseUp(with: event)
        default:
            XCTFail("Unsupported mouse event type")
        }
    }

    private func makeCoordinateImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                bytes.append(contentsOf: coordinatePixel(x: x, y: y))
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func coordinatePixel(x: Int, y: Int) -> [UInt8] {
        [
            UInt8((x * 11 + 17) % 251),
            UInt8((y * 13 + 23) % 251),
            UInt8((x * 7 + y * 5 + 31) % 251),
            255
        ]
    }

    private func decodedRGBAImage(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: decoded.width,
            height: decoded.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        context.clear(bounds)
        context.draw(decoded, in: bounds)
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaPixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: pointer + offset, count: 4))
    }

    private func assertDecodedSize(
        _ data: Data,
        width: Int,
        height: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("Encoded image could not be decoded", file: file, line: line)
            return
        }
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
    }
}
