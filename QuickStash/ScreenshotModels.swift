import CoreGraphics
import CoreText
import Foundation

struct PixelPoint: Codable, Equatable, Sendable {
    var x: Int
    var y: Int

    static let zero = PixelPoint(x: 0, y: 0)
}

struct PixelSize: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
}

struct PixelRect: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from first: PixelPoint, to second: PixelPoint) {
        x = min(first.x, second.x)
        y = min(first.y, second.y)
        width = abs(second.x - first.x)
        height = abs(second.y - first.y)
    }

    var minX: Int { x }
    var minY: Int { y }
    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var midX: Int { x + width / 2 }
    var midY: Int { y + height / 2 }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func contains(_ point: PixelPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func insetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(
            x: x + dx,
            y: y + dy,
            width: max(0, width - 2 * dx),
            height: max(0, height - 2 * dy)
        )
    }

    func clamped(to size: PixelSize, minimumSize: Int = 1) -> PixelRect {
        let boundedWidth = min(max(minimumSize, width), max(minimumSize, size.width))
        let boundedHeight = min(max(minimumSize, height), max(minimumSize, size.height))
        return PixelRect(
            x: min(max(0, x), max(0, size.width - boundedWidth)),
            y: min(max(0, y), max(0, size.height - boundedHeight)),
            width: boundedWidth,
            height: boundedHeight
        )
    }

    func translated(dx: Int, dy: Int, within size: PixelSize) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
            .clamped(to: size, minimumSize: min(width, height))
    }
}

struct ScreenshotDisplayGeometry: Equatable, Sendable {
    let displayID: UInt32
    let frameInScreenPoints: CGRect
    let pixelSize: PixelSize

    func pixelPoint(fromGlobalScreenPoint point: CGPoint) -> PixelPoint? {
        guard frameInScreenPoints.contains(point),
              frameInScreenPoints.width > 0,
              frameInScreenPoints.height > 0 else { return nil }
        let local = CGPoint(
            x: point.x - frameInScreenPoints.minX,
            y: frameInScreenPoints.maxY - point.y
        )
        return ScreenshotGeometry.pixelPoint(
            fromViewPoint: local,
            viewSize: frameInScreenPoints.size,
            imageSize: pixelSize,
            isViewFlipped: true
        )
    }

    func globalScreenPoint(fromPixelPoint point: PixelPoint) -> CGPoint {
        let local = ScreenshotGeometry.viewPoint(
            fromPixelPoint: point,
            viewSize: frameInScreenPoints.size,
            imageSize: pixelSize,
            isViewFlipped: true
        )
        return CGPoint(
            x: frameInScreenPoints.minX + local.x,
            y: frameInScreenPoints.maxY - local.y
        )
    }
}

struct ScreenshotWindowRegion: Equatable, Sendable {
    let windowID: CGWindowID
    let pixelRect: PixelRect
    let order: Int
    let cornerRadius: Int

    init(
        windowID: CGWindowID,
        pixelRect: PixelRect,
        order: Int,
        cornerRadius: Int = 0
    ) {
        self.windowID = windowID
        self.pixelRect = pixelRect
        self.order = order
        self.cornerRadius = ScreenshotCropStylePolicy.clampedCornerRadius(
            cornerRadius,
            for: pixelRect
        )
    }
}

enum ScreenshotCropStylePolicy {
    static let maximumAdjustableCornerRadius = 120
    static let standardWindowCornerRadiusPoints: CGFloat = 10

    static func maximumCornerRadius(for rect: PixelRect) -> Int {
        guard !rect.isEmpty else { return 0 }
        return min(
            maximumAdjustableCornerRadius,
            max(0, min(rect.width, rect.height) / 2)
        )
    }

    static func clampedCornerRadius(_ value: Int, for rect: PixelRect) -> Int {
        min(max(0, value), maximumCornerRadius(for: rect))
    }

