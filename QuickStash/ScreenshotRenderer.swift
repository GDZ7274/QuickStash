import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotRenderError: LocalizedError {
    case invalidCrop
    case contextCreationFailed
    case imageCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidCrop: return "截图选区无效"
        case .contextCreationFailed: return "无法创建截图渲染上下文"
        case .imageCreationFailed: return "无法生成截图图像"
        case .encodingFailed: return "无法编码截图"
        }
    }
}

struct ScreenshotRenderRequest: @unchecked Sendable {
    let sourceImage: CGImage
    let cropRect: PixelRect
    let annotations: [ScreenshotAnnotation]
    let cornerRadius: Int

    init(
        sourceImage: CGImage,
        cropRect: PixelRect,
        annotations: [ScreenshotAnnotation],
        cornerRadius: Int = 0
    ) {
        self.sourceImage = sourceImage
        self.cropRect = cropRect
        self.annotations = annotations
        self.cornerRadius = cornerRadius
    }
}

enum ScreenshotRenderer {
    static func render(_ request: ScreenshotRenderRequest) throws -> CGImage {
        try Task.checkCancellation()
        guard !request.cropRect.isEmpty else { throw ScreenshotRenderError.invalidCrop }
        let sourceSize = PixelSize(width: request.sourceImage.width, height: request.sourceImage.height)
        let crop = request.cropRect.clamped(to: sourceSize)
        guard !crop.isEmpty else { throw ScreenshotRenderError.invalidCrop }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotRenderError.contextCreationFailed
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        context.saveGState()
        let cornerRadius = ScreenshotCropStylePolicy.clampedCornerRadius(
            request.cornerRadius,
            for: crop
        )
        if cornerRadius > 0 {
            let outputBounds = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
            context.addPath(CGPath(
                roundedRect: outputBounds,
                cornerWidth: CGFloat(cornerRadius),
                cornerHeight: CGFloat(cornerRadius),
                transform: nil
            ))
            context.clip()
        }
        drawImage(request.sourceImage, crop: crop, in: context)

        // Annotation models use top-left, y-down pixel coordinates.
        context.translateBy(x: 0, y: CGFloat(crop.height))
        context.scaleBy(x: 1, y: -1)

        let mosaicImage: CGImage?
        if request.annotations.contains(where: { $0.kind == .mosaic }) {
            try Task.checkCancellation()
            mosaicImage = makeMosaicImage(request.sourceImage)
            try Task.checkCancellation()
        } else {
            mosaicImage = nil
        }
        for annotation in request.annotations {
            try Task.checkCancellation()
            draw(
                annotation,
                crop: crop,
                mosaicImage: mosaicImage,
                in: context
            )
        }
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw ScreenshotRenderError.imageCreationFailed
        }
        return image
    }

    static func encode(_ image: CGImage, format: ScreenshotOutputFormat) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        let type: CFString = format == .png ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw ScreenshotRenderError.encodingFailed
        }
        let encodedImage = format == .jpeg ? try opaqueImageForJPEG(image) : image
        let properties: CFDictionary = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            : [:] as CFDictionary
        CGImageDestinationAddImage(destination, encodedImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotRenderError.encodingFailed
        }
        try Task.checkCancellation()
        return data as Data
    }

    private static func draw(
        _ annotation: ScreenshotAnnotation,
        crop: PixelRect,
        mosaicImage: CGImage?,
        in context: CGContext
    ) {
        let start = CGPoint(x: annotation.start.x - crop.x, y: annotation.start.y - crop.y)
        let end = CGPoint(x: annotation.end.x - crop.x, y: annotation.end.y - crop.y)
        let bounds = annotation.bounds
        let relativeBounds = CGRect(
            x: bounds.x - crop.x,
            y: bounds.y - crop.y,
            width: bounds.width,
            height: bounds.height
        )

        switch annotation.kind {
        case .arrow:
            drawArrow(from: start, to: end, color: annotation.color.cgColor, width: annotation.lineWidth, in: context)
        case .rectangle:
            context.saveGState()
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(CGFloat(annotation.lineWidth))
            context.stroke(relativeBounds.insetBy(dx: CGFloat(annotation.lineWidth) / 2, dy: CGFloat(annotation.lineWidth) / 2))
            context.restoreGState()
        case .mosaic:
            guard let mosaicImage else { return }
            context.saveGState()
            context.clip(to: relativeBounds)
            // Return to the native bitmap CTM while drawing CGImage pixel rows.
            context.translateBy(x: 0, y: CGFloat(crop.height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            drawImage(mosaicImage, crop: crop, in: context)
            context.restoreGState()
        case .text:
            drawText(annotation.text, at: start, annotation: annotation, in: context)
        case .freehand:
            drawFreehand(annotation, crop: crop, in: context)
        }
    }

    private static func drawImage(
        _ image: CGImage,
        crop: PixelRect,
        in context: CGContext
    ) {
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(crop.x),
                y: CGFloat(crop.height - image.height + crop.y),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: CGColor,
        width: Int,
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(ScreenshotGeometry.arrowShaftPixelWidth(lineWidth: width))
        context.setLineCap(.round)
        let geometry = ScreenshotGeometry.arrowGeometry(
            from: start,
            to: end,
            lineWidth: width
        )
        context.move(to: start)
        context.addLine(to: geometry.shaftEnd)
        context.strokePath()

        context.move(to: geometry.tip)
        context.addLine(to: geometry.left)
        context.addLine(to: geometry.right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private static func opaqueImageForJPEG(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotRenderError.contextCreationFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let opaque = context.makeImage() else {
            throw ScreenshotRenderError.imageCreationFailed
        }
        return opaque
    }

    private static func drawFreehand(
        _ annotation: ScreenshotAnnotation,
        crop: PixelRect,
        in context: CGContext
    ) {
        guard let first = annotation.points.first else { return }
        let width = CGFloat(max(1, annotation.lineWidth))
        let relativeFirst = CGPoint(x: first.x - crop.x, y: first.y - crop.y)
        context.saveGState()
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        if annotation.points.count == 1 {
            context.fillEllipse(in: CGRect(
                x: relativeFirst.x - width / 2,
                y: relativeFirst.y - width / 2,
                width: width,
                height: width
            ))
        } else {
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: relativeFirst)
            for point in annotation.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x - crop.x, y: point.y - crop.y))
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        annotation: ScreenshotAnnotation,
        in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateWithName("PingFang SC" as CFString, CGFloat(annotation.fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.translateBy(x: point.x, y: point.y + CGFloat(annotation.fontSize))
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func makeMosaicImage(_ source: CGImage) -> CGImage? {
        let input = CIImage(cgImage: source)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(10.0, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }
}

struct ScreenshotImageBox: @unchecked Sendable {
    let image: CGImage
}

actor ScreenshotRenderExecutor {
    static let shared = ScreenshotRenderExecutor()

    func renderAndEncode(
        _ request: ScreenshotRenderRequest,
        format: ScreenshotOutputFormat
    ) throws -> Data {
        try Task.checkCancellation()
        let image = try ScreenshotRenderer.render(request)
        try Task.checkCancellation()
        return try ScreenshotRenderer.encode(image, format: format)
    }

    func renderEncodeAndWriteTemporary(
        _ request: ScreenshotRenderRequest,
        format: ScreenshotOutputFormat,
        destinationURL: URL
    ) throws -> URL {
        let data = try renderAndEncode(request, format: format)
        try Task.checkCancellation()
        let directory = destinationURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".quickstash-screenshot-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try Task.checkCancellation()
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func mosaicImage(for source: ScreenshotImageBox) throws -> ScreenshotImageBox? {
        try Task.checkCancellation()
        let image = ScreenshotRenderer.makeMosaicImage(source.image)
        try Task.checkCancellation()
        return image.map(ScreenshotImageBox.init(image:))
    }
}
