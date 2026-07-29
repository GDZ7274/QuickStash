import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO

private enum ScreenshotTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var installStatus: OSStatus = noErr
    var registerStatuses: [OSStatus] = []
    private(set) var registrations: [(descriptor: HotKeyDescriptor, id: UInt32)] = []
    private(set) var unregisteredIDs: [UInt32] = []
    private(set) var uninstallCount = 0
    private var handler: (@MainActor @Sendable (UInt32) -> Void)?

    func install(handler: @escaping @MainActor @Sendable (UInt32) -> Void) -> OSStatus {
        self.handler = handler
        return installStatus
    }

    func register(_ descriptor: HotKeyDescriptor, id: UInt32) -> OSStatus {
        registrations.append((descriptor, id))
        return registerStatuses.isEmpty ? noErr : registerStatuses.removeFirst()
    }

    func unregister(id: UInt32) {
        unregisteredIDs.append(id)
    }

    func uninstall() {
        uninstallCount += 1
        handler = nil
    }

    func fire(id: UInt32) {
        handler?(id)
    }
}

@MainActor
private final class PointerEventRecorder {
    private(set) var events: [GlobalPointerEventKind] = []

    func append(_ event: GlobalPointerEventKind) {
        events.append(event)
    }
}

@main
@MainActor
struct QuickStashScreenshotTests {
    static func main() async throws {
        try testMixedScaleDisplayGeometry()
        try testWindowSnapGeometryAndZOrder()
        try testWindowCornerRadiusGeometry()
        try testResizeHandlesClampAndMove()
        try testContextualStyleControlsAndContinuousWidths()
        try testLineWidthAdjustmentTransactionAndPhysicalPreview()
        try testArrowHeadGeometryLimits()
        try testArrowShaftWidthCompression()
        try testMaximumWidthArrowRasterFootprint()
        try testFreehandModelCompatibilityAndGeometry()
        try testCropLockAndEditHistoryDepth()
        try testAnnotationMoveModifyAndDelete()
        try testMarkedTextReturnPolicy()
        try testSessionGenerationAndRevisionGate()
        try testHotKeyConflictAndLifecycle()
        try testHotKeySignatureOwnership()
        try testRendererPixelOrientationAndMosaicBounds()
        try testRenderingAndEncoding()
        try testCornerRadiusAdjustmentAndRendering()
        try testDragPresentationGate()
        try testDragProximityArmsWithoutPresenting()
        try testStatusItemHoverPolicyRejectsDragGestures()
        try testStatusItemHoverSuppressionRequiresPointerExit()
        try testArmedDropTargetWatchdogOnlyHidesInvisibleTarget()
        try testDragPasteboardReader()
        try await testPointerEventCoalescing()
        try await testRenderEncodeCancelStress()

        print("QuickStash screenshot tests passed (100 complete component stress cycles)")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw ScreenshotTestFailure.assertion(message) }
    }

    private static func expectClose(
        _ actual: CGFloat,
        _ expected: CGFloat,
        _ message: String,
        tolerance: CGFloat = 0.0001
    ) throws {
        try expect(abs(actual - expected) <= tolerance, "\(message): \(actual) != \(expected)")
    }

    private static func testMixedScaleDisplayGeometry() throws {
        let displays = [
            ScreenshotDisplayGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
                pixelSize: PixelSize(width: 2_560, height: 1_600)
            ),
            ScreenshotDisplayGeometry(
                displayID: 2,
                frameInScreenPoints: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                pixelSize: PixelSize(width: 1_920, height: 1_080)
            ),
            ScreenshotDisplayGeometry(
                displayID: 3,
                frameInScreenPoints: CGRect(x: 200, y: 1_080, width: 1_000, height: 700),
                pixelSize: PixelSize(width: 1_500, height: 1_050)
            )
        ]
        let samples: [(CGPoint, PixelPoint)] = [
            (CGPoint(x: -960, y: 600), PixelPoint(x: 640, y: 400)),
            (CGPoint(x: 960, y: 540), PixelPoint(x: 960, y: 540)),
            (CGPoint(x: 700, y: 1_430), PixelPoint(x: 750, y: 525))
        ]

        for (index, sample) in samples.enumerated() {
            let display = displays[index]
            let pixel = display.pixelPoint(fromGlobalScreenPoint: sample.0)
            try expect(pixel == sample.1, "Display \(display.displayID) did not map to physical pixels")
            let roundTrip = display.globalScreenPoint(fromPixelPoint: sample.1)
            try expectClose(roundTrip.x, sample.0.x, "Display \(display.displayID) x round-trip failed")
            try expectClose(roundTrip.y, sample.0.y, "Display \(display.displayID) y round-trip failed")
        }

        try expect(
            displays[0].pixelPoint(fromGlobalScreenPoint: CGPoint(x: 50, y: 400)) == nil,
            "Negative-origin display accepted a point on another display"
        )
        let clampedPixel = ScreenshotGeometry.pixelPoint(
            fromViewPoint: CGPoint(x: 2_000, y: -20),
            viewSize: CGSize(width: 1_000, height: 500),
            imageSize: PixelSize(width: 1_500, height: 750),
            isViewFlipped: true
        )
        try expect(clampedPixel == PixelPoint(x: 1_500, y: 0), "View-to-pixel mapping did not clamp")

        let unflippedPixel = ScreenshotGeometry.pixelPoint(
            fromViewPoint: CGPoint(x: 250, y: 100),
            viewSize: CGSize(width: 500, height: 400),
            imageSize: PixelSize(width: 1_000, height: 800),
            isViewFlipped: false
        )
        try expect(unflippedPixel == PixelPoint(x: 500, y: 600), "Unflipped y mapping changed")
    }

    private static func testWindowSnapGeometryAndZOrder() throws {
        let oneXDisplay = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let oneX = ScreenshotGeometry.windowPixelRect(
            windowFrame: CGRect(x: 100, y: 120, width: 640, height: 480),
            displayFrame: oneXDisplay,
            imageSize: PixelSize(width: 1_920, height: 1_080)
        )
        try expect(
            oneX == PixelRect(x: 100, y: 120, width: 640, height: 480),
            "A 1x window did not preserve its display-point bounds"
        )

        let twoXDisplay = CGRect(x: -1_280, y: 0, width: 1_280, height: 800)
        let twoX = ScreenshotGeometry.windowPixelRect(
            windowFrame: CGRect(x: -1_200, y: 100, width: 600, height: 500),
            displayFrame: twoXDisplay,
            imageSize: PixelSize(width: 2_560, height: 1_600)
        )
        try expect(
            twoX == PixelRect(x: 160, y: 200, width: 1_200, height: 1_000),
            "A 2x negative-origin display mapped a window to the wrong pixels"
        )

        let upperOneAndHalfXDisplay = CGRect(x: 200, y: -700, width: 1_000, height: 700)
        let fractional = ScreenshotGeometry.windowPixelRect(
            windowFrame: CGRect(x: 300.25, y: -599.75, width: 100.5, height: 50.5),
            displayFrame: upperOneAndHalfXDisplay,
            imageSize: PixelSize(width: 1_500, height: 1_050)
        )
        try expect(
            fractional == PixelRect(x: 150, y: 150, width: 152, height: 77),
            "A 1.5x fractional window did not floor its minimums and ceil its maximums"
        )

        let horizontalSpanningWindow = CGRect(x: -100.25, y: 100, width: 300.5, height: 400)
        let leftSlice = ScreenshotGeometry.windowPixelRect(
            windowFrame: horizontalSpanningWindow,
            displayFrame: twoXDisplay,
            imageSize: PixelSize(width: 2_560, height: 1_600)
        )
        let mainSlice = ScreenshotGeometry.windowPixelRect(
            windowFrame: horizontalSpanningWindow,
            displayFrame: oneXDisplay,
            imageSize: PixelSize(width: 1_920, height: 1_080)
        )
        try expect(
            leftSlice == PixelRect(x: 2_359, y: 200, width: 201, height: 800),
            "The left-display slice of a spanning window was not clipped independently"
        )
        try expect(
            mainSlice == PixelRect(x: 0, y: 100, width: 201, height: 400),
            "The main-display slice of a spanning window was not clipped independently"
        )

        let belowDisplay = CGRect(x: 0, y: 1_080, width: 1_600, height: 900)
        let verticalSpanningWindow = CGRect(x: 100, y: 1_000, width: 500, height: 200)
        let upperSlice = ScreenshotGeometry.windowPixelRect(
            windowFrame: verticalSpanningWindow,
            displayFrame: oneXDisplay,
            imageSize: PixelSize(width: 1_920, height: 1_080)
        )
        let lowerSlice = ScreenshotGeometry.windowPixelRect(
            windowFrame: verticalSpanningWindow,
            displayFrame: belowDisplay,
            imageSize: PixelSize(width: 2_400, height: 1_350)
        )
        try expect(
            upperSlice == PixelRect(x: 100, y: 1_000, width: 500, height: 80),
            "The upper-display slice of a vertically spanning window was wrong"
        )
        try expect(
            lowerSlice == PixelRect(x: 150, y: 0, width: 750, height: 180),
            "The lower 1.5x-display slice of a vertically spanning window was wrong"
        )

        try expect(
            ScreenshotGeometry.windowPixelRect(
                windowFrame: CGRect(x: 5_000, y: 5_000, width: 100, height: 100),
                displayFrame: oneXDisplay,
                imageSize: PixelSize(width: 1_920, height: 1_080)
            ) == nil,
            "A window with no display intersection produced a snap region"
        )

        let back = ScreenshotWindowRegion(
            windowID: 100,
            pixelRect: PixelRect(x: 0, y: 0, width: 400, height: 400),
            order: 9
        )
        let front = ScreenshotWindowRegion(
            windowID: 200,
            pixelRect: PixelRect(x: 100, y: 100, width: 200, height: 200),
            order: 2,
            cornerRadius: 40
        )
        let unknownOrder = ScreenshotWindowRegion(
            windowID: 1,
            pixelRect: PixelRect(x: 120, y: 120, width: 100, height: 100),
            order: Int.max
        )
        try expect(
            ScreenshotGeometry.frontmostWindowRegion(
                at: PixelPoint(x: 150, y: 150),
                in: [back, unknownOrder, front]
            ) == front,
            "Window hit testing ignored explicit front-to-back order"
        )
        try expect(
            ScreenshotGeometry.frontmostWindowRegion(
                at: PixelPoint(x: 350, y: 350),
                in: [front, back]
            ) == back,
            "Window hit testing did not fall through to the containing back window"
        )
        try expect(
            ScreenshotGeometry.frontmostWindowRegion(
                at: PixelPoint(x: 100, y: 100),
                in: [front, back]
            ) == back,
            "A front window's transparent rounded corner hid the visible back window"
        )
    }

    private static func testWindowCornerRadiusGeometry() throws {
        let oneXDisplay = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let window = CGRect(x: 100, y: 120, width: 640, height: 480)
        let oneXRect = PixelRect(x: 100, y: 120, width: 640, height: 480)
        try expect(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: window,
                displayFrame: oneXDisplay,
                imageSize: PixelSize(width: 1_920, height: 1_080),
                pixelRect: oneXRect
            ) == 10,
            "A 1x window did not receive a 10-pixel standard corner radius"
        )
        try expect(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: window,
                displayFrame: oneXDisplay,
                imageSize: PixelSize(width: 3_840, height: 2_160),
                pixelRect: PixelRect(x: 200, y: 240, width: 1_280, height: 960)
            ) == 20,
            "A 2x window corner radius was not aligned to physical pixels"
        )
        try expect(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: window,
                displayFrame: oneXDisplay,
                imageSize: PixelSize(width: 2_880, height: 1_620),
                pixelRect: PixelRect(x: 150, y: 180, width: 960, height: 720)
            ) == 15,
            "A 1.5x window corner radius was not aligned to physical pixels"
        )
        try expect(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: CGRect(x: -100, y: 120, width: 640, height: 480),
                displayFrame: oneXDisplay,
                imageSize: PixelSize(width: 1_920, height: 1_080),
                pixelRect: PixelRect(x: 0, y: 120, width: 540, height: 480)
            ) == 0,
            "A cross-display window slice gained four false rounded corners"
        )
        try expect(
            ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                windowFrame: oneXDisplay,
                displayFrame: oneXDisplay,
                imageSize: PixelSize(width: 1_920, height: 1_080),
                pixelRect: PixelRect(x: 0, y: 0, width: 1_920, height: 1_080)
            ) == 0,
            "A full-screen window gained artificial rounded corners"
        )
        try expect(
            ScreenshotCropStylePolicy.clampedCornerRadius(
                120,
                for: PixelRect(x: 0, y: 0, width: 18, height: 10)
            ) == 5,
            "Corner radius exceeded half of the crop's short edge"
        )

        let roundedRect = PixelRect(x: 10, y: 20, width: 100, height: 80)
        try expect(
            !ScreenshotGeometry.roundedRectContains(
                PixelPoint(x: 10, y: 20),
                rect: roundedRect,
                cornerRadius: 20
            ),
            "A transparent rounded corner remained interactive"
        )
        try expect(
            ScreenshotGeometry.roundedRectContains(
                PixelPoint(x: 30, y: 20),
                rect: roundedRect,
                cornerRadius: 20
            ),
            "The rounded arc boundary was excluded"
        )
        try expect(
            ScreenshotGeometry.roundedRectContains(
                PixelPoint(x: 60, y: 60),
                rect: roundedRect,
                cornerRadius: 20
            ),
            "The rounded crop interior was excluded"
        )
        try expect(
            ScreenshotGeometry.roundedRectContains(
                PixelPoint(x: 10, y: 20),
                rect: roundedRect,
                cornerRadius: 0
            ),
            "A square crop lost its corner hit target"
        )
    }

    private static func testContextualStyleControlsAndContinuousWidths() throws {
        let policy = ScreenshotAnnotationStylePolicy.self
        try expect(policy.clampedLineWidth(-10) == 1, "Line width did not clamp to its lower bound")
        try expect(policy.clampedLineWidth(1) == 1, "Lower line-width bound changed")
        try expect(policy.clampedLineWidth(7) == 7, "A non-preset line width was rejected")
        try expect(policy.clampedLineWidth(24) == 24, "Upper line-width bound changed")
        try expect(policy.clampedLineWidth(100) == 24, "Line width did not clamp to its upper bound")

        try expect(
            policy.controls(for: .select, selectedAnnotationKind: nil).isEmpty,
            "Selection without an annotation exposed style controls"
        )
        for tool in [ScreenshotTool.arrow, .rectangle, .freehand] {
            let controls = policy.controls(for: tool, selectedAnnotationKind: nil)
            try expect(
                controls == ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: true),
                "\(tool) did not expose color and continuous width"
            )
        }
        try expect(
            policy.controls(for: .text, selectedAnnotationKind: nil)
                == ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: false),
            "Text exposed an irrelevant line-width control"
        )
        try expect(
            policy.controls(for: .mosaic, selectedAnnotationKind: nil).isEmpty,
            "Mosaic exposed irrelevant color or line-width controls"
        )
        try expect(
            policy.controls(for: .select, selectedAnnotationKind: .rectangle)
                == ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: true),
            "A selected rectangle did not expose its editable style"
        )
        try expect(
            policy.controls(for: .select, selectedAnnotationKind: .text)
                == ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: false),
            "A selected text annotation exposed the wrong style"
        )
        try expect(
            policy.controls(for: .select, selectedAnnotationKind: .mosaic).isEmpty,
            "A selected mosaic exposed irrelevant style controls"
        )
        try expect(
            policy.controls(for: .select, selectedAnnotationKind: .freehand)
                == ScreenshotStyleControlVisibility(showsColor: true, showsLineWidth: true),
            "A selected freehand annotation did not expose color and continuous width"
        )
    }

    private static func testLineWidthAdjustmentTransactionAndPhysicalPreview() throws {
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
        try expect(adjustment.originalLineWidth == 4, "Slider transaction lost its original width")
        try expect(adjustment.previewLineWidth == 21, "Slider transaction lost its latest preview")
        try expect(
            adjustment.previewAnnotations.first?.lineWidth == 21,
            "Slider transaction did not update the selected annotation"
        )

        var history = ScreenshotEditHistory(maximumDepth: 100)
        history.commit([rectangle])
        let baselineUndoDepth = history.undoStack.count
        history.commit(adjustment.previewAnnotations)
        try expect(
            history.undoStack.count == baselineUndoDepth + 1,
            "A full slider drag created more than one undo step"
        )
        try expect(history.undo(), "Slider edit could not be undone")
        try expect(history.annotations == [rectangle], "Undo did not restore the pre-slider annotation")

        var defaultOnlyAdjustment = ScreenshotLineWidthAdjustment(
            annotations: [rectangle],
            selectedAnnotationID: nil,
            lineWidth: 4
        )
        defaultOnlyAdjustment.preview(12)
        try expect(
            !defaultOnlyAdjustment.hasAnnotationChange,
            "Changing a drawing default unexpectedly edited an annotation"
        )
        try expect(
            defaultOnlyAdjustment.previewLineWidth == 12,
            "Default-only slider adjustment did not retain its selected width"
        )

        try expectClose(
            ScreenshotGeometry.viewLineWidth(
                sourcePixelWidth: 1,
                sourceWidth: 2_000,
                viewWidth: 1_000,
                backingScaleFactor: 2
            ),
            0.5,
            "A one-pixel Retina stroke previewed as two physical pixels"
        )
        try expectClose(
            ScreenshotGeometry.viewLineWidth(
                sourcePixelWidth: 13,
                sourceWidth: 2_000,
                viewWidth: 1_000,
                backingScaleFactor: 2
            ),
            6.5,
            "A non-preset Retina stroke width changed during preview"
        )
    }

    private static func testArrowHeadGeometryLimits() throws {
        try expectClose(
            ScreenshotGeometry.arrowHeadLength(lineWidth: 4, segmentLength: 1_000),
            16,
            "The default-width arrow head changed"
        )
        try expectClose(
            ScreenshotGeometry.arrowHeadLength(lineWidth: 24, segmentLength: 1_000),
            36,
            "A maximum-width arrow head was not capped at 36 pixels"
        )

        let shortSegmentLength = CGFloat(50)
        let shortHeadLength = ScreenshotGeometry.arrowHeadLength(
            lineWidth: 24,
            segmentLength: shortSegmentLength
        )
        try expectClose(
            shortHeadLength,
            shortSegmentLength * 0.4,
            "A short arrow head exceeded 40 percent of its segment"
        )
        try expect(
            ScreenshotGeometry.arrowHeadLength(lineWidth: 24, segmentLength: 0) == 0,
            "A zero-length arrow produced a visible arrow head"
        )

        let sourceSegmentLength = CGFloat(120)
        let outputHeadLength = ScreenshotGeometry.arrowHeadLength(
            lineWidth: 24,
            segmentLength: sourceSegmentLength
        )
        for scale in [CGFloat(1), CGFloat(2.0 / 3.0), CGFloat(0.5)] {
            let previewLength = ScreenshotGeometry.arrowHeadLength(
                lineWidth: 24,
                segmentLength: sourceSegmentLength * scale,
                coordinateScale: scale
            )
            try expectClose(
                previewLength / scale,
                outputHeadLength,
                "Arrow-head limits changed at display scale \(scale)"
            )
        }
    }

    private static func testArrowShaftWidthCompression() throws {
        let anchors: [(Int, CGFloat)] = [
            (1, 1),
            (4, 4),
            (8, 5.2),
            (16, 7.6),
            (24, 10)
        ]
        for (styleWidth, expected) in anchors {
            try expectClose(
                ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: styleWidth),
                expected,
                "Arrow shaft compression changed at style width \(styleWidth)"
            )
        }
        var previous: CGFloat = 0
        for styleWidth in ScreenshotAnnotationStylePolicy.lineWidthRange {
            let current = ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: styleWidth)
            try expect(current >= previous, "Arrow shaft compression stopped being monotonic")
            previous = current
        }
        for scale in [CGFloat(1), CGFloat(2.0 / 3.0), CGFloat(0.5)] {
            let preview = ScreenshotGeometry.viewLineWidth(
                sourcePixelWidth: ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: 24),
                sourceWidth: 1_000,
                viewWidth: 1_000 * scale,
                backingScaleFactor: 2
            )
            try expectClose(
                preview / scale,
                10,
                "Maximum arrow shaft changed at preview scale \(scale)"
            )
        }
    }

    private static func testMaximumWidthArrowRasterFootprint() throws {
        let source = try makeSourceImage(width: 220, height: 120)
        let crop = PixelRect(x: 0, y: 0, width: 220, height: 120)
        let baseline = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: []
        ))
        let rendered = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: [ScreenshotAnnotation(
                kind: .arrow,
                start: PixelPoint(x: 20, y: 60),
                end: PixelPoint(x: 200, y: 60),
                color: .black,
                lineWidth: 24
            )]
        ))

        var minY = rendered.height
        var maxY = -1
        var changedPixels = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width where try rgbaPixel(in: baseline, x: x, y: y)
                != rgbaPixel(in: rendered, x: x, y: y) {
                minY = min(minY, y)
                maxY = max(maxY, y)
                changedPixels += 1
            }
        }
        let footprintHeight = maxY >= minY ? maxY - minY + 1 : 0
        try expect(changedPixels > 1_000, "Maximum-width arrow did not render a visible shaft and head")
        try expect(
            footprintHeight >= 24 && footprintHeight <= 42,
            "Maximum-width arrow head expanded to an invalid \(footprintHeight)-pixel footprint"
        )
        let shaftX = 80
        var shaftChangedPixels = 0
        for y in 0..<rendered.height where try rgbaPixel(in: baseline, x: shaftX, y: y)
            != rgbaPixel(in: rendered, x: shaftX, y: y) {
            shaftChangedPixels += 1
        }
        try expect(
            shaftChangedPixels >= 10 && shaftChangedPixels <= 12,
            "Maximum arrow shaft rendered as \(shaftChangedPixels) pixels instead of about 10"
        )
    }

    private static func testFreehandModelCompatibilityAndGeometry() throws {
        let path = [
            PixelPoint(x: 10, y: 10),
            PixelPoint(x: 30, y: 20),
            PixelPoint(x: 20, y: 40)
        ]
        let freehand = ScreenshotAnnotation(
            kind: .freehand,
            start: path[0],
            end: path[2],
            color: .blue,
            lineWidth: 7,
            points: path
        )
        try expect(
            freehand.bounds == PixelRect(x: 10, y: 10, width: 20, height: 30),
            "Freehand bounds did not include every sampled point"
        )

        let singlePoint = PixelPoint(x: 17, y: 23)
        let dot = ScreenshotAnnotation(
            kind: .freehand,
            start: singlePoint,
            end: singlePoint,
            points: [singlePoint]
        )
        try expect(
            dot.bounds == PixelRect(x: 17, y: 23, width: 1, height: 1),
            "A one-point freehand mark did not retain selectable bounds"
        )

        let translated = freehand.translated(
            dx: 100,
            dy: 100,
            within: PixelRect(x: 0, y: 0, width: 50, height: 50)
        )
        let expectedTranslatedPoints = [
            PixelPoint(x: 30, y: 20),
            PixelPoint(x: 50, y: 30),
            PixelPoint(x: 40, y: 50)
        ]
        try expect(
            translated.points == expectedTranslatedPoints
                && translated.start == expectedTranslatedPoints.first
                && translated.end == expectedTranslatedPoints.last,
            "Moving a freehand annotation did not translate and clamp its full path"
        )

        let resizedBounds = ScreenshotGeometry.resizing(
            freehand.bounds,
            handle: .bottomRight,
            to: PixelPoint(x: 50, y: 70),
            within: PixelSize(width: 100, height: 100)
        )
        func transformForResize(_ point: PixelPoint) -> PixelPoint {
            let xRatio = CGFloat(point.x - freehand.bounds.minX) / CGFloat(freehand.bounds.width)
            let yRatio = CGFloat(point.y - freehand.bounds.minY) / CGFloat(freehand.bounds.height)
            return PixelPoint(
                x: resizedBounds.minX + Int((xRatio * CGFloat(resizedBounds.width)).rounded()),
                y: resizedBounds.minY + Int((yRatio * CGFloat(resizedBounds.height)).rounded())
            )
        }
        let resizedPoints = freehand.points.map(transformForResize)
        let resized = ScreenshotAnnotation(
            id: freehand.id,
            kind: .freehand,
            start: resizedPoints[0],
            end: resizedPoints[2],
            color: freehand.color,
            lineWidth: freehand.lineWidth,
            points: resizedPoints
        )
        try expect(
            resized.points == [
                PixelPoint(x: 10, y: 10),
                PixelPoint(x: 50, y: 30),
                PixelPoint(x: 30, y: 70)
            ] && resized.bounds == resizedBounds,
            "Bounding-box scaling did not transform the entire freehand path"
        )

        let encodedFreehand = try JSONEncoder().encode(freehand)
        let decodedFreehand = try JSONDecoder().decode(
            ScreenshotAnnotation.self,
            from: encodedFreehand
        )
        try expect(decodedFreehand == freehand, "Freehand points or style did not survive Codable")

        let legacy = ScreenshotAnnotation(
            kind: .rectangle,
            start: PixelPoint(x: 3, y: 4),
            end: PixelPoint(x: 20, y: 24),
            color: .green,
            lineWidth: 5
        )
        let encodedLegacy = try JSONEncoder().encode(legacy)
        guard var legacyObject = try JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any] else {
            throw ScreenshotTestFailure.assertion("Could not inspect legacy annotation JSON")
        }
        legacyObject.removeValue(forKey: "points")
        let legacyWithoutPoints = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(
            ScreenshotAnnotation.self,
            from: legacyWithoutPoints
        )
        try expect(
            decodedLegacy.points.isEmpty
                && decodedLegacy.kind == legacy.kind
                && decodedLegacy.start == legacy.start
                && decodedLegacy.end == legacy.end
                && decodedLegacy.color == legacy.color
                && decodedLegacy.lineWidth == legacy.lineWidth,
            "An annotation encoded before freehand points existed no longer decodes"
        )

        var adjustment = ScreenshotLineWidthAdjustment(
            annotations: [freehand],
            selectedAnnotationID: freehand.id,
            lineWidth: freehand.lineWidth
        )
        adjustment.preview(19)
        try expect(
            adjustment.previewAnnotations.first?.lineWidth == 19
                && adjustment.previewAnnotations.first?.color == .blue
                && adjustment.previewAnnotations.first?.points == path,
            "Changing freehand thickness damaged its color or sampled path"
        )
    }

    private static func testResizeHandlesClampAndMove() throws {
        let rect = PixelRect(x: 20, y: 30, width: 40, height: 50)
        let imageSize = PixelSize(width: 100, height: 100)
        let handles = ScreenshotGeometry.handlePoints(for: rect)
        try expect(ScreenshotResizeHandle.allCases.count == 8, "Resize handle count is not eight")
        try expect(handles.count == 8, "Not every resize handle has a point")
        try expect(handles[.topLeft] == PixelPoint(x: 20, y: 30), "Top-left handle moved")
        try expect(handles[.top] == PixelPoint(x: 40, y: 30), "Top handle moved")
        try expect(handles[.topRight] == PixelPoint(x: 60, y: 30), "Top-right handle moved")
        try expect(handles[.right] == PixelPoint(x: 60, y: 55), "Right handle moved")
        try expect(handles[.bottomRight] == PixelPoint(x: 60, y: 80), "Bottom-right handle moved")
        try expect(handles[.bottom] == PixelPoint(x: 40, y: 80), "Bottom handle moved")
        try expect(handles[.bottomLeft] == PixelPoint(x: 20, y: 80), "Bottom-left handle moved")
        try expect(handles[.left] == PixelPoint(x: 20, y: 55), "Left handle moved")

        let expectedResizes: [(ScreenshotResizeHandle, PixelPoint, PixelRect)] = [
            (.topLeft, PixelPoint(x: 10, y: 15), PixelRect(x: 10, y: 15, width: 50, height: 65)),
            (.top, PixelPoint(x: 50, y: 15), PixelRect(x: 20, y: 15, width: 40, height: 65)),
            (.topRight, PixelPoint(x: 80, y: 15), PixelRect(x: 20, y: 15, width: 60, height: 65)),
            (.right, PixelPoint(x: 80, y: 50), PixelRect(x: 20, y: 30, width: 60, height: 50)),
            (.bottomRight, PixelPoint(x: 80, y: 90), PixelRect(x: 20, y: 30, width: 60, height: 60)),
            (.bottom, PixelPoint(x: 50, y: 90), PixelRect(x: 20, y: 30, width: 40, height: 60)),
            (.bottomLeft, PixelPoint(x: 10, y: 90), PixelRect(x: 10, y: 30, width: 50, height: 60)),
            (.left, PixelPoint(x: 10, y: 50), PixelRect(x: 10, y: 30, width: 50, height: 50))
        ]
        for (handle, point, expected) in expectedResizes {
            let resized = ScreenshotGeometry.resizing(rect, handle: handle, to: point, within: imageSize)
            try expect(resized == expected, "Resize result changed for \(handle)")
        }

        let minimumTopLeft = ScreenshotGeometry.resizing(
            rect,
            handle: .topLeft,
            to: PixelPoint(x: 1_000, y: 1_000),
            within: imageSize,
            minimumSize: 2
        )
        try expect(
            minimumTopLeft == PixelRect(x: 58, y: 78, width: 2, height: 2),
            "Top-left crossing did not preserve the minimum size"
        )
        let minimumBottomRight = ScreenshotGeometry.resizing(
            rect,
            handle: .bottomRight,
            to: PixelPoint(x: -1_000, y: -1_000),
            within: imageSize,
            minimumSize: 2
        )
        try expect(
            minimumBottomRight == PixelRect(x: 20, y: 30, width: 2, height: 2),
            "Bottom-right crossing did not preserve the minimum size"
        )
        try expect(
            rect.translated(dx: -500, dy: 500, within: imageSize)
                == PixelRect(x: 0, y: 50, width: 40, height: 50),
            "Moving a crop did not clamp it to image bounds"
        )
        try expect(
            PixelRect(x: -10, y: -20, width: 150, height: 160).clamped(to: imageSize)
                == PixelRect(x: 0, y: 0, width: 100, height: 100),
            "Oversized crop did not clamp to the image"
        )

        let outputHeadLength = ScreenshotGeometry.arrowHeadLength(lineWidth: 2)
        for scale in [CGFloat(1), CGFloat(2.0 / 3.0), CGFloat(0.5)] {
            let previewLength = ScreenshotGeometry.arrowHeadLength(
                lineWidth: 2,
                coordinateScale: scale
            )
            try expectClose(
                previewLength / scale,
                outputHeadLength,
                "Arrow head changed at display scale \(scale)"
            )
        }
    }

    private static func testCropLockAndEditHistoryDepth() throws {
        var editor = ScreenshotEditorState(
            cropRect: PixelRect(x: 5, y: 5, width: 80, height: 60),
            maximumHistoryDepth: 100
        )
        try expect(
            editor.setCropRect(PixelRect(x: 10, y: 10, width: 70, height: 50)),
            "Crop could not change before the first annotation"
        )
        editor.commitAnnotations([])
        try expect(!editor.cropLocked, "An empty annotation commit locked the crop")

        let annotation = makeAnnotation(index: 1)
        editor.commitAnnotations([annotation])
        try expect(editor.cropLocked, "First annotation did not lock the crop")
        let lockedCrop = editor.cropRect
        try expect(
            !editor.setCropRect(PixelRect(x: 0, y: 0, width: 10, height: 10)),
            "Locked crop accepted a new selection"
        )
        try expect(editor.cropRect == lockedCrop, "Rejected crop update still mutated the crop")
        try expect(editor.undo(), "First annotation could not be undone")
        try expect(editor.history.annotations.isEmpty, "Undo did not remove the first annotation")
        try expect(editor.cropLocked, "Undo unexpectedly unlocked the crop")
        try expect(editor.redo(), "First annotation could not be redone")

        var history = ScreenshotEditHistory(maximumDepth: 100)
        for index in 1...120 {
            history.commit([makeAnnotation(index: index)])
        }
        try expect(history.undoStack.count == 100, "Undo history exceeded its 100-step limit")

        var undoCount = 0
        while history.undo() { undoCount += 1 }
        try expect(undoCount == 100, "Undo depth was \(undoCount), expected 100")
        try expect(history.annotations.first?.text == "annotation-20", "Undo retained the wrong oldest state")
        try expect(!history.canUndo, "Undo remained available beyond the configured depth")

        var redoCount = 0
        while history.redo() { redoCount += 1 }
        try expect(redoCount == 100, "Redo depth was \(redoCount), expected 100")
        try expect(history.annotations.first?.text == "annotation-120", "Redo did not restore the latest state")
        try expect(!history.canRedo, "Redo remained available after restoring every state")

        try expect(history.undo(), "History could not undo before a branch edit")
        history.commit([makeAnnotation(index: 999)])
        try expect(!history.canRedo, "A branch edit did not clear redo history")
    }

    private static func testAnnotationMoveModifyAndDelete() throws {
        let crop = PixelRect(x: 0, y: 0, width: 100, height: 80)
        let arrow = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 40, y: 40)
        )
        let rectangle = ScreenshotAnnotation(
            kind: .rectangle,
            start: PixelPoint(x: 10, y: 10),
            end: PixelPoint(x: 30, y: 30),
            color: .yellow,
            lineWidth: 3
        )
        let mosaic = ScreenshotAnnotation(
            kind: .mosaic,
            start: PixelPoint(x: 50, y: 10),
            end: PixelPoint(x: 75, y: 35)
        )
        let text = ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: 10, y: 45),
            end: PixelPoint(x: 50, y: 70),
            color: .white,
            text: "中文标注",
            fontSize: 18
        )

        var editor = ScreenshotEditorState(cropRect: crop)
        editor.commitAnnotations([arrow, rectangle, mosaic, text])
        var edited = editor.history.annotations

        guard let arrowIndex = edited.firstIndex(where: { $0.id == arrow.id }) else {
            throw ScreenshotTestFailure.assertion("Selected arrow was not found by ID")
        }
        edited[arrowIndex] = edited[arrowIndex].translated(dx: 200, dy: 200, within: crop)
        try expect(
            edited[arrowIndex].start == PixelPoint(x: 80, y: 60)
                && edited[arrowIndex].end == PixelPoint(x: 100, y: 80),
            "Moving an annotation did not clamp it to the crop"
        )

        guard let rectangleIndex = edited.firstIndex(where: { $0.id == rectangle.id }) else {
            throw ScreenshotTestFailure.assertion("Selected rectangle was not found by ID")
        }
        edited[rectangleIndex].end = PixelPoint(x: 45, y: 38)
        edited[rectangleIndex].color = .blue
        edited[rectangleIndex].lineWidth = 7
        edited.removeAll { $0.id == mosaic.id }
        editor.commitAnnotations(edited)

        let current = editor.history.annotations
        try expect(current.count == 3, "Deleting one annotation changed the wrong count")
        try expect(!current.contains(where: { $0.id == mosaic.id }), "Deleted mosaic remained")
        try expect(
            current.first(where: { $0.id == rectangle.id })?.end == PixelPoint(x: 45, y: 38),
            "Rectangle geometry modification was lost"
        )
        try expect(
            current.first(where: { $0.id == rectangle.id })?.color == .blue,
            "Rectangle style modification was lost"
        )
        try expect(
            current.first(where: { $0.id == rectangle.id })?.lineWidth == 7,
            "A non-preset rectangle width was lost"
        )
        try expect(current.first(where: { $0.id == text.id }) == text, "Unselected text was modified")

        try expect(editor.undo(), "Annotation edit/delete transaction could not be undone")
        try expect(editor.history.annotations.count == 4, "Undo did not restore the deleted annotation")
        try expect(editor.redo(), "Annotation edit/delete transaction could not be redone")
        try expect(editor.history.annotations.count == 3, "Redo did not restore the deletion")
    }

    private static func testMarkedTextReturnPolicy() throws {
        try expect(
            !ScreenshotTextCommandPolicy.shouldCommitReturn(hasMarkedText: true),
            "Return committed while an IME marked-text composition was active"
        )
        try expect(
            ScreenshotTextCommandPolicy.shouldCommitReturn(hasMarkedText: false),
            "Return did not commit after marked text ended"
        )

        let chinese = ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: 4, y: 8),
            end: PixelPoint(x: 80, y: 32),
            text: "拼音输入完成",
            fontSize: 20
        )
        let encoded = try JSONEncoder().encode(chinese)
        let decoded = try JSONDecoder().decode(ScreenshotAnnotation.self, from: encoded)
        try expect(decoded == chinese, "Chinese text annotation did not survive model serialization")
        try expect(
            chinese.bounds.width >= 100,
            "Chinese text bounds still use a half-width character estimate"
        )
    }

    private static func testSessionGenerationAndRevisionGate() throws {
        var gate = ScreenshotSessionGate()
        let firstCapture = gate.begin()
        try expect(gate.accepts(firstCapture), "New screenshot token was rejected")

        let firstEdit = gate.mutate()
        try expect(!gate.accepts(firstCapture), "Pre-edit screenshot token survived a revision")
        try expect(gate.accepts(firstEdit), "Current edit token was rejected")

        gate.end()
        try expect(!gate.accepts(firstEdit), "Cancelled screenshot token remained accepted")
        try expect(!gate.isActive, "Ending a screenshot left the session active")

        let secondCapture = gate.begin()
        try expect(secondCapture.generation != firstCapture.generation, "New session reused a generation")
        try expect(secondCapture.revision == 0, "New session did not reset revision")
        try expect(!gate.accepts(firstCapture), "Late capture result polluted a new session")
        try expect(!gate.accepts(firstEdit), "Late render result polluted a new session")
        try expect(gate.accepts(secondCapture), "New session token was rejected")

        let secondEdit = gate.mutate()
        try expect(!gate.accepts(secondCapture), "Late encode result survived a revision change")
        try expect(gate.accepts(secondEdit), "Latest save token was rejected")
    }

    private static func testHotKeyConflictAndLifecycle() throws {
        let suiteName = "QuickStashTests.screenshot.hotkey.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ScreenshotTestFailure.assertion("Could not create isolated hot-key defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = ScreenshotPreferences(defaults: defaults)
        let registrar = FakeHotKeyRegistrar()
        registrar.registerStatuses = [noErr, OSStatus(eventHotKeyExistsErr), noErr]
        let manager = GlobalHotKeyManager(preferences: preferences, registrar: registrar)
        var actionCount = 0

        try expect(manager.start { actionCount += 1 }, "Default screenshot hot key did not register")
        try expect(manager.isRegistered, "Manager did not publish successful registration")
        try expect(preferences.hotKey == .defaultScreenshot, "Default hot key changed during start")
        try expect(
            HotKeyDescriptor.defaultScreenshot.keyCode == UInt32(kVK_ANSI_A)
                && HotKeyDescriptor.defaultScreenshot.carbonModifiers == UInt32(cmdKey | shiftKey),
            "Default shortcut descriptor is not Command+Shift+A"
        )
        try expect(
            HotKeyDescriptor.defaultScreenshot.displayName == "⇧⌘A",
            "Default shortcut is not Command+Shift+A"
        )
        registrar.fire(id: 1)
        try expect(actionCount == 1, "Registered hot key did not invoke its action")

        let conflicting = HotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_B),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "B"
        )
        try expect(!manager.update(conflicting), "Conflicting hot key unexpectedly registered")
        try expect(manager.isRegistered, "Conflict disabled the existing hot key")
        try expect(preferences.hotKey == .defaultScreenshot, "Conflict persisted the rejected shortcut")
        try expect(registrar.unregisteredIDs.isEmpty, "Conflict unregistered the working shortcut")
        registrar.fire(id: 1)
        try expect(actionCount == 2, "Conflict stopped the old shortcut action")

        let replacement = HotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_C),
            carbonModifiers: UInt32(controlKey | optionKey),
            keyLabel: "C"
        )
        try expect(manager.update(replacement), "Valid replacement hot key did not register")
        try expect(preferences.hotKey == replacement, "Successful replacement was not persisted")
        try expect(registrar.unregisteredIDs == [1], "Successful switch did not unregister the old ID")
        registrar.fire(id: 1)
        try expect(actionCount == 2, "Retired hot-key ID still invoked the action")
        registrar.fire(id: 3)
        try expect(actionCount == 3, "Replacement hot-key ID did not invoke the action")

        let missingModifier = HotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifiers: 0,
            keyLabel: "D"
        )
        let registrationCount = registrar.registrations.count
        try expect(!manager.update(missingModifier), "Modifier-free global shortcut was accepted")
        try expect(
            registrar.registrations.count == registrationCount,
            "Modifier validation still called the registrar"
        )
        try expect(preferences.hotKey == replacement, "Rejected modifier-free shortcut was persisted")

        let reloadedPreferences = ScreenshotPreferences(defaults: defaults)
        try expect(reloadedPreferences.hotKey == replacement, "Hot-key preference did not reload")
        manager.stop()
        try expect(registrar.unregisteredIDs == [1, 3], "Stop did not unregister the current ID")
        try expect(registrar.uninstallCount == 1, "Stop did not uninstall the Carbon handler")
        try expect(!manager.isRegistered, "Stop left the manager registered")
    }

    private static func testHotKeySignatureOwnership() throws {
        let owned = EventHotKeyID(signature: quickStashHotKeySignature, id: 7)
        let foreign = EventHotKeyID(signature: 0x464F524E, id: 7) // FORN
        try expect(
            quickStashOwnsHotKeyID(owned),
            "QuickStash hot-key signature was rejected"
        )
        try expect(
            !quickStashOwnsHotKeyID(foreign),
            "Foreign hot-key signature was accepted"
        )
    }

    private static func testRenderingAndEncoding() throws {
        let source = try makeSourceImage(width: 80, height: 60)
        let crop = PixelRect(x: 8, y: 6, width: 48, height: 36)
        let annotations = [
            ScreenshotAnnotation(
                kind: .arrow,
                start: PixelPoint(x: 12, y: 12),
                end: PixelPoint(x: 40, y: 25),
                color: .red,
                lineWidth: 3
            ),
            ScreenshotAnnotation(
                kind: .rectangle,
                start: PixelPoint(x: 16, y: 10),
                end: PixelPoint(x: 46, y: 30),
                color: .green,
                lineWidth: 2
            ),
            ScreenshotAnnotation(
                kind: .mosaic,
                start: PixelPoint(x: 30, y: 18),
                end: PixelPoint(x: 50, y: 36)
            ),
            ScreenshotAnnotation(
                kind: .text,
                start: PixelPoint(x: 10, y: 8),
                end: PixelPoint(x: 44, y: 28),
                color: .white,
                text: "截图",
                fontSize: 14
            ),
            ScreenshotAnnotation(
                kind: .freehand,
                start: PixelPoint(x: 12, y: 32),
                end: PixelPoint(x: 42, y: 32),
                color: .yellow,
                lineWidth: 3,
                points: [
                    PixelPoint(x: 12, y: 32),
                    PixelPoint(x: 22, y: 20),
                    PixelPoint(x: 32, y: 34),
                    PixelPoint(x: 42, y: 32)
                ]
            )
        ]
        let rendered = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: annotations
        ))
        try expect(rendered.width == 48 && rendered.height == 36, "Rendered crop dimensions changed")

        let png = try ScreenshotRenderer.encode(rendered, format: .png)
        let jpeg = try ScreenshotRenderer.encode(rendered, format: .jpeg)
        try expect(
            png.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            "PNG signature is invalid"
        )
        try expect(jpeg.prefix(2).elementsEqual([0xFF, 0xD8]), "JPEG start marker is invalid")
        try expect(jpeg.suffix(2).elementsEqual([0xFF, 0xD9]), "JPEG end marker is invalid")
        try expectDecodedSize(png, width: 48, height: 36, label: "PNG")
        try expectDecodedSize(jpeg, width: 48, height: 36, label: "JPEG")
    }

    private static func testCornerRadiusAdjustmentAndRendering() throws {
        let crop = PixelRect(x: 8, y: 6, width: 48, height: 36)
        var adjustment = ScreenshotCornerRadiusAdjustment(cornerRadius: 10, cropRect: crop)
        adjustment.preview(10_000)
        try expect(adjustment.originalCornerRadius == 10, "Corner adjustment lost its original value")
        try expect(
            adjustment.previewCornerRadius == 18,
            "Corner adjustment did not clamp to half of the short edge"
        )
        try expect(adjustment.hasChange, "Corner adjustment did not report its preview change")

        let annotation = ScreenshotAnnotation(
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
        var history = ScreenshotEditHistory(maximumDepth: 100)
        history.reset(annotations: [annotation], cornerRadius: 10)
        history.commit(history.annotations, cornerRadius: adjustment.previewCornerRadius)
        try expect(history.undoStack.count == 1, "A corner slider drag created multiple undo steps")
        try expect(history.cornerRadius == 18, "Corner slider commit lost its preview value")
        try expect(history.undo(), "Corner radius could not be undone")
        try expect(history.cornerRadius == 10, "Undo did not restore the previous corner radius")
        try expect(history.redo(), "Corner radius could not be redone")
        try expect(history.cornerRadius == 18, "Redo did not restore the adjusted corner radius")
        try expect(history.annotations == [annotation], "Corner undo modified existing annotations")

        let source = try makeSourceImage(width: 80, height: 60)
        let rendered = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: [annotation],
            cornerRadius: 12
        ))
        let renderedCorner = try rgbaPixel(in: rendered, x: 0, y: 0)
        try expect(
            renderedCorner[3] == 0,
            "Rounded crop left an opaque top-left corner"
        )
        let renderedInterior = try rgbaPixel(
            in: rendered,
            x: rendered.width / 2,
            y: rendered.height / 2
        )
        try expect(
            renderedInterior[3] == 255,
            "Rounded crop made its interior transparent"
        )
        var antialiasedPixels = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                let alpha = try rgbaPixel(in: rendered, x: x, y: y)[3]
                if alpha > 0 && alpha < 255 { antialiasedPixels += 1 }
            }
        }
        try expect(antialiasedPixels > 0, "Rounded crop edge was not antialiased")

        let png = try ScreenshotRenderer.encode(rendered, format: .png)
        let decodedPNG = try decodedRGBAImage(png, label: "Rounded PNG")
        let pngCorner = try rgbaPixel(in: decodedPNG, x: 0, y: 0)
        try expect(
            pngCorner[3] == 0,
            "PNG encoding discarded transparent rounded corners"
        )

        let jpeg = try ScreenshotRenderer.encode(rendered, format: .jpeg)
        let decodedJPEG = try decodedRGBAImage(jpeg, label: "Rounded JPEG")
        let jpegCorner = try rgbaPixel(in: decodedJPEG, x: 0, y: 0)
        try expect(
            jpegCorner[0] >= 240 && jpegCorner[1] >= 240 && jpegCorner[2] >= 240
                && jpegCorner[3] == 255,
            "JPEG rounded corner was not composited onto an opaque white background"
        )
    }

    private static func testRendererPixelOrientationAndMosaicBounds() throws {
        let source = try makeCoordinateImage(width: 20, height: 16)
        let crop = PixelRect(x: 3, y: 4, width: 12, height: 9)
        do {
            _ = try ScreenshotRenderer.render(ScreenshotRenderRequest(
                sourceImage: source,
                cropRect: .zero,
                annotations: []
            ))
            throw ScreenshotTestFailure.assertion("Renderer accepted an empty crop")
        } catch ScreenshotRenderError.invalidCrop {
            // Expected.
        }
        let baseline = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: []
        ))

        for outputY in 0..<crop.height {
            for outputX in 0..<crop.width {
                let actual = try rgbaPixel(in: baseline, x: outputX, y: outputY)
                let expected = coordinatePixel(x: crop.x + outputX, y: crop.y + outputY)
                try expect(
                    actual == expected,
                    "Renderer changed source orientation at output (\(outputX), \(outputY)): \(actual) != \(expected)"
                )
            }
        }

        let mosaicBounds = PixelRect(x: 7, y: 7, width: 5, height: 4)
        let mosaic = ScreenshotAnnotation(
            kind: .mosaic,
            start: PixelPoint(x: mosaicBounds.minX, y: mosaicBounds.minY),
            end: PixelPoint(x: mosaicBounds.maxX, y: mosaicBounds.maxY)
        )
        let mosaicked = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: [mosaic]
        ))
        var changedInside = 0
        for outputY in 0..<crop.height {
            for outputX in 0..<crop.width {
                let baselinePixel = try rgbaPixel(in: baseline, x: outputX, y: outputY)
                let mosaicPixel = try rgbaPixel(in: mosaicked, x: outputX, y: outputY)
                let sourcePoint = PixelPoint(x: crop.x + outputX, y: crop.y + outputY)
                let isInside = sourcePoint.x >= mosaicBounds.minX
                    && sourcePoint.x < mosaicBounds.maxX
                    && sourcePoint.y >= mosaicBounds.minY
                    && sourcePoint.y < mosaicBounds.maxY
                if isInside {
                    if baselinePixel != mosaicPixel { changedInside += 1 }
                } else {
                    try expect(
                        baselinePixel == mosaicPixel,
                        "Mosaic changed a pixel outside its bounds at \(sourcePoint)"
                    )
                }
            }
        }
        try expect(changedInside > 0, "Mosaic did not change any pixel inside its bounds")

        let fullCrop = PixelRect(x: 0, y: 0, width: source.width, height: source.height)
        let fullMosaic = ScreenshotAnnotation(
            kind: .mosaic,
            start: .zero,
            end: PixelPoint(x: source.width, y: source.height)
        )
        let fullMosaicRender = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: fullCrop,
            annotations: [fullMosaic]
        ))
        let croppedMosaicRender = try ScreenshotRenderer.render(ScreenshotRenderRequest(
            sourceImage: source,
            cropRect: crop,
            annotations: [fullMosaic]
        ))
        for outputY in 0..<crop.height {
            for outputX in 0..<crop.width {
                let croppedPixel = try rgbaPixel(
                    in: croppedMosaicRender,
                    x: outputX,
                    y: outputY
                )
                let fullPixel = try rgbaPixel(
                    in: fullMosaicRender,
                    x: crop.x + outputX,
                    y: crop.y + outputY
                )
                try expect(
                    croppedPixel == fullPixel,
                    "Mosaic sampling phase shifted for a nonzero crop"
                )
            }
        }
    }

    private static func testDragPresentationGate() throws {
        var gate = DragPresentationGate()
        try expect(gate.showOverlay(), "Drag overlay could not be shown initially")
        let oldHideToken = gate.makeHideToken()
        try expect(gate.acceptsHideToken(oldHideToken), "Current hide token was rejected")

        gate.setSuspended(true)
        try expect(gate.isSuspended, "Screenshot did not suspend drag presentation")
        try expect(!gate.isOverlayVisible, "Suspending screenshot interaction left the overlay visible")
        try expect(!gate.acceptsHideToken(oldHideToken), "Pre-screenshot hide token survived suspension")
        try expect(!gate.showOverlay(), "Drag overlay opened while screenshot interaction was active")

        gate.setSuspended(false)
        try expect(!gate.isSuspended, "Screenshot completion did not resume drag presentation")
        try expect(gate.showOverlay(), "A new drag could not show the overlay after resume")
        let newHideToken = gate.makeHideToken()
        try expect(gate.acceptsHideToken(newHideToken), "Post-resume hide token was rejected")
        try expect(!gate.acceptsHideToken(oldHideToken), "Old hide token matched a resumed overlay")
        try expect(gate.hideOverlay(), "Current overlay could not be hidden")
        try expect(!gate.isOverlayVisible, "Hidden overlay remained visible in the gate")
    }

    private static func testDragProximityArmsWithoutPresenting() throws {
        var gate = DragPresentationGate()

        try expect(gate.armDropTarget(), "Drag proximity did not arm the drop target")
        try expect(gate.isDropTargetArmed, "Armed drop target state was not recorded")
        try expect(gate.isActive, "Armed drop target was not considered active")
        try expect(!gate.isOverlayVisible, "Proximity alone presented the drop overlay")
        try expect(!gate.armDropTarget(), "Repeated proximity re-armed the same drop target")

        try expect(gate.showOverlay(), "Confirmed file drag did not present the armed target")
        try expect(gate.isOverlayVisible, "Confirmed file drag remained invisible")
        try expect(gate.hideOverlay(), "Active drop target could not be hidden")
        try expect(!gate.isDropTargetArmed, "Hidden overlay left the drop target armed")
        try expect(!gate.isActive, "Hidden drop target remained active")

        try expect(gate.armDropTarget(), "Drop target could not be re-armed")
        gate.setSuspended(true)
        try expect(!gate.isDropTargetArmed, "Screenshot suspension left the drop target armed")
        try expect(!gate.isActive, "Screenshot suspension left drag presentation active")
    }

    private static func testStatusItemHoverPolicyRejectsDragGestures() throws {
        try expect(
            StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 0),
            "Pointer hover without a pressed button was rejected"
        )
        try expect(
            !StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 1),
            "A left-button drag was treated as a status-item hover"
        )
        try expect(
            !StatusItemHoverPolicy.shouldPresentHover(pressedMouseButtons: 2),
            "A right-button drag was treated as a status-item hover"
        )
    }

    private static func testStatusItemHoverSuppressionRequiresPointerExit() throws {
        var gate = StatusItemHoverGate()
        try expect(
            !gate.shouldPresentOnEnter(pressedMouseButtons: 1),
            "Dragging into the status item was treated as a hover"
        )
        try expect(gate.isSuppressedUntilPointerExit, "Drag hover suppression was not recorded")
        try expect(
            !gate.shouldPresentOnEnter(pressedMouseButtons: 0),
            "Releasing inside the status item presented a hover window"
        )

        gate.pointerExited()
        try expect(!gate.isSuppressedUntilPointerExit, "Pointer exit did not clear hover suppression")
        try expect(
            gate.shouldPresentOnEnter(pressedMouseButtons: 0),
            "Normal hover did not resume after pointer exit"
        )

        gate.suppressUntilPointerExit()
        try expect(
            !gate.shouldPresentOnEnter(pressedMouseButtons: 0),
            "Global drag proximity suppression did not survive button release"
        )
        gate.pointerExited()
    }

    private static func testArmedDropTargetWatchdogOnlyHidesInvisibleTarget() throws {
        try expect(
            ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: false,
                hasActiveFileDrag: false,
                pressedMouseButtons: 0
            ),
            "Released invisible drop target was not cleaned up"
        )
        try expect(
            !ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: true,
                hasActiveFileDrag: false,
                pressedMouseButtons: 0
            ),
            "Watchdog could hide a confirmed file drag presentation"
        )
        try expect(
            !ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: false,
                hasActiveFileDrag: false,
                pressedMouseButtons: 1
            ),
            "Watchdog hid an invisible target while dragging was still active"
        )
        try expect(
            !ArmedDropTargetWatchdogPolicy.shouldHide(
                isDropTargetActive: true,
                isPresentationVisible: false,
                hasActiveFileDrag: true,
                pressedMouseButtons: 0
            ),
            "Watchdog hid a confirmed file drag before its presentation callback"
        )
    }

    private static func testDragPasteboardReader() throws {
        try expect(
            DragPasteboardReader.defaultMaximumCount == ImportPolicy.default.maximumSourceItems + 1,
            "Drag pasteboard parsing is not capped at the import limit plus one"
        )
        let pasteboard = NSPasteboard(name: .init("QuickStashTests.drag.\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()

        let firstURL = URL(fileURLWithPath: "/tmp/quickstash-drag-first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/quickstash-drag-second.txt")
        let items = [firstURL, secondURL].map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        let nonFileItem = NSPasteboardItem()
        nonFileItem.setString("https://example.com/not-a-file", forType: .fileURL)
        try expect(pasteboard.writeObjects(items + [nonFileItem]), "Could not seed named drag pasteboard")

        try expect(
            DragPasteboardReader.fileURLs(from: pasteboard, maximumCount: 2)
                == [firstURL.standardizedFileURL, secondURL.standardizedFileURL],
            "Drag reader changed URL order or ignored the maximum count"
        )
        try expect(
            DragPasteboardReader.fileURLs(from: pasteboard, maximumCount: 0).isEmpty,
            "Drag reader ignored a zero maximum count"
        )
        try expect(
            DragPasteboardReader.fileURLs(from: pasteboard, maximumCount: 3).count == 2,
            "Drag reader accepted a non-file URL"
        )
    }

    private static func testPointerEventCoalescing() async throws {
        let recorder = PointerEventRecorder()
        let relay = GlobalPointerEventRelay { event in recorder.append(event) }
        relay.submit(.moved)
        relay.submit(.dragged)
        relay.submit(.released)

        try await waitUntil("coalesced pointer delivery") { recorder.events.count == 1 }
        try expect(recorder.events == [.released], "Pointer relay did not preserve the latest pending event")

        relay.submit(.released)
        relay.submit(.dragged)
        try await waitUntil("second pointer delivery") { recorder.events.count == 2 }
        try expect(
            recorder.events == [.released, .dragged],
            "A new drag was swallowed by the previous release"
        )

        relay.submit(.moved)
        try await waitUntil("third pointer delivery") { recorder.events.count == 3 }
        try expect(
            recorder.events == [.released, .dragged, .moved],
            "Pointer relay remained stuck after delivery"
        )
    }

    private static func testRenderEncodeCancelStress() async throws {
        let source = try makeSourceImage(width: 96, height: 72)
        var gate = ScreenshotSessionGate()
        var previousToken: ScreenshotSessionToken?
        let pasteboard = NSPasteboard(name: .init("QuickStashTests.screenshot-output.\(UUID().uuidString)"))
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashScreenshotStress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer {
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: outputRoot)
        }

        for index in 0..<100 {
            let captureToken = gate.begin()
            if let previousToken {
                try expect(!gate.accepts(previousToken), "Round \(index) accepted a previous session token")
            }
            let renderToken = gate.mutate()
            try expect(!gate.accepts(captureToken), "Round \(index) accepted a stale capture revision")
            try expect(gate.accepts(renderToken), "Round \(index) rejected its render token")

            let crop = PixelRect(
                x: index % 16,
                y: index % 12,
                width: 32,
                height: 24
            )
            let annotation: ScreenshotAnnotation
            switch index % 5 {
            case 0:
                annotation = ScreenshotAnnotation(
                    kind: .arrow,
                    start: PixelPoint(x: crop.x + 2, y: crop.y + 2),
                    end: PixelPoint(x: crop.x + 26, y: crop.y + 18),
                    color: .red,
                    lineWidth: 2
                )
            case 1:
                annotation = ScreenshotAnnotation(
                    kind: .rectangle,
                    start: PixelPoint(x: crop.x + 2, y: crop.y + 2),
                    end: PixelPoint(x: crop.x + 28, y: crop.y + 20),
                    color: .blue,
                    lineWidth: 2
                )
            case 2:
                annotation = ScreenshotAnnotation(
                    kind: .mosaic,
                    start: PixelPoint(x: crop.x + 4, y: crop.y + 4),
                    end: PixelPoint(x: crop.x + 24, y: crop.y + 18)
                )
            case 3:
                let points = [
                    PixelPoint(x: crop.x + 2, y: crop.y + 18),
                    PixelPoint(x: crop.x + 9, y: crop.y + 5),
                    PixelPoint(x: crop.x + 18, y: crop.y + 19),
                    PixelPoint(x: crop.x + 29, y: crop.y + 7)
                ]
                annotation = ScreenshotAnnotation(
                    kind: .freehand,
                    start: points[0],
                    end: points[3],
                    color: .green,
                    lineWidth: index % 24 + 1,
                    points: points
                )
            default:
                annotation = ScreenshotAnnotation(
                    kind: .text,
                    start: PixelPoint(x: crop.x + 2, y: crop.y + 2),
                    end: PixelPoint(x: crop.x + 28, y: crop.y + 20),
                    color: .white,
                    text: "轮次\(index)",
                    fontSize: 10
                )
            }

            let request = ScreenshotRenderRequest(
                sourceImage: source,
                cropRect: crop,
                annotations: [annotation]
            )

            let cancelledOutput = Task {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return try await ScreenshotRenderExecutor.shared.renderAndEncode(request, format: .png)
            }
            do {
                _ = try await cancelledOutput.value
                throw ScreenshotTestFailure.assertion(
                    "Round \(index) completed a pre-cancelled render"
                )
            } catch is CancellationError {
                // Expected: every stress round proves the cancellation path.
            }

            let encoded = try await ScreenshotRenderExecutor.shared.renderAndEncode(
                request,
                format: .png
            )
            pasteboard.clearContents()
            try expect(
                pasteboard.setData(encoded, forType: .png),
                "Round \(index) named clipboard rejected PNG data"
            )
            try expect(
                pasteboard.data(forType: .png) == encoded,
                "Round \(index) clipboard PNG changed"
            )

            for format in ScreenshotOutputFormat.allCases {
                let destination = outputRoot.appendingPathComponent(
                    "round-\(index).\(format.filenameExtension)"
                )
                let temporaryURL = try await ScreenshotRenderExecutor.shared
                    .renderEncodeAndWriteTemporary(
                        request,
                        format: format,
                        destinationURL: destination
                    )
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                let encoded = try Data(contentsOf: destination)
                try expect(!encoded.isEmpty, "Round \(index) saved empty data")
                if format == .png {
                    try expect(
                        encoded.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                        "Round \(index) saved an invalid PNG"
                    )
                } else {
                    try expect(
                        encoded.prefix(2).elementsEqual([0xFF, 0xD8])
                            && encoded.suffix(2).elementsEqual([0xFF, 0xD9]),
                        "Round \(index) saved an invalid JPEG"
                    )
                }
                try FileManager.default.removeItem(at: destination)
            }

            gate.end()
            try expect(!gate.accepts(renderToken), "Round \(index) accepted a cancelled output token")
            previousToken = renderToken
        }
    }

    private static func makeAnnotation(index: Int) -> ScreenshotAnnotation {
        ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: index % 40, y: index % 30),
            end: PixelPoint(x: index % 40 + 30, y: index % 30 + 20),
            color: .red,
            text: "annotation-\(index)",
            fontSize: 14
        )
    }

    private static func makeSourceImage(width: Int, height: Int) throws -> CGImage {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotTestFailure.assertion("Could not create synthetic image context")
        }
        context.setFillColor(CGColor(red: 0.12, green: 0.22, blue: 0.38, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.85, green: 0.28, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 3, y: 4, width: max(1, width / 2), height: max(1, height / 2)))
        guard let image = context.makeImage() else {
            throw ScreenshotTestFailure.assertion("Could not create synthetic source image")
        }
        return image
    }

    private static func makeCoordinateImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                bytes.append(contentsOf: coordinatePixel(x: x, y: y))
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
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
              ) else {
            throw ScreenshotTestFailure.assertion("Could not create coordinate source image")
        }
        return image
    }

    private static func coordinatePixel(x: Int, y: Int) -> [UInt8] {
        [
            UInt8((x * 11 + 17) % 251),
            UInt8((y * 13 + 23) % 251),
            UInt8((x * 7 + y * 5 + 31) % 251),
            255
        ]
    }

    private static func rgbaPixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard x >= 0, x < image.width, y >= 0, y < image.height,
              let providerData = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(providerData) else {
            throw ScreenshotTestFailure.assertion("Could not read rendered pixel data")
        }
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: pointer + offset, count: 4))
    }

    private static func expectDecodedSize(
        _ data: Data,
        width: Int,
        height: Int,
        label: String
    ) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotTestFailure.assertion("\(label) could not be decoded")
        }
        try expect(image.width == width, "\(label) decoded width changed")
        try expect(image.height == height, "\(label) decoded height changed")
    }

    private static func decodedRGBAImage(_ data: Data, label: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil,
                  width: decoded.width,
                  height: decoded.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotTestFailure.assertion("\(label) could not be decoded as RGBA")
        }
        context.clear(CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let image = context.makeImage() else {
            throw ScreenshotTestFailure.assertion("\(label) could not be normalized as RGBA")
        }
        return image
    }

    private static func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
        }
        throw ScreenshotTestFailure.assertion("Timed out waiting for \(description)")
    }
}