    static func automaticWindowCornerRadius(
        windowFrame: CGRect,
        displayFrame: CGRect,
        imageSize: PixelSize,
        pixelRect: PixelRect
    ) -> Int {
        let window = windowFrame.standardized
        let display = displayFrame.standardized
        guard display.contains(window), display.width > 0, display.height > 0 else {
            return 0
        }
        let fillsDisplay = abs(window.minX - display.minX) <= 1
            && abs(window.minY - display.minY) <= 1
            && abs(window.maxX - display.maxX) <= 1
            && abs(window.maxY - display.maxY) <= 1
        guard !fillsDisplay else { return 0 }
        let scaleX = CGFloat(imageSize.width) / display.width
        let scaleY = CGFloat(imageSize.height) / display.height
        let physicalRadius = Int((standardWindowCornerRadiusPoints * min(scaleX, scaleY)).rounded())
        return clampedCornerRadius(physicalRadius, for: pixelRect)
    }
}

struct ScreenshotArrowGeometry: Equatable, Sendable {
    let shaftEnd: CGPoint
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint
}

enum ScreenshotResizeHandle: Int, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

enum ScreenshotTool: Int, CaseIterable, Sendable {
    case select
    case arrow
    case rectangle
    case mosaic
    case text
    case freehand
}

enum ScreenshotColor: Int, CaseIterable, Codable, Sendable {
    case red
    case yellow
    case green
    case blue
    case white
    case black

    var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch self {
        case .red: return (0.96, 0.18, 0.20, 1)
        case .yellow: return (1, 0.78, 0.08, 1)
        case .green: return (0.16, 0.72, 0.35, 1)
        case .blue: return (0.13, 0.47, 0.95, 1)
        case .white: return (1, 1, 1, 1)
        case .black: return (0.03, 0.03, 0.04, 1)
        }
    }

    var cgColor: CGColor {
        let value = rgba
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [value.0, value.1, value.2, value.3]
        ) ?? CGColor(gray: 0, alpha: 1)
    }
}

enum ScreenshotAnnotationKind: Int, Codable, Sendable {
    case arrow
    case rectangle
    case mosaic
    case text
    case freehand
}

struct ScreenshotStyleControlVisibility: Equatable, Sendable {
    let showsColor: Bool
    let showsLineWidth: Bool

    var isEmpty: Bool { !showsColor && !showsLineWidth }
}

enum ScreenshotAnnotationStylePolicy {
    static let defaultLineWidth = 4
    static let lineWidthRange = 1...24

    static func clampedLineWidth(_ value: Int) -> Int {
        min(max(lineWidthRange.lowerBound, value), lineWidthRange.upperBound)
    }

    static func controls(
        for tool: ScreenshotTool,
        selectedAnnotationKind: ScreenshotAnnotationKind?
    ) -> ScreenshotStyleControlVisibility {
        let kind = selectedAnnotationKind ?? annotationKind(for: tool)
        return ScreenshotStyleControlVisibility(
            showsColor: kind.map(supportsColor) ?? false,
            showsLineWidth: kind.map(supportsLineWidth) ?? false
        )
    }

    static func supportsColor(_ kind: ScreenshotAnnotationKind) -> Bool {
        switch kind {
        case .arrow, .rectangle, .text, .freehand:
            return true
        case .mosaic:
            return false
        }
    }

    static func supportsLineWidth(_ kind: ScreenshotAnnotationKind) -> Bool {
        switch kind {
        case .arrow, .rectangle, .freehand:
            return true
        case .mosaic, .text:
            return false
        }
    }

    private static func annotationKind(for tool: ScreenshotTool) -> ScreenshotAnnotationKind? {
        switch tool {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .mosaic: return .mosaic
        case .text: return .text
        case .freehand: return .freehand
        case .select: return nil
        }
    }
}

struct ScreenshotAnnotation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: ScreenshotAnnotationKind
    var start: PixelPoint
    var end: PixelPoint
    var color: ScreenshotColor
    var lineWidth: Int
    var text: String
    var fontSize: Int
    var points: [PixelPoint]

    init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        start: PixelPoint,
        end: PixelPoint,
        color: ScreenshotColor = .red,
        lineWidth: Int = ScreenshotAnnotationStylePolicy.defaultLineWidth,
        text: String = "",
        fontSize: Int = 20,
        points: [PixelPoint] = []
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
        self.points = points
    }

    var bounds: PixelRect {
        switch kind {
        case .text:
            let measured = ScreenshotTextLayout.pixelSize(text: text, fontSize: fontSize)
            return PixelRect(
                x: start.x,
                y: start.y,
                width: max(measured.width, end.x - start.x),
                height: max(measured.height, end.y - start.y)
            )
        case .freehand:
            let path = points.isEmpty ? [start, end] : points
            let xs = path.map(\.x)
            let ys = path.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else {
                return PixelRect(from: start, to: end)
            }
            return PixelRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX),
                height: max(1, maxY - minY)
            )
        default:
            return PixelRect(from: start, to: end)
        }
    }

    func translated(dx: Int, dy: Int, within crop: PixelRect) -> ScreenshotAnnotation {
        var result = self
        let originalBounds = bounds
        let targetX = min(max(crop.minX, originalBounds.minX + dx), crop.maxX - originalBounds.width)
        let targetY = min(max(crop.minY, originalBounds.minY + dy), crop.maxY - originalBounds.height)
        let appliedX = targetX - originalBounds.minX
        let appliedY = targetY - originalBounds.minY
        result.start.x += appliedX
        result.start.y += appliedY
        result.end.x += appliedX
        result.end.y += appliedY
        result.points = result.points.map {
            PixelPoint(x: $0.x + appliedX, y: $0.y + appliedY)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case start
        case end
        case color
        case lineWidth
        case text
        case fontSize
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ScreenshotAnnotationKind.self, forKey: .kind)
        start = try container.decode(PixelPoint.self, forKey: .start)
        end = try container.decode(PixelPoint.self, forKey: .end)
        color = try container.decode(ScreenshotColor.self, forKey: .color)
        lineWidth = try container.decode(Int.self, forKey: .lineWidth)
        text = try container.decode(String.self, forKey: .text)
        fontSize = try container.decode(Int.self, forKey: .fontSize)
        points = try container.decodeIfPresent([PixelPoint].self, forKey: .points) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(color, forKey: .color)
        try container.encode(lineWidth, forKey: .lineWidth)
        try container.encode(text, forKey: .text)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(points, forKey: .points)
    }
}

struct ScreenshotLineWidthAdjustment: Sendable {
    let originalAnnotations: [ScreenshotAnnotation]
    let selectedAnnotationID: UUID?
    let originalLineWidth: Int
    private(set) var previewLineWidth: Int
    private(set) var previewAnnotations: [ScreenshotAnnotation]

    init(
        annotations: [ScreenshotAnnotation],
        selectedAnnotationID: UUID?,
        lineWidth: Int
    ) {
        let normalizedWidth = ScreenshotAnnotationStylePolicy.clampedLineWidth(lineWidth)
        originalAnnotations = annotations
        originalLineWidth = normalizedWidth
        previewLineWidth = normalizedWidth
        previewAnnotations = annotations
        self.selectedAnnotationID = selectedAnnotationID.flatMap { id in
            annotations.first(where: { $0.id == id }).flatMap { annotation in
                ScreenshotAnnotationStylePolicy.supportsLineWidth(annotation.kind) ? id : nil
            }
        }
    }

    mutating func preview(_ lineWidth: Int) {
        let normalizedWidth = ScreenshotAnnotationStylePolicy.clampedLineWidth(lineWidth)
        previewLineWidth = normalizedWidth
        previewAnnotations = originalAnnotations
        guard let selectedAnnotationID,
              let index = previewAnnotations.firstIndex(where: { $0.id == selectedAnnotationID }) else {
            return
        }
        previewAnnotations[index].lineWidth = normalizedWidth
    }

    var hasAnnotationChange: Bool {
        previewAnnotations != originalAnnotations
    }
}

struct ScreenshotCornerRadiusAdjustment: Equatable, Sendable {
    let originalCornerRadius: Int
    private(set) var previewCornerRadius: Int
    let cropRect: PixelRect

    init(cornerRadius: Int, cropRect: PixelRect) {
        self.cropRect = cropRect
        let normalized = ScreenshotCropStylePolicy.clampedCornerRadius(
            cornerRadius,
            for: cropRect
        )
        originalCornerRadius = normalized
        previewCornerRadius = normalized
    }

    mutating func preview(_ cornerRadius: Int) {
        previewCornerRadius = ScreenshotCropStylePolicy.clampedCornerRadius(
            cornerRadius,
            for: cropRect
        )
    }

    var hasChange: Bool { previewCornerRadius != originalCornerRadius }
}

enum ScreenshotTextLayout {
    static func pixelSize(text: String, fontSize: Int) -> PixelSize {
        let size = max(1, fontSize)
        guard !text.isEmpty else { return PixelSize(width: size, height: size) }
        let font = CTFontCreateWithName("PingFang SC" as CFString, CGFloat(size), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return PixelSize(
            width: max(size, Int(ceil(width))),
            height: max(size, Int(ceil(ascent + descent + leading)) + 2)
        )
    }
}

struct ScreenshotEditValue: Equatable, Sendable {
    var annotations: [ScreenshotAnnotation]
    var cornerRadius: Int
}

struct ScreenshotEditHistory: Sendable {
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var cornerRadius = 0
    private(set) var undoStack: [ScreenshotEditValue] = []
    private(set) var redoStack: [ScreenshotEditValue] = []
    let maximumDepth: Int

    init(maximumDepth: Int = 100) {
        self.maximumDepth = max(1, maximumDepth)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func commit(
        _ newAnnotations: [ScreenshotAnnotation],
        cornerRadius newCornerRadius: Int? = nil
    ) {
        let next = ScreenshotEditValue(
            annotations: newAnnotations,
            cornerRadius: max(0, newCornerRadius ?? cornerRadius)
        )
        guard next != currentValue else { return }
        undoStack.append(currentValue)
        if undoStack.count > maximumDepth {
            undoStack.removeFirst(undoStack.count - maximumDepth)
        }
        apply(next)
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func reset(
        annotations: [ScreenshotAnnotation] = [],
        cornerRadius: Int = 0
    ) {
        self.annotations = annotations
        self.cornerRadius = max(0, cornerRadius)
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(currentValue)
        apply(previous)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(currentValue)
        apply(next)
        return true
    }

    mutating func removeAll() {
        commit([])
    }

    private var currentValue: ScreenshotEditValue {
        ScreenshotEditValue(annotations: annotations, cornerRadius: cornerRadius)
    }

    private mutating func apply(_ value: ScreenshotEditValue) {
        annotations = value.annotations
        cornerRadius = value.cornerRadius
    }
}

struct ScreenshotEditorState: Sendable {
    private(set) var cropRect: PixelRect?
    private(set) var cropLocked = false
    private(set) var history: ScreenshotEditHistory

    init(cropRect: PixelRect? = nil, maximumHistoryDepth: Int = 100) {
        self.cropRect = cropRect
        history = ScreenshotEditHistory(maximumDepth: maximumHistoryDepth)
    }

    mutating func setCropRect(_ rect: PixelRect) -> Bool {
        guard !cropLocked else { return false }
        cropRect = rect
        return true
    }

    mutating func commitAnnotations(_ annotations: [ScreenshotAnnotation]) {
        history.commit(annotations)
        if !annotations.isEmpty {
            cropLocked = true
        }
    }

    @discardableResult
    mutating func undo() -> Bool { history.undo() }

    @discardableResult
    mutating func redo() -> Bool { history.redo() }
}

enum ScreenshotTextCommandPolicy {
    static func shouldCommitReturn(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }
}

struct ScreenshotSessionToken: Equatable, Sendable {
    let generation: UInt64
    let revision: UInt64
}

struct ScreenshotSessionGate: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var isActive = false

    mutating func begin() -> ScreenshotSessionToken {
        generation &+= 1
        revision = 0
        isActive = true
        return token
    }

    mutating func mutate() -> ScreenshotSessionToken {
        guard isActive else { return token }
        revision &+= 1
        return token
    }

    mutating func end() {
        generation &+= 1
        revision = 0
        isActive = false
    }

    var token: ScreenshotSessionToken {
        ScreenshotSessionToken(generation: generation, revision: revision)
    }

    func accepts(_ candidate: ScreenshotSessionToken) -> Bool {
        isActive && candidate == token
    }
}

enum ScreenshotGeometry {
    static func roundedRectContains(
        _ point: PixelPoint,
        rect: PixelRect,
        cornerRadius: Int
    ) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = ScreenshotCropStylePolicy.clampedCornerRadius(cornerRadius, for: rect)
        guard radius > 0 else { return true }

        let localX = CGFloat(point.x - rect.minX)
        let localY = CGFloat(point.y - rect.minY)
        let width = CGFloat(rect.width)
        let height = CGFloat(rect.height)
        let radiusValue = CGFloat(radius)
        if localX >= radiusValue, localX <= width - radiusValue {
            return true
        }
        if localY >= radiusValue, localY <= height - radiusValue {
            return true
        }

        let centerX = localX < radiusValue ? radiusValue : width - radiusValue
        let centerY = localY < radiusValue ? radiusValue : height - radiusValue
        let dx = localX - centerX
        let dy = localY - centerY
        return dx * dx + dy * dy <= radiusValue * radiusValue
    }

    static func arrowShaftPixelWidth(lineWidth: Int) -> CGFloat {
        let width = CGFloat(ScreenshotAnnotationStylePolicy.clampedLineWidth(lineWidth))
        return width <= 4 ? width : 4 + (width - 4) * 0.3
    }

    static func viewLineWidth(
        sourcePixelWidth: CGFloat,
        sourceWidth: Int,
        viewWidth: CGFloat,
        backingScaleFactor: CGFloat
    ) -> CGFloat {
        guard sourceWidth > 0, viewWidth > 0 else { return 0 }
        let scale = max(backingScaleFactor, 1)
        return max(
            1 / scale,
            max(1, sourcePixelWidth) / CGFloat(sourceWidth) * viewWidth
        )
    }

    static func viewLineWidth(
        sourcePixelWidth: Int,
        sourceWidth: Int,
        viewWidth: CGFloat,
        backingScaleFactor: CGFloat
    ) -> CGFloat {
        viewLineWidth(
            sourcePixelWidth: CGFloat(sourcePixelWidth),
            sourceWidth: sourceWidth,
            viewWidth: viewWidth,
            backingScaleFactor: backingScaleFactor
        )
    }

    static func arrowHeadLength(
        lineWidth: Int,
        segmentLength: CGFloat = .greatestFiniteMagnitude,
        coordinateScale: CGFloat = 1
    ) -> CGFloat {
        let scale = max(0, coordinateScale)
        let nominal = min(36, max(12, 10 + CGFloat(max(1, lineWidth)) * 1.5))
        return min(nominal * scale, max(0, segmentLength) * 0.4)
    }

    static func arrowGeometry(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: Int,
        coordinateScale: CGFloat = 1
    ) -> ScreenshotArrowGeometry {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = arrowHeadLength(
            lineWidth: lineWidth,
            segmentLength: hypot(end.x - start.x, end.y - start.y),
            coordinateScale: coordinateScale
        )
        let spread = CGFloat.pi / 7
        let shaftEnd = CGPoint(
            x: end.x - headLength * cos(angle),
            y: end.y - headLength * sin(angle)
        )
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        return ScreenshotArrowGeometry(
            shaftEnd: shaftEnd,
            tip: end,
            left: left,
            right: right
        )
    }

    static func windowPixelRect(
        windowFrame: CGRect,
        displayFrame: CGRect,
        imageSize: PixelSize
    ) -> PixelRect? {
        guard displayFrame.width > 0,
              displayFrame.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else { return nil }
        let intersection = windowFrame.standardized.intersection(displayFrame.standardized)
        guard !intersection.isNull,
              !intersection.isEmpty,
              intersection.width >= 2,
              intersection.height >= 2 else { return nil }

        let scaleX = CGFloat(imageSize.width) / displayFrame.width
        let scaleY = CGFloat(imageSize.height) / displayFrame.height
        let left = Int(((intersection.minX - displayFrame.minX) * scaleX).rounded(.down))
        let top = Int(((intersection.minY - displayFrame.minY) * scaleY).rounded(.down))
        let right = Int(((intersection.maxX - displayFrame.minX) * scaleX).rounded(.up))
        let bottom = Int(((intersection.maxY - displayFrame.minY) * scaleY).rounded(.up))
        let rect = PixelRect(
            x: left,
            y: top,
            width: max(1, right - left),
            height: max(1, bottom - top)
        ).clamped(to: imageSize)
        return rect.width >= 2 && rect.height >= 2 ? rect : nil
    }

    static func frontmostWindowRegion(
        at point: PixelPoint,
        in regions: [ScreenshotWindowRegion]
    ) -> ScreenshotWindowRegion? {
        regions
            .filter {
                roundedRectContains(
                    point,
                    rect: $0.pixelRect,
                    cornerRadius: $0.cornerRadius
                )
            }
            .min { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.windowID < rhs.windowID
            }
    }

    static func isClickGesture(
        from anchor: CGPoint,
        to current: CGPoint,
        threshold: CGFloat = 3
    ) -> Bool {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let distance = max(0, threshold)
        return dx * dx + dy * dy <= distance * distance
    }

    static func pixelPoint(
        fromViewPoint point: CGPoint,
        viewSize: CGSize,
        imageSize: PixelSize,
        isViewFlipped: Bool
    ) -> PixelPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let normalizedX = min(max(0, point.x / viewSize.width), 1)
        let rawY = isViewFlipped ? point.y : viewSize.height - point.y
        let normalizedY = min(max(0, rawY / viewSize.height), 1)
        return PixelPoint(
            x: Int((normalizedX * CGFloat(imageSize.width)).rounded()),
            y: Int((normalizedY * CGFloat(imageSize.height)).rounded())
        )
    }

    static func viewPoint(
        fromPixelPoint point: PixelPoint,
        viewSize: CGSize,
        imageSize: PixelSize,
        isViewFlipped: Bool
    ) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let x = CGFloat(point.x) / CGFloat(imageSize.width) * viewSize.width
        let topY = CGFloat(point.y) / CGFloat(imageSize.height) * viewSize.height
        return CGPoint(x: x, y: isViewFlipped ? topY : viewSize.height - topY)
    }

    static func handlePoints(for rect: PixelRect) -> [ScreenshotResizeHandle: PixelPoint] {
        [
            .topLeft: PixelPoint(x: rect.minX, y: rect.minY),
            .top: PixelPoint(x: rect.midX, y: rect.minY),
            .topRight: PixelPoint(x: rect.maxX, y: rect.minY),
            .right: PixelPoint(x: rect.maxX, y: rect.midY),
            .bottomRight: PixelPoint(x: rect.maxX, y: rect.maxY),
            .bottom: PixelPoint(x: rect.midX, y: rect.maxY),
            .bottomLeft: PixelPoint(x: rect.minX, y: rect.maxY),
            .left: PixelPoint(x: rect.minX, y: rect.midY)
        ]
    }

    static func resizing(
        _ rect: PixelRect,
        handle: ScreenshotResizeHandle,
        to point: PixelPoint,
        within imageSize: PixelSize,
        minimumSize: Int = 2
    ) -> PixelRect {
        var left = rect.minX
        var top = rect.minY
        var right = rect.maxX
        var bottom = rect.maxY
        let clampedX = min(max(0, point.x), imageSize.width)
        let clampedY = min(max(0, point.y), imageSize.height)

        switch handle {
        case .topLeft:
            left = min(clampedX, right - minimumSize)
            top = min(clampedY, bottom - minimumSize)
        case .top:
            top = min(clampedY, bottom - minimumSize)
        case .topRight:
            right = max(clampedX, left + minimumSize)
            top = min(clampedY, bottom - minimumSize)
        case .right:
            right = max(clampedX, left + minimumSize)
        case .bottomRight:
            right = max(clampedX, left + minimumSize)
            bottom = max(clampedY, top + minimumSize)
        case .bottom:
            bottom = max(clampedY, top + minimumSize)
        case .bottomLeft:
            left = min(clampedX, right - minimumSize)
            bottom = max(clampedY, top + minimumSize)
        case .left:
            left = min(clampedX, right - minimumSize)
        }

        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
            .clamped(to: imageSize, minimumSize: minimumSize)
    }
}

enum ScreenshotOutputFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    var filenameExtension: String { self == .png ? "png" : "jpg" }
}
