import Foundation
import AppKit
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardPNGEncodingError: LocalizedError, Sendable {
    case sourceTooLarge
    case invalidImage
    case sourceIncomplete
    case dimensionsTooLarge
    case encodingFailed
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge:
            return "剪贴板图片源数据过大，已跳过"
        case .invalidImage:
            return "无法解码剪贴板图片"
        case .sourceIncomplete:
            return "剪贴板图片尚未完整提供"
        case .dimensionsTooLarge:
            return "剪贴板图片像素尺寸过大，已跳过"
        case .encodingFailed:
            return "无法将剪贴板图片转换为 PNG"
        case .outputTooLarge:
            return "剪贴板图片转换为 PNG 后超过 50 MB，已跳过"
        }
    }
}

struct PreparedClipboardPNG: Sendable {
    let data: Data
    let fingerprint: String
}

enum ClipboardPNGEncoder {
    static let maximumSourceBytes = 256 * 1_024 * 1_024
    static let maximumOutputBytes = 50 * 1_024 * 1_024
    static let maximumPixelDimension: Int64 = 32_768
    static let maximumDecodedBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumPixelCount = maximumDecodedBytes / 4
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let pngCRCTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? 0xEDB8_8320 ^ (value >> 1)
                : value >> 1
        }
        return value
    }

    static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .png
            || type == .tiff
            || UTType(type.rawValue)?.conforms(to: .image) == true
    }

    static func pngData(from sourceData: Data, maximumOutputBytes: Int = maximumOutputBytes) throws -> Data {
        try prepare(from: sourceData, maximumOutputBytes: maximumOutputBytes).data
    }

    static func fingerprint(from sourceData: Data) throws -> String {
        try prepare(from: sourceData).fingerprint
    }

    static func prepare(
        from sourceData: Data,
        maximumOutputBytes: Int = maximumOutputBytes
    ) throws -> PreparedClipboardPNG {
        try autoreleasepool {
            try preparePNG(from: sourceData, maximumOutputBytes: maximumOutputBytes)
        }
    }

    static func validateDimensions(width: Int64, height: Int64) throws {
        guard width > 0,
              height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension else {
            throw ClipboardPNGEncodingError.dimensionsTooLarge
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw ClipboardPNGEncodingError.dimensionsTooLarge
        }
    }

    private static func preparePNG(
        from sourceData: Data,
        maximumOutputBytes: Int
    ) throws -> PreparedClipboardPNG {
        guard sourceData.count <= maximumSourceBytes else {
            throw ClipboardPNGEncodingError.sourceTooLarge
        }
        let hasPNGSignature = sourceData.starts(with: pngSignature)
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw ClipboardPNGEncodingError.invalidImage
        }
        guard CGImageSourceGetCount(source) > 0 else {
            switch CGImageSourceGetStatus(source) {
            case .statusIncomplete, .statusReadingHeader, .statusUnexpectedEOF:
                throw ClipboardPNGEncodingError.sourceIncomplete
            default:
                throw (hasPNGSignature || hasPlausibleIncompleteImageHeader(sourceData))
                    ? ClipboardPNGEncodingError.sourceIncomplete
                    : ClipboardPNGEncodingError.invalidImage
            }
        }
        switch CGImageSourceGetStatusAtIndex(source, 0) {
        case .statusComplete:
            break
        case .statusIncomplete, .statusReadingHeader, .statusUnexpectedEOF:
            throw ClipboardPNGEncodingError.sourceIncomplete
        default:
            throw ClipboardPNGEncodingError.invalidImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
            throw hasPNGSignature
                ? ClipboardPNGEncodingError.sourceIncomplete
                : ClipboardPNGEncodingError.invalidImage
        }
        try validateDimensions(width: width, height: height)
        try validateEstimatedDecodedSize(
            properties: properties,
            width: width,
            height: height
        )

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if hasPNGSignature, orientation == 1 {
            guard isStructurallyValidPNG(sourceData) else {
                throw ClipboardPNGEncodingError.invalidImage
            }
            guard let decodedImage = decodedImage(from: source) else {
                throw ClipboardPNGEncodingError.sourceIncomplete
            }
            try validateDecodedSize(decodedImage)
            guard sourceData.count <= maximumOutputBytes else {
                throw ClipboardPNGEncodingError.outputTooLarge
            }
            return PreparedClipboardPNG(
                data: sourceData,
                fingerprint: try pixelFingerprint(decodedImage)
            )
        }

        let image: CGImage?
        if orientation == 1 {
            image = decodedImage(from: source)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else {
            throw ClipboardPNGEncodingError.invalidImage
        }
        try validateDecodedSize(image)

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardPNGEncodingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardPNGEncodingError.encodingFailed
        }
        let pngData = output as Data
        guard pngData.starts(with: pngSignature) else {
            throw ClipboardPNGEncodingError.encodingFailed
        }
        guard pngData.count <= maximumOutputBytes else {
            throw ClipboardPNGEncodingError.outputTooLarge
        }
        return PreparedClipboardPNG(
            data: pngData,
            fingerprint: try pixelFingerprint(image)
        )
    }

    private static func pixelFingerprint(_ image: CGImage) throws -> String {
        let width = image.width
        let height = image.height
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow,
              !sizeOverflow,
              byteCount <= maximumDecodedBytes,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ClipboardPNGEncodingError.dimensionsTooLarge
        }

        var pixels = Data(count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw ClipboardPNGEncodingError.encodingFailed
        }

        var header = Data()
        var bigEndianWidth = UInt64(width).bigEndian
        var bigEndianHeight = UInt64(height).bigEndian
        withUnsafeBytes(of: &bigEndianWidth) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigEndianHeight) { header.append(contentsOf: $0) }
        var hasher = SHA256()
        hasher.update(data: header)
        hasher.update(data: pixels)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func decodedImage(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private static func isStructurallyValidPNG(_ data: Data) -> Bool {
        guard data.starts(with: pngSignature), data.count >= 8 + 12 else { return false }
        var offset = 8
        var sawHeader = false
        var sawImageData = false

        while offset <= data.count - 12 {
            let length = Int(readBigEndianUInt32(data, at: offset))
            let typeOffset = offset + 4
            let payloadOffset = typeOffset + 4
            let (crcOffset, payloadOverflow) = payloadOffset.addingReportingOverflow(length)
            let (nextOffset, chunkOverflow) = crcOffset.addingReportingOverflow(4)
            guard !payloadOverflow,
                  !chunkOverflow,
                  crcOffset >= payloadOffset,
                  nextOffset <= data.count else { return false }

            let chunkType = readBigEndianUInt32(data, at: typeOffset)
            let expectedCRC = readBigEndianUInt32(data, at: crcOffset)
            guard pngCRC(data, from: typeOffset, to: crcOffset) == expectedCRC else { return false }

            switch chunkType {
            case 0x4948_4452: // IHDR
                guard !sawHeader, offset == 8, length == 13 else { return false }
                sawHeader = true
            case 0x4944_4154: // IDAT
                guard sawHeader else { return false }
                sawImageData = true
            case 0x4945_4E44: // IEND
                return sawHeader && sawImageData && length == 0 && nextOffset == data.count
            default:
                guard sawHeader else { return false }
            }
            offset = nextOffset
        }
        return false
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: 4)
        return data[start..<end].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func pngCRC(_ data: Data, from startOffset: Int, to endOffset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: startOffset)
        let end = data.index(data.startIndex, offsetBy: endOffset)
        var crc = UInt32.max
        for byte in data[start..<end] {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = pngCRCTable[tableIndex] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }

    private static func hasPlausibleIncompleteImageHeader(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xD8])
            || data.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
            || data.starts(with: [0x47, 0x49, 0x46, 0x38])
            || data.starts(with: [0x42, 0x4D]) {
            return true
        }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data.dropFirst(8).prefix(4).elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return true
        }
        guard data.count >= 12,
              data.dropFirst(4).prefix(4).elementsEqual([0x66, 0x74, 0x79, 0x70]) else { return false }
        let brand = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        return ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"]
            .contains(brand)
    }

    private static func validateEstimatedDecodedSize(
        properties: [CFString: Any],
        width: Int64,
        height: Int64
    ) throws {
        let depth = max(8, (properties[kCGImagePropertyDepth] as? NSNumber)?.int64Value ?? 8)
        let colorModel = properties[kCGImagePropertyColorModel] as? String
        let colorChannels: Int64
        switch colorModel {
        case "Gray", "Monochrome":
            colorChannels = 1
        case "CMYK":
            colorChannels = 4
        default:
            colorChannels = 3
        }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue == true
        let channels = colorChannels + (hasAlpha ? 1 : 0)
        let (bitsPerPixel, bitsOverflow) = depth.multipliedReportingOverflow(by: channels)
        let (roundedBits, roundingOverflow) = bitsPerPixel.addingReportingOverflow(7)
        guard !bitsOverflow, !roundingOverflow else {
            throw ClipboardPNGEncodingError.dimensionsTooLarge
        }
        let bytesPerPixel = max(4, roundedBits / 8)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (decodedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: bytesPerPixel)
        guard !pixelOverflow,
              !byteOverflow,
              decodedBytes <= maximumDecodedBytes else {
            throw ClipboardPNGEncodingError.dimensionsTooLarge
        }
    }

    private static func validateDecodedSize(_ image: CGImage) throws {
        let (decodedBytes, overflow) = Int64(image.bytesPerRow)
            .multipliedReportingOverflow(by: Int64(image.height))
        guard !overflow, decodedBytes <= maximumDecodedBytes else {
            throw ClipboardPNGEncodingError.dimensionsTooLarge
        }
    }
}

struct ImportPolicy: Sendable, Equatable {
    let maximumSourceItems: Int
    let maximumEntries: Int
    let maximumSingleItemBytes: Int64
    let maximumBatchBytes: Int64
    let storageQuotaBytes: Int64
    let minimumFreeSpaceBytes: Int64
    let diskHeadroomFraction: Double

    init(
        maximumSourceItems: Int,
        maximumEntries: Int,
        maximumSingleItemBytes: Int64,
        maximumBatchBytes: Int64,
        storageQuotaBytes: Int64,
        minimumFreeSpaceBytes: Int64,
        diskHeadroomFraction: Double = 0.05
    ) {
        self.maximumSourceItems = maximumSourceItems
        self.maximumEntries = maximumEntries
        self.maximumSingleItemBytes = maximumSingleItemBytes
        self.maximumBatchBytes = maximumBatchBytes
        self.storageQuotaBytes = storageQuotaBytes
        self.minimumFreeSpaceBytes = minimumFreeSpaceBytes
        self.diskHeadroomFraction = diskHeadroomFraction
    }

    static let `default` = ImportPolicy(
        maximumSourceItems: 500,
        maximumEntries: 20_000,
        maximumSingleItemBytes: 10 * 1_024 * 1_024 * 1_024,
        maximumBatchBytes: 20 * 1_024 * 1_024 * 1_024,
        storageQuotaBytes: 50 * 1_024 * 1_024 * 1_024,
        minimumFreeSpaceBytes: 1 * 1_024 * 1_024 * 1_024
    )
}

struct FileImportBatch: Sendable {
    let items: [StashItem]
    let failures: [FileImportFailure]
    let wasCancelled: Bool
    let retryURLs: [URL]
    let cleanupFailures: [FileCleanupFailure]
    let manifestID: UUID?

    init(
        items: [StashItem],
        failures: [FileImportFailure],
        wasCancelled: Bool = false,
        retryURLs: [URL]? = nil,
        cleanupFailures: [FileCleanupFailure] = [],
        manifestID: UUID? = nil
    ) {
        self.items = items
        self.failures = failures
        self.wasCancelled = wasCancelled
        self.retryURLs = retryURLs ?? failures.map(\.sourceURL)
        self.cleanupFailures = cleanupFailures
        self.manifestID = manifestID
    }

    var needsRecovery: Bool { !cleanupFailures.isEmpty }
}

struct ManagedFileRecoveryResult: Sendable {
    let items: [StashItem]
    let cleanupFailures: [FileCleanupFailure]
    let manifestIDsNeedingRecovery: [UUID]
    let manifestIDsToAcknowledge: [UUID]
    let deletedItemPaths: Set<String>
    let resolvedJobIDs: Set<UUID>
}

private struct ImportRecoveryManifest: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceURLs: [URL]
    var currentPartialPath: String?
    var currentFinalPath: String?
    var committedItems: [StashItem]
    var cleanupFailures: [FileCleanupFailure]
    var requiresCleanup: Bool?
}

enum ImportManifestOperationKind: Sendable, Equatable {
    case create
    case prepare
    case commit
    case finalize
}

struct ImportManifestOperation: Sendable, Equatable {
    let kind: ImportManifestOperationKind
    let manifestID: UUID
}

private struct ManagedFileIdentity: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

private enum DeletionSourceState: Equatable {
    case absent
    case matching
    case replaced
}

private struct DeletionRecoveryManifest: Codable, Sendable {
    let id: UUID
    let originalPath: String
    let trashPath: String
    let replacementItem: StashItem?
    let commitOnAcknowledgement: Bool?
    let sourceIdentity: ManagedFileIdentity?
    let sourceWasPresent: Bool?

    init(
        id: UUID,
        originalPath: String,
        trashPath: String,
        replacementItem: StashItem? = nil,
        commitOnAcknowledgement: Bool = false,
        sourceIdentity: ManagedFileIdentity? = nil,
        sourceWasPresent: Bool? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.replacementItem = replacementItem
        self.commitOnAcknowledgement = commitOnAcknowledgement
        self.sourceIdentity = sourceIdentity
        self.sourceWasPresent = sourceWasPresent
    }
}

struct ManagedClipboardImageReplacement: Sendable {
    let manifestID: UUID
    let item: StashItem
}

struct FileImportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preflighting
        case importing
    }

    let phase: Phase
    let completedBytes: Int64
    let totalBytes: Int64
    let completedItems: Int
    let totalItems: Int
    let currentItemName: String?
}

final class ImportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct ClipboardImagePayload: @unchecked Sendable {
    let data: Data
    let pasteboardType: NSPasteboard.PasteboardType
}

final class QuickStashFileManager: @unchecked Sendable {
    static let shared = QuickStashFileManager()

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.quickstash.file-io", qos: .utility)
    private let appRoot: URL
    let storageDirectory: URL
    let imagesDirectory: URL
    private let importingDirectory: URL
    private let manifestsDirectory: URL
    private let deletionManifestsDirectory: URL
    private let trashDirectory: URL
    private let importPolicy: ImportPolicy
    private let availableCapacityProvider: @Sendable (URL) throws -> Int64
    private let cleanupFaultInjector: (@Sendable (FileCleanupOperation) throws -> Void)?
    private let manifestFaultInjector: (@Sendable (ImportManifestOperation) throws -> Void)?

    init(
        baseDirectory: URL? = nil,
        importPolicy: ImportPolicy = .default,
        availableCapacityProvider: (@Sendable (URL) throws -> Int64)? = nil,
        cleanupFaultInjector: (@Sendable (FileCleanupOperation) throws -> Void)? = nil,
        manifestFaultInjector: (@Sendable (ImportManifestOperation) throws -> Void)? = nil
    ) {
        let defaultAppSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appSupport = baseDirectory ?? defaultAppSupport
        appRoot = appSupport.appendingPathComponent("QuickStash", isDirectory: true)
        storageDirectory = appRoot.appendingPathComponent("Files", isDirectory: true)
        imagesDirectory = appRoot.appendingPathComponent("Images", isDirectory: true)
        importingDirectory = appRoot.appendingPathComponent("Importing", isDirectory: true)
        manifestsDirectory = appRoot.appendingPathComponent("ImportManifests", isDirectory: true)
        deletionManifestsDirectory = appRoot.appendingPathComponent("DeletionManifests", isDirectory: true)
        trashDirectory = appRoot.appendingPathComponent("Trash", isDirectory: true)
        self.importPolicy = importPolicy
        self.cleanupFaultInjector = cleanupFaultInjector
        self.manifestFaultInjector = manifestFaultInjector
        if let availableCapacityProvider {
            self.availableCapacityProvider = availableCapacityProvider
        } else {
            self.availableCapacityProvider = { url in
                try QuickStashFileManager.availableCapacity(at: url)
            }
        }
    }

    func importFiles(
        _ sourceURLs: [URL],
        cancellationToken: ImportCancellationToken = ImportCancellationToken(),
        progress: (@Sendable (FileImportProgress) -> Void)? = nil
    ) async -> FileImportBatch {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                let progressEmitter = FileImportProgressEmitter(progress)
                let batch = performImport(
                    sourceURLs,
                    cancellationToken: cancellationToken,
                    progress: { progressEmitter.emit($0) }
                )
                progressEmitter.finish()
                continuation.resume(returning: batch)
            }
        }
    }

    private func performImport(
        _ sourceURLs: [URL],
        cancellationToken: ImportCancellationToken,
        progress: (@Sendable (FileImportProgress) -> Void)?
    ) -> FileImportBatch {
        guard !sourceURLs.isEmpty else {
            return FileImportBatch(items: [], failures: [])
        }

        progress?(FileImportProgress(
            phase: .preflighting,
            completedBytes: 0,
            totalBytes: 0,
            completedItems: 0,
            totalItems: sourceURLs.count,
            currentItemName: nil
        ))

        do {
            try ensureDirectories()
            try throwIfCancelled(cancellationToken)
        } catch FileImportOperationError.cancelled {
            return cancelledBatch(for: sourceURLs)
        } catch {
            let failures = sourceURLs.map {
                failure(for: error, sourceURL: $0, fallbackKind: .copyFailed)
            }
            return FileImportBatch(items: [], failures: failures)
        }

        guard sourceURLs.count <= importPolicy.maximumSourceItems else {
            let message = "单批最多存入 \(importPolicy.maximumSourceItems) 个项目"
            let failures = sourceURLs.map {
                FileImportFailure(sourceURL: $0, kind: .limitExceeded, message: message)
            }
            return FileImportBatch(items: [], failures: failures)
        }

        var plans: [SourceImportPlan] = []
        var failures: [FileImportFailure] = []
        var totalBytes: Int64 = 0
        var totalEntries = 0

        for sourceURL in sourceURLs {
            do {
                try throwIfCancelled(cancellationToken)
                let plan = try preflightSource(sourceURL, cancellationToken: cancellationToken)
                plans.append(plan)
                totalBytes = try checkedAdd(totalBytes, plan.byteCount, message: "批次大小超出可计算范围")
                totalEntries = try checkedAdd(totalEntries, plan.entryCount, message: "批次项目数量超出可计算范围")
            } catch FileImportOperationError.cancelled {
                return cancelledBatch(for: sourceURLs, retaining: failures)
            } catch {
                failures.append(failure(for: error, sourceURL: sourceURL, fallbackKind: .invalidSource))
            }
        }

        if totalEntries > importPolicy.maximumEntries {
            return failedPreflightBatch(
                plans: plans,
                existingFailures: failures,
                kind: .limitExceeded,
                message: "单批最多包含 \(importPolicy.maximumEntries) 个文件或文件夹"
            )
        }

        if totalBytes > importPolicy.maximumBatchBytes {
            return failedPreflightBatch(
                plans: plans,
                existingFailures: failures,
                kind: .limitExceeded,
                message: "单批总大小不能超过 \(formattedBytes(importPolicy.maximumBatchBytes))"
            )
        }

        do {
            let existingStorageBytes = try managedStorageByteCount(cancellationToken: cancellationToken)
            let quotaTotal = try checkedAdd(existingStorageBytes, totalBytes, message: "应用存储用量超出可计算范围")
            guard quotaTotal <= importPolicy.storageQuotaBytes else {
                return failedPreflightBatch(
                    plans: plans,
                    existingFailures: failures,
                    kind: .quotaExceeded,
                    message: "存入后将超过 QuickStash 的 \(formattedBytes(importPolicy.storageQuotaBytes)) 存储配额"
                )
            }

            let freeBytes = try availableCapacityProvider(appRoot)
            let headroomBytes = try diskHeadroom(for: totalBytes)
            let reservedBytes = try checkedAdd(
                importPolicy.minimumFreeSpaceBytes,
                headroomBytes,
                message: "磁盘预留空间超出可计算范围"
            )
            let requiredBytes = try checkedAdd(totalBytes, reservedBytes, message: "所需磁盘空间超出可计算范围")
            guard freeBytes >= requiredBytes else {
                return failedPreflightBatch(
                    plans: plans,
                    existingFailures: failures,
                    kind: .insufficientDiskSpace,
                    message: "磁盘空间不足，至少需要 \(formattedBytes(requiredBytes)) 可用空间"
                )
            }

            let manifestID = UUID()
            try writeManifest(ImportRecoveryManifest(
                id: manifestID,
                createdAt: Date(),
                sourceURLs: sourceURLs,
                currentPartialPath: nil,
                currentFinalPath: nil,
                committedItems: [],
                cleanupFailures: [],
                requiresCleanup: false
            ), operation: .create)
            let batch = copyPreflightedSources(
                plans,
                originalURLs: sourceURLs,
                preflightFailures: failures,
                preflightBytes: totalBytes,
                existingStorageBytes: existingStorageBytes,
                initiallyAvailableBytes: freeBytes,
                reservedDiskBytes: reservedBytes,
                manifestID: manifestID,
                cancellationToken: cancellationToken,
                progress: progress
            )
            var durableCleanupFailures = batch.cleanupFailures
            if batch.items.isEmpty,
               durableCleanupFailures.isEmpty,
               manifestHasExistingFileState(manifestID) {
                durableCleanupFailures = [FileCleanupFailure(
                    path: manifestURL(for: manifestID).path,
                    message: "导入状态未完成，需要启动恢复"
                )]
                try? markCleanupIntent(for: manifestID)
            }
            if batch.items.isEmpty, durableCleanupFailures.isEmpty {
                removeManifest(manifestID)
                return FileImportBatch(
                    items: batch.items,
                    failures: batch.failures,
                    wasCancelled: batch.wasCancelled,
                    retryURLs: batch.retryURLs,
                    cleanupFailures: durableCleanupFailures
                )
            }
            updateManifest(manifestID) { manifest in
                manifest.cleanupFailures = durableCleanupFailures
                manifest.requiresCleanup = batch.items.isEmpty && !durableCleanupFailures.isEmpty
            }
            if batch.items.isEmpty, !durableCleanupFailures.isEmpty {
                try? markCleanupIntent(for: manifestID)
            }
            return FileImportBatch(
                items: batch.items,
                failures: batch.failures,
                wasCancelled: batch.wasCancelled,
                retryURLs: batch.retryURLs,
                cleanupFailures: durableCleanupFailures,
                manifestID: manifestID
            )
        } catch FileImportOperationError.cancelled {
            return cancelledBatch(for: sourceURLs)
        } catch {
            let capacityFailures = plans.map {
                failure(for: error, sourceURL: $0.sourceURL, fallbackKind: .insufficientDiskSpace)
            }
            return FileImportBatch(items: [], failures: failures + capacityFailures)
        }
    }

    private func copyPreflightedSources(
        _ plans: [SourceImportPlan],
        originalURLs: [URL],
        preflightFailures: [FileImportFailure],
        preflightBytes: Int64,
        existingStorageBytes: Int64,
        initiallyAvailableBytes: Int64,
        reservedDiskBytes: Int64,
        manifestID: UUID,
        cancellationToken: ImportCancellationToken,
        progress: (@Sendable (FileImportProgress) -> Void)?
    ) -> FileImportBatch {
        var items: [StashItem] = []
        var failures = preflightFailures
        var completedBytes: Int64 = 0
        var completedEntries = 0
        var processedItems = preflightFailures.count
        var cleanupFailures: [FileCleanupFailure] = []

        progress?(FileImportProgress(
            phase: .importing,
            completedBytes: completedBytes,
            totalBytes: preflightBytes,
            completedItems: processedItems,
            totalItems: originalURLs.count,
            currentItemName: plans.first?.sourceURL.lastPathComponent
        ))

        for plan in plans {
            if cancellationToken.isCancelled {
                cleanupFailures += rollbackImportedItems(items)
                return cancelledBatch(
                    for: originalURLs,
                    retaining: failures,
                    cleanupFailures: cleanupFailures,
                    manifestID: manifestID
                )
            }

            do {
                let result = try importFile(
                    from: plan,
                    completedBatchBytes: completedBytes,
                    completedBatchEntries: completedEntries,
                    existingStorageBytes: existingStorageBytes,
                    initiallyAvailableBytes: initiallyAvailableBytes,
                    reservedDiskBytes: reservedDiskBytes,
                    completedItems: processedItems,
                    totalItems: originalURLs.count,
                    totalBytes: preflightBytes,
                    manifestID: manifestID,
                    cancellationToken: cancellationToken,
                    progress: progress
                )
                items.append(result.item)
                completedBytes = try checkedAdd(completedBytes, result.copiedBytes, message: "复制大小超出可计算范围")
                completedEntries = try checkedAdd(completedEntries, result.copiedEntries, message: "复制项目数量超出可计算范围")
                processedItems += 1
                progress?(FileImportProgress(
                    phase: .importing,
                    completedBytes: completedBytes,
                    totalBytes: preflightBytes,
                    completedItems: processedItems,
                    totalItems: originalURLs.count,
                    currentItemName: plan.sourceURL.lastPathComponent
                ))
            } catch {
                if let operationError = error as? FileImportOperationError {
                    cleanupFailures += operationError.cleanupFailures
                    if operationError.isCancellation {
                        cleanupFailures += rollbackImportedItems(items)
                        return cancelledBatch(
                            for: originalURLs,
                            retaining: failures,
                            cleanupFailures: cleanupFailures,
                            manifestID: manifestID
                        )
                    }
                }
                processedItems += 1
                failures.append(failure(for: error, sourceURL: plan.sourceURL, fallbackKind: .copyFailed))
                progress?(FileImportProgress(
                    phase: .importing,
                    completedBytes: completedBytes,
                    totalBytes: preflightBytes,
                    completedItems: processedItems,
                    totalItems: originalURLs.count,
                    currentItemName: plan.sourceURL.lastPathComponent
                ))
            }
        }

        return FileImportBatch(
            items: items,
            failures: failures,
            cleanupFailures: cleanupFailures,
            manifestID: manifestID
        )
    }

    private func preflightSource(
        _ sourceURL: URL,
        cancellationToken: ImportCancellationToken
    ) throws -> SourceImportPlan {
        guard sourceURL.isFileURL else {
            throw FileImportOperationError.invalidSource("只支持本地文件")
        }

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let fileName = sourceURL.lastPathComponent
        guard !fileName.isEmpty else {
            throw FileImportOperationError.invalidSource("文件名无效")
        }

        let measurement = try measureItem(at: sourceURL, cancellationToken: cancellationToken)
        return SourceImportPlan(
            sourceURL: sourceURL,
            byteCount: measurement.byteCount,
            entryCount: measurement.entryCount,
            isDirectory: measurement.isDirectory
        )
    }

    private func measureItem(
        at itemURL: URL,
        expectedDirectory: Bool? = nil,
        cancellationToken: ImportCancellationToken
    ) throws -> ItemMeasurement {
        try throwIfCancelled(cancellationToken)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        let sourceValues = try itemURL.resourceValues(forKeys: keys)
        guard sourceValues.isSymbolicLink != true,
              sourceValues.isRegularFile == true || sourceValues.isDirectory == true else {
            throw FileImportOperationError.invalidSource("不支持符号链接或特殊文件")
        }
        let isDirectory = sourceValues.isDirectory == true
        if let expectedDirectory, expectedDirectory != isDirectory {
            throw FileImportOperationError.invalidSource(
                "项目类型在检查期间发生变化：\(itemURL.lastPathComponent)"
            )
        }

        var byteCount = try measuredBytes(
            at: itemURL,
            values: sourceValues,
            isDirectory: isDirectory
        )
        var entryCount = 1
        guard byteCount <= importPolicy.maximumSingleItemBytes else {
            throw FileImportOperationError.limitExceeded(
                "单个项目不能超过 \(formattedBytes(importPolicy.maximumSingleItemBytes))"
            )
        }

        if sourceValues.isDirectory == true {
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: itemURL,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw FileImportOperationError.invalidSource("无法读取文件夹内容")
            }

            while let entryURL = enumerator.nextObject() as? URL {
                try throwIfCancelled(cancellationToken)
                let values = try entryURL.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw FileImportOperationError.invalidSource("文件夹内含符号链接：\(entryURL.lastPathComponent)")
                }
                guard values.isRegularFile == true || values.isDirectory == true else {
                    throw FileImportOperationError.invalidSource("文件夹内含不支持的特殊文件：\(entryURL.lastPathComponent)")
                }

                entryCount = try checkedAdd(entryCount, 1, message: "项目数量超出可计算范围")
                guard entryCount <= importPolicy.maximumEntries else {
                    throw FileImportOperationError.limitExceeded(
                        "单批最多包含 \(importPolicy.maximumEntries) 个文件或文件夹"
                    )
                }

                let entryBytes = try measuredBytes(
                    at: entryURL,
                    values: values,
                    isDirectory: values.isDirectory == true
                )
                byteCount = try checkedAdd(
                    byteCount,
                    entryBytes,
                    message: "项目大小超出可计算范围"
                )
                guard byteCount <= importPolicy.maximumSingleItemBytes else {
                    throw FileImportOperationError.limitExceeded(
                        "单个项目不能超过 \(formattedBytes(importPolicy.maximumSingleItemBytes))"
                    )
                }
            }

            if let enumerationError {
                throw FileImportOperationError.invalidSource("读取文件夹失败：\(enumerationError.localizedDescription)")
            }
        }

        return ItemMeasurement(
            byteCount: byteCount,
            entryCount: entryCount,
            isDirectory: isDirectory
        )
    }

    private func importFile(
        from plan: SourceImportPlan,
        completedBatchBytes: Int64,
        completedBatchEntries: Int,
        existingStorageBytes: Int64,
        initiallyAvailableBytes: Int64,
        reservedDiskBytes: Int64,
        completedItems: Int,
        totalItems: Int,
        totalBytes: Int64,
        manifestID: UUID,
        cancellationToken: ImportCancellationToken,
        progress: (@Sendable (FileImportProgress) -> Void)?
    ) throws -> ImportedFileResult {
        let sourceURL = plan.sourceURL
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        try throwIfCancelled(cancellationToken)

        let finalURL = uniqueDestination(for: sourceURL, in: storageDirectory)
        let temporaryURL = importingDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("partial")

        let context = CopyOperationContext(
            token: cancellationToken,
            policy: importPolicy,
            completedBatchBytes: completedBatchBytes,
            completedBatchEntries: completedBatchEntries,
            existingStorageBytes: existingStorageBytes,
            maximumWritableBytes: max(0, initiallyAvailableBytes - reservedDiskBytes),
            reservedDiskBytes: reservedDiskBytes,
            capacityURL: appRoot,
            availableCapacityProvider: availableCapacityProvider,
            completedItems: completedItems,
            totalItems: totalItems,
            totalBytes: totalBytes,
            progress: progress
        )

        let measurement: ItemMeasurement
        do {
            try updateManifestThrowing(manifestID, operation: .prepare) { manifest in
                manifest.currentPartialPath = temporaryURL.path
                manifest.currentFinalPath = finalURL.path
            }
            try copyItemWithProgress(
                from: sourceURL,
                to: temporaryURL,
                expectedDirectory: plan.isDirectory,
                context: context
            )
            try throwIfCancelled(cancellationToken)
            measurement = try measureItem(
                at: temporaryURL,
                expectedDirectory: plan.isDirectory,
                cancellationToken: cancellationToken
            )
            try validatePostflight(
                measurement,
                completedBatchBytes: completedBatchBytes,
                completedBatchEntries: completedBatchEntries,
                existingStorageBytes: existingStorageBytes,
                maximumWritableBytes: max(0, initiallyAvailableBytes - reservedDiskBytes),
                reservedDiskBytes: reservedDiskBytes
            )
            progress?(FileImportProgress(
                phase: .importing,
                completedBytes: try checkedAdd(completedBatchBytes, measurement.byteCount, message: "复制大小超出可计算范围"),
                totalBytes: totalBytes,
                completedItems: completedItems,
                totalItems: totalItems,
                currentItemName: sourceURL.lastPathComponent
            ))
            try throwIfCancelled(cancellationToken)
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            let cleanupFailures = cleanupStagingItem(at: temporaryURL)
            throw wrapping(error, cleanupFailures: cleanupFailures)
        }

        // The job commits after this final cancellation check. A later cancel loses the race to completion.
        if cancellationToken.isCancelled {
            let cleanupFailures = cleanupCommittedItem(at: finalURL)
            throw wrapping(FileImportOperationError.cancelled, cleanupFailures: cleanupFailures)
        }

        let values = try? finalURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let isDirectory = values?.isDirectory == true
        let size = Int64(values?.fileSize ?? 0)
        let detail = isDirectory
            ? "文件夹"
            : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

        let item = StashItem(
            type: isDirectory ? .file : ItemType.fromFileExtension(sourceURL.pathExtension),
            content: finalURL.path,
            preview: "\(sourceURL.lastPathComponent) (\(detail))"
        )
        do {
            try updateManifestThrowing(manifestID, operation: .commit) { manifest in
                manifest.currentPartialPath = nil
                manifest.currentFinalPath = nil
                if !manifest.committedItems.contains(where: { $0.content == item.content }) {
                    manifest.committedItems.append(item)
                }
            }
        } catch {
            try? markCleanupIntent(for: manifestID)
            let cleanupFailures = cleanupCommittedItem(at: finalURL)
            if cleanupFailures.isEmpty {
                removeManifest(manifestID)
                throw FileImportOperationError.copyFailed(
                    "文件已复制，但记录恢复状态失败，已安全回滚：\(error.localizedDescription)"
                )
            }
            updateManifest(manifestID, operation: .finalize) { manifest in
                manifest.requiresCleanup = true
                manifest.cleanupFailures.append(contentsOf: cleanupFailures)
            }
            throw wrapping(error, cleanupFailures: cleanupFailures)
        }
        return ImportedFileResult(
            item: item,
            copiedBytes: measurement.byteCount,
            copiedEntries: measurement.entryCount
        )
    }

    private func validatePostflight(
        _ measurement: ItemMeasurement,
        completedBatchBytes: Int64,
        completedBatchEntries: Int,
        existingStorageBytes: Int64,
        maximumWritableBytes: Int64,
        reservedDiskBytes: Int64
    ) throws {
        let batchBytes = try checkedAdd(
            completedBatchBytes,
            measurement.byteCount,
            message: "复制后的批次大小超出可计算范围"
        )
        guard batchBytes <= importPolicy.maximumBatchBytes else {
            throw FileImportOperationError.limitExceeded("复制后的实际用量超过批次大小限制")
        }
        guard batchBytes <= maximumWritableBytes else {
            throw FileImportOperationError.insufficientDiskSpace("复制后的实际用量超过可用磁盘空间")
        }

        let batchEntries = try checkedAdd(
            completedBatchEntries,
            measurement.entryCount,
            message: "复制后的项目数量超出可计算范围"
        )
        guard batchEntries <= importPolicy.maximumEntries else {
            throw FileImportOperationError.limitExceeded("复制后的项目数量超过批次限制")
        }

        let quotaBytes = try checkedAdd(
            existingStorageBytes,
            batchBytes,
            message: "复制后的应用存储用量超出可计算范围"
        )
        guard quotaBytes <= importPolicy.storageQuotaBytes else {
            throw FileImportOperationError.quotaExceeded("复制后的实际用量超过应用存储配额")
        }

        let freeBytes = try availableCapacityProvider(appRoot)
        guard freeBytes >= reservedDiskBytes else {
            throw FileImportOperationError.insufficientDiskSpace("复制后磁盘预留空间不足")
        }
    }

    private func copyItemWithProgress(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedDirectory: Bool,
        context: CopyOperationContext
    ) throws {
        var sourceStatus = stat()
        let statusResult = sourceURL.path.withCString { lstat($0, &sourceStatus) }
        guard statusResult == 0 else {
            throw FileImportOperationError.posix(code: errno, path: sourceURL.path)
        }

        let fileType = sourceStatus.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFREG) {
            guard !expectedDirectory else {
                throw FileImportOperationError.invalidSource(
                    "源项目类型在预检后发生变化：\(sourceURL.lastPathComponent)"
                )
            }
            try copyRegularFile(from: sourceURL, to: destinationURL, context: context)
        } else if fileType == mode_t(S_IFDIR) {
            guard expectedDirectory else {
                throw FileImportOperationError.invalidSource(
                    "源项目类型在预检后发生变化：\(sourceURL.lastPathComponent)"
                )
            }
            try copyDirectory(from: sourceURL, to: destinationURL, context: context)
        } else if fileType == mode_t(S_IFLNK) {
            throw FileImportOperationError.invalidSource("检测到符号链接：\(sourceURL.lastPathComponent)")
        } else {
            throw FileImportOperationError.invalidSource("不支持特殊文件：\(sourceURL.lastPathComponent)")
        }
        context.emitProgress(currentPath: sourceURL.path, force: true)
    }

    private func copyRegularFile(
        from sourceURL: URL,
        to destinationURL: URL,
        context: CopyOperationContext
    ) throws {
        let sourceFlags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let sourceFD = sourceURL.path.withCString { open($0, sourceFlags) }
        guard sourceFD >= 0 else {
            throw FileImportOperationError.posix(code: errno, path: sourceURL.path)
        }
        defer { close(sourceFD) }

        var sourceStatus = stat()
        guard fstat(sourceFD, &sourceStatus) == 0 else {
            throw FileImportOperationError.posix(code: errno, path: sourceURL.path)
        }
        guard sourceStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FileImportOperationError.invalidSource("源文件类型在预检后发生变化：\(sourceURL.lastPathComponent)")
        }
        try context.beginEntry(path: sourceURL.path)

        let destinationFlags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let destinationMode = mode_t(S_IRUSR | S_IWUSR)
        let destinationFD = destinationURL.path.withCString {
            open($0, destinationFlags, destinationMode)
        }
        guard destinationFD >= 0 else {
            throw FileImportOperationError.posix(code: errno, path: destinationURL.path)
        }
        defer { close(destinationFD) }

        let state = try makeCopyState(context: context)
        defer { copyfile_state_free(state) }
        let result = fcopyfile(sourceFD, destinationFD, state, copyfile_flags_t(COPYFILE_ALL))
        let copyErrno = errno
        if let abortError = context.abortError {
            throw abortError
        }
        guard result == 0 else {
            throw FileImportOperationError.posix(code: copyErrno, path: sourceURL.path)
        }
    }

    private func copyDirectory(
        from sourceURL: URL,
        to destinationURL: URL,
        context: CopyOperationContext
    ) throws {
        let state = try makeCopyState(context: context)
        defer { copyfile_state_free(state) }
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_RECURSIVE
        )
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, state, flags)
            }
        }
        let copyErrno = errno
        if let abortError = context.abortError {
            throw abortError
        }
        guard result == 0 else {
            throw FileImportOperationError.posix(code: copyErrno, path: sourceURL.path)
        }
    }

    private func makeCopyState(context: CopyOperationContext) throws -> copyfile_state_t {
        guard let state = copyfile_state_alloc() else {
            throw FileImportOperationError.copyFailed("无法创建复制状态")
        }

        let callbackPointer = unsafeBitCast(Self.copyCallback, to: UnsafeRawPointer.self)
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer) == 0 else {
            let code = errno
            copyfile_state_free(state)
            throw FileImportOperationError.posix(code: code, path: "copyfile callback")
        }

        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPointer) == 0 else {
            let code = errno
            copyfile_state_free(state)
            throw FileImportOperationError.posix(code: code, path: "copyfile context")
        }

        var enabled: UInt32 = 1
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT), &enabled) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_FORBID_DST_EXISTING_SYMLINKS), &enabled) == 0 else {
            let code = errno
            copyfile_state_free(state)
            throw FileImportOperationError.posix(code: code, path: "copyfile policy")
        }
        return state
    }

    private static let copyCallback: copyfile_callback_t = { what, stage, state, source, _, rawContext in
        let callbackErrno = errno
        guard let rawContext else { return COPYFILE_QUIT }
        let context = Unmanaged<CopyOperationContext>
            .fromOpaque(rawContext)
            .takeUnretainedValue()
        let sourcePath = source.map { String(cString: $0) } ?? ""

        if stage == COPYFILE_ERR {
            context.abort(with: .posix(code: callbackErrno, path: sourcePath))
            return COPYFILE_QUIT
        }

        if context.token.isCancelled {
            context.abort(with: .cancelled)
            return COPYFILE_QUIT
        }

        do {
            try context.checkCapacityIfNeeded()
        } catch let error as FileImportOperationError {
            context.abort(with: error)
            return COPYFILE_QUIT
        } catch {
            context.abort(with: .copyFailed(error.localizedDescription))
            return COPYFILE_QUIT
        }

        if stage == COPYFILE_START,
           what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR {
            var entry: UnsafePointer<FTSENT>?
            guard copyfile_state_get(
                state,
                UInt32(COPYFILE_STATE_RECURSIVE_SRC_FTSENT),
                &entry
            ) == 0, let entry else {
                context.abort(with: .copyFailed("无法验证递归复制项目：\(sourcePath)"))
                return COPYFILE_QUIT
            }

            let info = entry.pointee.fts_info
            let expectedInfo = what == COPYFILE_RECURSE_DIR ? UInt16(FTS_D) : UInt16(FTS_F)
            guard info == expectedInfo else {
                let name = URL(fileURLWithPath: sourcePath).lastPathComponent
                context.abort(with: .invalidSource("文件夹内含符号链接或特殊文件：\(name)"))
                return COPYFILE_QUIT
            }

            do {
                try context.beginEntry(path: sourcePath)
            } catch let error as FileImportOperationError {
                context.abort(with: error)
                return COPYFILE_QUIT
            } catch {
                context.abort(with: .copyFailed(error.localizedDescription))
                return COPYFILE_QUIT
            }
        }

        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
            guard let state else {
                context.abort(with: .copyFailed("复制进度状态不可用"))
                return COPYFILE_QUIT
            }
            do {
                try context.updateCopiedBytes(state: state, path: sourcePath)
            } catch let error as FileImportOperationError {
                context.abort(with: error)
                return COPYFILE_QUIT
            } catch {
                context.abort(with: .copyFailed(error.localizedDescription))
                return COPYFILE_QUIT
            }
        }

        return COPYFILE_CONTINUE
    }

    private func failedPreflightBatch(
        plans: [SourceImportPlan],
        existingFailures: [FileImportFailure],
        kind: FileImportFailureKind,
        message: String
    ) -> FileImportBatch {
        let failures = existingFailures + plans.map {
            FileImportFailure(sourceURL: $0.sourceURL, kind: kind, message: message)
        }
        return FileImportBatch(items: [], failures: failures)
    }

    private func cancelledBatch(
        for sourceURLs: [URL],
        retaining failures: [FileImportFailure] = [],
        cleanupFailures: [FileCleanupFailure] = [],
        manifestID: UUID? = nil
    ) -> FileImportBatch {
        FileImportBatch(
            items: [],
            failures: failures,
            wasCancelled: true,
            retryURLs: sourceURLs,
            cleanupFailures: cleanupFailures,
            manifestID: manifestID
        )
    }

    private func rollbackImportedItems(_ items: [StashItem]) -> [FileCleanupFailure] {
        var failures: [FileCleanupFailure] = []
        for item in items where isManagedFile(at: item.content) {
            failures += cleanupCommittedItem(at: URL(fileURLWithPath: item.content))
        }
        return failures
    }

    private func cleanupStagingItem(at url: URL) -> [FileCleanupFailure] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            try cleanupFaultInjector?(FileCleanupOperation(
                kind: .stagingRemoval,
                sourceURL: url,
                destinationURL: nil
            ))
            try fileManager.removeItem(at: url)
            return []
        } catch {
            return [FileCleanupFailure(path: url.path, message: error.localizedDescription)]
        }
    }

    private func cleanupCommittedItem(at url: URL) -> [FileCleanupFailure] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            try cleanupFaultInjector?(FileCleanupOperation(
                kind: .committedRemoval,
                sourceURL: url,
                destinationURL: nil
            ))
            try fileManager.removeItem(at: url)
            return []
        } catch let removalError {
            let quarantineURL = trashDirectory.appendingPathComponent(
                "cancelled-\(UUID().uuidString)-\(url.lastPathComponent)"
            )
            do {
                try cleanupFaultInjector?(FileCleanupOperation(
                    kind: .committedQuarantine,
                    sourceURL: url,
                    destinationURL: quarantineURL
                ))
                try fileManager.moveItem(at: url, to: quarantineURL)
                return []
            } catch let quarantineError {
                return [FileCleanupFailure(
                    path: url.path,
                    message: "删除失败：\(removalError.localizedDescription)；隔离失败：\(quarantineError.localizedDescription)"
                )]
            }
        }
    }

    private func wrapping(
        _ error: Error,
        cleanupFailures: [FileCleanupFailure]
    ) -> FileImportOperationError {
        guard !cleanupFailures.isEmpty else {
            return error as? FileImportOperationError ?? .copyFailed(error.localizedDescription)
        }
        if let operationError = error as? FileImportOperationError,
           case .cleanupRequired(let message, let kind, let cancelled, let existing) = operationError {
            return .cleanupRequired(
                message: message,
                underlyingKind: kind,
                wasCancelled: cancelled,
                failures: existing + cleanupFailures
            )
        }
        let operationError = error as? FileImportOperationError
        return .cleanupRequired(
            message: error.localizedDescription,
            underlyingKind: operationError?.failureKind,
            wasCancelled: operationError?.isCancellation == true,
            failures: cleanupFailures
        )
    }

    private func failure(
        for error: Error,
        sourceURL: URL,
        fallbackKind: FileImportFailureKind
    ) -> FileImportFailure {
        let kind: FileImportFailureKind
        if let operationError = error as? FileImportOperationError {
            kind = operationError.failureKind ?? fallbackKind
        } else {
            kind = fallbackKind
        }
        return FileImportFailure(
            sourceURL: sourceURL,
            kind: kind,
            message: error.localizedDescription
        )
    }

    private func throwIfCancelled(_ token: ImportCancellationToken) throws {
        if token.isCancelled {
            throw FileImportOperationError.cancelled
        }
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64, message: String) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw FileImportOperationError.limitExceeded(message) }
        return result
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int, message: String) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw FileImportOperationError.limitExceeded(message) }
        return result
    }

    private func measuredBytes(
        at url: URL,
        values: URLResourceValues,
        isDirectory: Bool
    ) throws -> Int64 {
        let extendedAttributeBytes = try extendedAttributeLogicalBytes(at: url)
        let logicalBytes = Int64(max(0, values.fileSize ?? 0))
        let allocatedBytes = Int64(max(0, values.totalFileAllocatedSize ?? 0))
        if isDirectory {
            return max(extendedAttributeBytes, allocatedBytes)
        }
        let logicalTotal = try checkedAdd(
            logicalBytes,
            extendedAttributeBytes,
            message: "文件及扩展属性大小超出可计算范围"
        )
        return max(logicalTotal, allocatedBytes)
    }

    private func extendedAttributeLogicalBytes(at url: URL) throws -> Int64 {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw FileImportOperationError.copyFailed(
                    "无法读取扩展属性路径：\(url.lastPathComponent)"
                )
            }

            let maximumNameListBytes = 4 * 1_024 * 1_024
            let maximumAttempts = 4
            for _ in 0..<maximumAttempts {
                let requiredSize = listxattr(path, nil, 0, XATTR_NOFOLLOW)
                let sizeErrno = errno
                if requiredSize < 0, sizeErrno == EINTR {
                    continue
                }
                guard requiredSize >= 0 else {
                    throw FileImportOperationError.posix(code: sizeErrno, path: url.path)
                }
                guard requiredSize > 0 else { return 0 }
                guard requiredSize <= maximumNameListBytes else {
                    throw FileImportOperationError.limitExceeded(
                        "扩展属性名称列表过大：\(url.lastPathComponent)"
                    )
                }

                var names = [CChar](repeating: 0, count: requiredSize)
                let readSize = names.withUnsafeMutableBufferPointer { buffer in
                    listxattr(path, buffer.baseAddress, buffer.count, XATTR_NOFOLLOW)
                }
                let listErrno = errno
                if readSize < 0, listErrno == ERANGE || listErrno == EINTR {
                    continue
                }
                guard readSize >= 0 else {
                    throw FileImportOperationError.posix(code: listErrno, path: url.path)
                }
                guard readSize <= names.count else {
                    throw FileImportOperationError.copyFailed("扩展属性列表大小无效：\(url.lastPathComponent)")
                }
                guard let nameListBytes = Int64(exactly: readSize) else {
                    throw FileImportOperationError.limitExceeded(
                        "扩展属性名称列表大小超出可计算范围"
                    )
                }

                let measurement = try names.withUnsafeBufferPointer { buffer -> (bytes: Int64, retry: Bool) in
                    guard let baseAddress = buffer.baseAddress else { return (0, false) }
                    var total: Int64 = 0
                    total = try checkedAdd(
                        total,
                        nameListBytes,
                        message: "扩展属性名称列表大小超出可计算范围"
                    )
                    var offset = 0
                    while offset < readSize {
                        var terminator = offset
                        while terminator < readSize, baseAddress[terminator] != 0 {
                            terminator += 1
                        }
                        guard terminator < readSize, terminator > offset else {
                            throw FileImportOperationError.copyFailed(
                                "扩展属性列表格式无效：\(url.lastPathComponent)"
                            )
                        }
                        guard terminator - offset <= Int(XATTR_MAXNAMELEN) else {
                            throw FileImportOperationError.copyFailed(
                                "扩展属性名称过长：\(url.lastPathComponent)"
                            )
                        }

                        let attributeSize = getxattr(
                            path,
                            baseAddress.advanced(by: offset),
                            nil,
                            0,
                            0,
                            XATTR_NOFOLLOW
                        )
                        let attributeErrno = errno
                        if attributeSize < 0,
                           attributeErrno == ENOATTR || attributeErrno == ERANGE || attributeErrno == EINTR {
                            return (0, true)
                        }
                        guard attributeSize >= 0 else {
                            throw FileImportOperationError.posix(code: attributeErrno, path: url.path)
                        }
                        guard let exactAttributeSize = Int64(exactly: attributeSize) else {
                            throw FileImportOperationError.limitExceeded(
                                "扩展属性大小超出可计算范围"
                            )
                        }
                        total = try checkedAdd(
                            total,
                            exactAttributeSize,
                            message: "扩展属性大小超出可计算范围"
                        )
                        offset = terminator + 1
                    }
                    return (total, false)
                }
                if measurement.retry { continue }
                return measurement.bytes
            }
            throw FileImportOperationError.copyFailed(
                "扩展属性在检查期间持续变化：\(url.lastPathComponent)"
            )
        }
    }

    private func diskHeadroom(for bytes: Int64) throws -> Int64 {
        guard importPolicy.diskHeadroomFraction >= 0,
              importPolicy.diskHeadroomFraction.isFinite else {
            throw FileImportOperationError.limitExceeded("磁盘预留比例无效")
        }
        let headroom = (Double(bytes) * importPolicy.diskHeadroomFraction).rounded(.up)
        guard headroom.isFinite, headroom <= Double(Int64.max) else {
            throw FileImportOperationError.limitExceeded("磁盘预留空间超出可计算范围")
        }
        return Int64(headroom)
    }

    private func managedStorageByteCount(cancellationToken: ImportCancellationToken) throws -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]

        for directory in [storageDirectory, imagesDirectory, importingDirectory, trashDirectory] {
            try throwIfCancelled(cancellationToken)
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                try throwIfCancelled(cancellationToken)
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true,
                      values.isRegularFile == true || values.isDirectory == true else { continue }
                let itemBytes = try measuredBytes(
                    at: url,
                    values: values,
                    isDirectory: values.isDirectory == true
                )
                total = try checkedAdd(total, itemBytes, message: "应用存储用量超出可计算范围")
            }
            if let enumerationError {
                throw FileImportOperationError.copyFailed(
                    "无法统计应用存储用量：\(enumerationError.localizedDescription)"
                )
            }
        }
        return total
    }

    private static func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        throw FileImportOperationError.copyFailed("无法读取磁盘剩余空间")
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func recoverManagedFiles(
        referencedBy storedItems: [StashItem],
        importJobs: [ImportJob] = []
    ) async -> ManagedFileRecoveryResult {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: performManagedFileRecovery(
                    referencedBy: storedItems,
                    importJobs: importJobs
                ))
            }
        }
    }

    func acknowledgeRecoveryManifests(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                for id in ids {
                    removeManifest(id)
                    let deletionURL = deletionManifestURL(for: id)
                    guard fileManager.fileExists(atPath: deletionURL.path) else { continue }
                    do {
                        let data = try Data(contentsOf: deletionURL)
                        let manifest = try JSONDecoder().decode(
                            DeletionRecoveryManifest.self,
                            from: data
                        )
                        if manifest.commitOnAcknowledgement == true {
                            try commitDeletionManifest(manifest)
                        }
                        try fileManager.removeItem(at: deletionURL)
                    } catch {
                        // Keep the intent so the next recovery can retry cleanup.
                    }
                }
                continuation.resume()
            }
        }
    }

    private func performManagedFileRecovery(
        referencedBy storedItems: [StashItem],
        importJobs: [ImportJob]
    ) -> ManagedFileRecoveryResult {
        do {
            try ensureDirectories()
        } catch {
            return ManagedFileRecoveryResult(
                items: storedItems,
                cleanupFailures: [FileCleanupFailure(path: appRoot.path, message: error.localizedDescription)],
                manifestIDsNeedingRecovery: [],
                manifestIDsToAcknowledge: [],
                deletedItemPaths: [],
                resolvedJobIDs: []
            )
        }

        let deletionLoad = loadDeletionManifests()
        let deletionManifests = deletionLoad.manifests
        var pathsRemovedFromMetadata = Set<String>()
        var excludedOrphanPaths = pathsRemovedFromMetadata
        var cleanupFailures = deletionLoad.failures
        var needsRecovery: [UUID] = []
        var acknowledge: [UUID] = []
        var resolvedJobIDs = Set<UUID>()
        var storedRecoveryCandidates: [StashItem] = []
        var deletionReplacementCandidates: [StashItem] = []

        for manifest in deletionManifests {
            let sourceURL = URL(fileURLWithPath: manifest.originalPath)
            let preferredTrashURL = URL(fileURLWithPath: manifest.trashPath)
            let sourcePath = standardizedPath(sourceURL.path)
            guard isManagedFile(sourceURL), isDescendant(preferredTrashURL, of: trashDirectory) else {
                cleanupFailures.append(FileCleanupFailure(
                    path: deletionManifestURL(for: manifest.id).path,
                    message: "删除恢复清单包含非受管路径，已拒绝执行"
                ))
                needsRecovery.append(manifest.id)
                continue
            }
            let sourceState: DeletionSourceState
            do {
                sourceState = try deletionSourceState(for: manifest)
            } catch {
                cleanupFailures.append(FileCleanupFailure(
                    path: sourceURL.path,
                    message: error.localizedDescription
                ))
                needsRecovery.append(manifest.id)
                continue
            }
            if sourceState == .replaced {
                acknowledge.append(manifest.id)
                resolvedJobIDs.formUnion(importJobs.compactMap { job in
                    job.needsRecovery && (job.recoveryManifestID == manifest.id || job.id == manifest.id)
                        ? job.id
                        : nil
                })
                continue
            }
            var replacementCandidate: StashItem?
            if let replacement = manifest.replacementItem {
                let replacementURL = URL(fileURLWithPath: replacement.content)
                let replacementPath = standardizedPath(replacement.content)
                excludedOrphanPaths.insert(replacementPath)
                guard replacement.type == .image,
                      replacement.managedOrigin == .clipboard,
                      isDescendant(replacementURL, of: imagesDirectory),
                      replacementPath != standardizedPath(sourceURL.path),
                      let fingerprint = clipboardImageFingerprint(at: replacementPath),
                      replacement.contentFingerprint.map({ $0 == fingerprint }) ?? true else {
                    cleanupFailures.append(FileCleanupFailure(
                        path: replacement.content,
                        message: "图片替换恢复清单缺少有效的新文件，已保留原记录"
                    ))
                    needsRecovery.append(manifest.id)
                    continue
                }
                replacementCandidate = StashItem(
                    id: replacement.id,
                    type: .image,
                    content: replacementPath,
                    preview: replacement.preview,
                    createdAt: replacement.createdAt,
                    isPinned: replacement.isPinned,
                    availability: .available,
                    managedOrigin: .clipboard,
                    contentFingerprint: fingerprint
                )
            }
            if sourceState == .matching {
                do {
                    let committedState = try commitDeletionManifest(manifest)
                    if committedState == .replaced {
                        acknowledge.append(manifest.id)
                        resolvedJobIDs.formUnion(importJobs.compactMap { job in
                            job.needsRecovery && (job.recoveryManifestID == manifest.id || job.id == manifest.id)
                                ? job.id
                                : nil
                        })
                        continue
                    }
                } catch {
                    if manifest.replacementItem == nil {
                        pathsRemovedFromMetadata.insert(sourcePath)
                        excludedOrphanPaths.insert(sourcePath)
                    }
                    cleanupFailures.append(FileCleanupFailure(
                        path: sourceURL.path,
                        message: error.localizedDescription
                    ))
                    needsRecovery.append(manifest.id)
                    continue
                }
            }
            pathsRemovedFromMetadata.insert(sourcePath)
            excludedOrphanPaths.insert(sourcePath)
            if let replacementCandidate {
                deletionReplacementCandidates.append(replacementCandidate)
            }
            acknowledge.append(manifest.id)
            resolvedJobIDs.formUnion(importJobs.compactMap { job in
                job.needsRecovery && (job.recoveryManifestID == manifest.id || job.id == manifest.id)
                    ? job.id
                    : nil
            })
        }

        for manifest in loadImportManifests() {
            let manifestPaths = Set(
                [manifest.currentPartialPath, manifest.currentFinalPath].compactMap { $0 }
                    + manifest.committedItems.map(\.content)
            )
            let standardizedManifestPaths = Set(manifestPaths.map(standardizedPath))
            excludedOrphanPaths.formUnion(standardizedManifestPaths)
            let cleanupIntent = manifest.requiresCleanup == true
                || fileManager.fileExists(atPath: cleanupIntentURL(for: manifest.id).path)

            if cleanupIntent {
                pathsRemovedFromMetadata.formUnion(standardizedManifestPaths)
                var manifestFailures: [FileCleanupFailure] = []
                for path in manifestPaths where fileManager.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    if standardizedPath(path).hasPrefix(standardizedPath(importingDirectory.path) + "/") {
                        manifestFailures.append(contentsOf: cleanupStagingItem(at: url))
                    } else if isManagedFile(at: path) {
                        manifestFailures.append(contentsOf: cleanupCommittedItem(at: url))
                    }
                }
                if manifestFailures.isEmpty {
                    acknowledge.append(manifest.id)
                    resolvedJobIDs.formUnion(importJobs.compactMap { job in
                        job.needsRecovery && (job.recoveryManifestID == manifest.id || job.id == manifest.id)
                            ? job.id
                            : nil
                    })
                } else {
                    needsRecovery.append(manifest.id)
                    cleanupFailures.append(contentsOf: manifestFailures)
                }
                continue
            }

            var candidates = manifest.committedItems
            if let finalPath = manifest.currentFinalPath,
               fileManager.fileExists(atPath: finalPath),
               !candidates.contains(where: { standardizedPath($0.content) == standardizedPath(finalPath) }) {
                candidates.append(recoveredItem(at: URL(fileURLWithPath: finalPath), origin: .imported))
            }

            var manifestFailures: [FileCleanupFailure] = []
            if let partialPath = manifest.currentPartialPath,
               fileManager.fileExists(atPath: partialPath) {
                manifestFailures.append(contentsOf: cleanupStagingItem(at: URL(fileURLWithPath: partialPath)))
            }

            for candidate in candidates {
                let path = standardizedPath(candidate.content)
                guard fileManager.fileExists(atPath: path) else { continue }
                var recovered = candidate
                recovered.availability = .available
                recovered.managedOrigin = .imported
                storedRecoveryCandidates.append(recovered)
            }

            if manifestFailures.isEmpty {
                acknowledge.append(manifest.id)
                resolvedJobIDs.formUnion(importJobs.compactMap { job in
                    job.needsRecovery && (job.recoveryManifestID == manifest.id || job.id == manifest.id)
                        ? job.id
                        : nil
                })
            } else {
                needsRecovery.append(manifest.id)
                cleanupFailures.append(contentsOf: manifestFailures)
            }
        }

        var reconciled = deduplicatedStoredItems(storedItems)
            .filter { item in
                guard let path = managedPathIdentity(for: item) else { return true }
                return !pathsRemovedFromMetadata.contains(path)
            }
        var knownPaths = Set(reconciled.compactMap(managedPathIdentity(for:)))
        for candidate in deletionReplacementCandidates + storedRecoveryCandidates {
            guard let path = managedPathIdentity(for: candidate) else { continue }
            if knownPaths.insert(path).inserted {
                reconciled.append(candidate)
            }
        }

        for directory in [storageDirectory, imagesDirectory] {
            let orphanOrigin: ManagedItemOrigin = directory == imagesDirectory ? .clipboard : .legacyUnknown
            let topLevel = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in topLevel {
                let path = standardizedPath(url.path)
                guard !excludedOrphanPaths.contains(path) else { continue }
                guard knownPaths.insert(path).inserted else { continue }
                reconciled.append(recoveredItem(at: url, origin: orphanOrigin))
            }
        }

        reconciled = reconciled.map { item in
            guard item.type.isFileBacked, isManagedFile(at: item.content) else { return item }
            var updated = item
            updated.availability = fileManager.fileExists(atPath: item.content) ? .available : .unavailable
            guard updated.type == .image,
                  updated.managedOrigin == .clipboard,
                  updated.availability == .available else {
                return updated
            }
            guard let fingerprint = clipboardImageFingerprint(at: updated.content) else {
                updated.availability = .unavailable
                return updated
            }
            if let expectedFingerprint = updated.contentFingerprint {
                if fingerprint != expectedFingerprint {
                    updated.availability = .unavailable
                }
                return updated
            }
            return StashItem(
                id: updated.id,
                type: updated.type,
                content: updated.content,
                preview: updated.preview,
                createdAt: updated.createdAt,
                isPinned: updated.isPinned,
                availability: updated.availability,
                managedOrigin: updated.managedOrigin,
                contentFingerprint: fingerprint
            )
        }

        let referencedPaths = Set(storedItems.compactMap(managedPathIdentity(for:)))
        let invalidClipboardOrphans = reconciled.filter { item in
            item.type == .image
                && item.managedOrigin == .clipboard
                && item.availability == .unavailable
                && !referencedPaths.contains(standardizedPath(item.content))
        }
        if !invalidClipboardOrphans.isEmpty {
            let invalidPaths = Set(invalidClipboardOrphans.compactMap(managedPathIdentity(for:)))
            reconciled.removeAll { item in
                guard item.type == .image,
                      item.managedOrigin == .clipboard,
                      let path = managedPathIdentity(for: item) else { return false }
                return invalidPaths.contains(path)
            }
            for item in invalidClipboardOrphans {
                var manifest: DeletionRecoveryManifest?
                do {
                    manifest = try makeDeletionManifest(for: URL(fileURLWithPath: item.content))
                    if let manifest {
                        try commitDeletionManifest(manifest)
                        acknowledge.append(manifest.id)
                    }
                } catch {
                    if let manifest {
                        needsRecovery.append(manifest.id)
                    }
                    cleanupFailures.append(FileCleanupFailure(
                        path: item.content,
                        message: error.localizedDescription
                    ))
                }
            }
        }

        let persistedIDs = Set(storedItems.map(\.id))
        let fingerprintGroups = Dictionary(grouping: reconciled.filter { item in
            item.type == .image
                && item.managedOrigin == .clipboard
                && item.contentFingerprint != nil
        }) { $0.contentFingerprint! }
        for fingerprint in fingerprintGroups.keys.sorted() {
            guard let group = fingerprintGroups[fingerprint],
                  group.count > 1,
                  group.contains(where: { $0.availability == .available }) else { continue }
            let ordered = group.sorted { lhs, rhs in
                let lhsPersisted = persistedIDs.contains(lhs.id)
                let rhsPersisted = persistedIDs.contains(rhs.id)
                if lhsPersisted != rhsPersisted { return lhsPersisted }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            guard let canonical = ordered.first,
                  let backing = ordered.first(where: { $0.availability == .available }) else { continue }
            let groupIDs = Set(group.map(\.id))
            let groupPaths = Set(group.map { standardizedPath($0.content) })
            let backingPath = standardizedPath(backing.content)
            let merged = StashItem(
                id: canonical.id,
                type: .image,
                content: backingPath,
                preview: backing.preview,
                createdAt: group.map(\.createdAt).max() ?? canonical.createdAt,
                isPinned: group.contains(where: \.isPinned),
                availability: .available,
                managedOrigin: .clipboard,
                contentFingerprint: fingerprint
            )
            reconciled.removeAll { item in
                guard item.type == .image,
                      item.managedOrigin == .clipboard else { return false }
                return groupIDs.contains(item.id)
                    || managedPathIdentity(for: item).map(groupPaths.contains) == true
            }
            reconciled.append(merged)

            for duplicate in group where standardizedPath(duplicate.content) != backingPath {
                do {
                    let manifest = try makeDeletionManifest(
                        for: URL(fileURLWithPath: duplicate.content),
                        replacementItem: merged,
                        commitOnAcknowledgement: true
                    )
                    if let manifest {
                        acknowledge.append(manifest.id)
                    }
                } catch {
                    cleanupFailures.append(FileCleanupFailure(
                        path: duplicate.content,
                        message: error.localizedDescription
                    ))
                }
            }
        }
        reconciled.sort { $0.createdAt > $1.createdAt }
        return ManagedFileRecoveryResult(
            items: reconciled,
            cleanupFailures: cleanupFailures,
            manifestIDsNeedingRecovery: needsRecovery,
            manifestIDsToAcknowledge: Array(Set(acknowledge)),
            deletedItemPaths: pathsRemovedFromMetadata,
            resolvedJobIDs: resolvedJobIDs
        )
    }

    private func recoveredItem(at url: URL, origin: ManagedItemOrigin) -> StashItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let type: ItemType = isDirectory ? .file : ItemType.fromFileExtension(url.pathExtension)
        let detail = isDirectory
            ? "文件夹"
            : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let fingerprint = origin == .clipboard && type == .image
            ? clipboardImageFingerprint(at: url.path)
            : nil
        return StashItem(
            type: type,
            content: standardizedPath(url.path),
            preview: "\(url.lastPathComponent) (\(detail))",
            createdAt: values?.contentModificationDate ?? Date(),
            managedOrigin: origin,
            contentFingerprint: fingerprint
        )
    }

    private func clipboardImageFingerprint(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard isDescendant(url, of: imagesDirectory),
              fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .fileSizeKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= ClipboardPNGEncoder.maximumSourceBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return try? ClipboardPNGEncoder.fingerprint(from: data)
    }

    private func deduplicatedStoredItems(_ items: [StashItem]) -> [StashItem] {
        var unmanaged: [StashItem] = []
        var managedGroups: [String: [StashItem]] = [:]
        for item in items {
            guard item.type.isFileBacked, isManagedFile(at: item.content) else {
                unmanaged.append(item)
                continue
            }
            managedGroups[standardizedPath(item.content), default: []].append(item)
        }

        var result = unmanaged
        for path in managedGroups.keys.sorted() {
            guard let group = managedGroups[path],
                  var retained = group.min(by: { $0.id.uuidString < $1.id.uuidString }) else { continue }
            retained.isPinned = group.contains(where: \.isPinned)
            if group.contains(where: { $0.availability == .available }) {
                retained.availability = .available
            }
            result.append(retained)
        }
        return result
    }

    private func managedPathIdentity(for item: StashItem) -> String? {
        guard item.type.isFileBacked, isManagedFile(at: item.content) else { return nil }
        return standardizedPath(item.content)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func manifestURL(for id: UUID) -> URL {
        manifestsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func cleanupIntentURL(for id: UUID) -> URL {
        manifestsDirectory.appendingPathComponent("\(id.uuidString).cleanup.json")
    }

    private func deletionManifestURL(for id: UUID) -> URL {
        deletionManifestsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func markCleanupIntent(for id: UUID) throws {
        let source = manifestURL(for: id)
        let destination = cleanupIntentURL(for: id)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func manifestHasExistingFileState(_ id: UUID) -> Bool {
        guard let manifest = loadImportManifest(id) else { return false }
        let paths = [manifest.currentPartialPath, manifest.currentFinalPath]
            .compactMap { $0 } + manifest.committedItems.map(\.content)
        return paths.contains { fileManager.fileExists(atPath: $0) }
    }

    private func loadImportManifest(_ id: UUID) -> ImportRecoveryManifest? {
        let url = fileManager.fileExists(atPath: cleanupIntentURL(for: id).path)
            ? cleanupIntentURL(for: id)
            : manifestURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ImportRecoveryManifest.self, from: data)
    }

    private func writeManifest(
        _ manifest: ImportRecoveryManifest,
        operation: ImportManifestOperationKind
    ) throws {
        try manifestFaultInjector?(ImportManifestOperation(kind: operation, manifestID: manifest.id))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(manifest).write(to: manifestURL(for: manifest.id), options: [.atomic])
    }

    private func writeDeletionManifest(_ manifest: DeletionRecoveryManifest) throws {
        try JSONEncoder().encode(manifest).write(to: deletionManifestURL(for: manifest.id), options: [.atomic])
    }

    private func makeDeletionManifest(
        for sourceURL: URL,
        replacementItem: StashItem? = nil,
        commitOnAcknowledgement: Bool = false
    ) throws -> DeletionRecoveryManifest? {
        guard isManagedFile(sourceURL) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let sourceWasPresent = fileManager.fileExists(atPath: sourceURL.path)
        guard sourceWasPresent || replacementItem != nil else {
            return nil
        }
        let sourceIdentity = sourceWasPresent ? try managedFileIdentity(at: sourceURL) : nil
        let manifest = DeletionRecoveryManifest(
            id: UUID(),
            originalPath: standardizedPath(sourceURL.path),
            trashPath: trashDirectory.appendingPathComponent(
                "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
            ).path,
            replacementItem: replacementItem,
            commitOnAcknowledgement: commitOnAcknowledgement,
            sourceIdentity: sourceIdentity,
            sourceWasPresent: sourceWasPresent
        )
        try writeDeletionManifest(manifest)
        return manifest
    }

    private func deletionSourceState(
        for manifest: DeletionRecoveryManifest
    ) throws -> DeletionSourceState {
        let sourceURL = URL(fileURLWithPath: manifest.originalPath)
        let preferredTrashURL = URL(fileURLWithPath: manifest.trashPath)
        guard isManagedFile(sourceURL), isDescendant(preferredTrashURL, of: trashDirectory) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else { return .absent }
        if manifest.sourceWasPresent == false {
            return .replaced
        }
        if let expectedIdentity = manifest.sourceIdentity {
            return try managedFileIdentity(at: sourceURL) == expectedIdentity
                ? .matching
                : .replaced
        }
        if manifest.sourceWasPresent == nil,
           fileManager.fileExists(atPath: preferredTrashURL.path) {
            return .replaced
        }
        return .matching
    }

    @discardableResult
    private func commitDeletionManifest(
        _ manifest: DeletionRecoveryManifest
    ) throws -> DeletionSourceState {
        let state = try deletionSourceState(for: manifest)
        guard state == .matching else { return state }
        let sourceURL = URL(fileURLWithPath: manifest.originalPath)
        let preferredTrashURL = URL(fileURLWithPath: manifest.trashPath)
        let destination = fileManager.fileExists(atPath: preferredTrashURL.path)
            ? uniqueDestination(for: sourceURL, in: trashDirectory)
            : preferredTrashURL
        try cleanupFaultInjector?(FileCleanupOperation(
            kind: .committedQuarantine,
            sourceURL: sourceURL,
            destinationURL: destination
        ))
        try fileManager.moveItem(at: sourceURL, to: destination)
        return .absent
    }

    private func managedFileIdentity(at url: URL) throws -> ManagedFileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        return ManagedFileIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino)
        )
    }

    private func updateManifestThrowing(
        _ id: UUID,
        operation: ImportManifestOperationKind,
        mutation: (inout ImportRecoveryManifest) -> Void
    ) throws {
        let url = manifestURL(for: id)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var manifest = try decoder.decode(ImportRecoveryManifest.self, from: data)
        mutation(&manifest)
        try writeManifest(manifest, operation: operation)
    }

    private func updateManifest(
        _ id: UUID,
        operation: ImportManifestOperationKind = .finalize,
        mutation: (inout ImportRecoveryManifest) -> Void
    ) {
        try? updateManifestThrowing(id, operation: operation, mutation: mutation)
    }

    private func removeManifest(_ id: UUID) {
        try? fileManager.removeItem(at: manifestURL(for: id))
        try? fileManager.removeItem(at: cleanupIntentURL(for: id))
    }

    private func loadImportManifests() -> [ImportRecoveryManifest] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: manifestsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ImportRecoveryManifest.self, from: data)
        }
    }

    private func loadDeletionManifests() -> (
        manifests: [DeletionRecoveryManifest],
        failures: [FileCleanupFailure]
    ) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: deletionManifestsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var manifests: [DeletionRecoveryManifest] = []
        var failures: [FileCleanupFailure] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                manifests.append(try JSONDecoder().decode(DeletionRecoveryManifest.self, from: data))
            } catch {
                failures.append(FileCleanupFailure(
                    path: url.path,
                    message: "删除恢复清单损坏，已拒绝执行：\(error.localizedDescription)"
                ))
            }
        }
        return (manifests, failures)
    }

    func saveClipboardImage(
        data: Data,
        fileExtension: String,
        createdAt: Date = Date()
    ) async throws -> StashItem {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try ensureDirectories()
                    let prepared = try ClipboardPNGEncoder.prepare(from: data)
                    let fileURL = imagesDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("png")
                    try prepared.data.write(to: fileURL, options: .atomic)
                    do {
                        try fileManager.setAttributes(
                            [.modificationDate: createdAt],
                            ofItemAtPath: fileURL.path
                        )
                    } catch {
                        try? fileManager.removeItem(at: fileURL)
                        throw error
                    }
                    let size = ByteCountFormatter.string(
                        fromByteCount: Int64(prepared.data.count),
                        countStyle: .file
                    )
                    continuation.resume(returning: StashItem(
                        type: .image,
                        content: standardizedPath(fileURL.path),
                        preview: "图片 (\(size))",
                        createdAt: createdAt,
                        managedOrigin: .clipboard,
                        contentFingerprint: prepared.fingerprint
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func clipboardImageFingerprint(data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try ClipboardPNGEncoder.fingerprint(from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func discardUnregisteredClipboardImage(at path: String) async {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try ensureDirectories()
                    let sourceURL = URL(fileURLWithPath: path)
                    guard isDescendant(sourceURL, of: imagesDirectory) else {
                        continuation.resume()
                        return
                    }
                    if let manifest = try makeDeletionManifest(for: sourceURL) {
                        let result = try commitDeletionManifest(manifest)
                        guard result != .replaced else {
                            try? fileManager.removeItem(at: deletionManifestURL(for: manifest.id))
                            continuation.resume()
                            return
                        }
                        try? fileManager.removeItem(at: deletionManifestURL(for: manifest.id))
                    }
                } catch {
                    // A written manifest is intentionally retained so recovery can finish the discard.
                }
                continuation.resume()
            }
        }
    }

    func readManagedImage(at path: String) async throws -> ClipboardImagePayload {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    guard isManagedFile(at: path) else {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    let url = URL(fileURLWithPath: path)
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= ClipboardPNGEncoder.maximumSourceBytes else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let pngData = try ClipboardPNGEncoder.pngData(from: data)
                    continuation.resume(returning: ClipboardImagePayload(data: pngData, pasteboardType: .png))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func quarantineManagedFile(at path: String) async throws -> UUID? {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try ensureDirectories()
                    let sourceURL = URL(fileURLWithPath: path)
                    guard let manifest = try makeDeletionManifest(for: sourceURL) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    do {
                        guard try commitDeletionManifest(manifest) != .replaced else {
                            throw CocoaError(.fileWriteFileExists)
                        }
                    } catch {
                        try? fileManager.removeItem(at: deletionManifestURL(for: manifest.id))
                        throw error
                    }
                    continuation.resume(returning: manifest.id)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func prepareClipboardImageReplacement(
        existing: StashItem,
        incoming: StashItem
    ) async throws -> ManagedClipboardImageReplacement {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try ensureDirectories()
                    let sourceURL = URL(fileURLWithPath: existing.content)
                    let incomingURL = URL(fileURLWithPath: incoming.content)
                    guard existing.type == .image,
                          incoming.type == .image,
                          existing.managedOrigin == .clipboard,
                          incoming.managedOrigin == .clipboard,
                          isDescendant(sourceURL, of: imagesDirectory),
                          isDescendant(incomingURL, of: imagesDirectory),
                          standardizedPath(sourceURL.path) != standardizedPath(incomingURL.path),
                          let fingerprint = clipboardImageFingerprint(at: incomingURL.path),
                          existing.contentFingerprint.map({ $0 == fingerprint }) ?? true,
                          incoming.contentFingerprint.map({ $0 == fingerprint }) ?? true else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let replacement = StashItem(
                        id: existing.id,
                        type: .image,
                        content: standardizedPath(incomingURL.path),
                        preview: incoming.preview,
                        createdAt: max(existing.createdAt, incoming.createdAt),
                        isPinned: existing.isPinned,
                        availability: .available,
                        managedOrigin: .clipboard,
                        contentFingerprint: fingerprint
                    )
                    guard let manifest = try makeDeletionManifest(
                        for: sourceURL,
                        replacementItem: replacement
                    ) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    continuation.resume(returning: ManagedClipboardImageReplacement(
                        manifestID: manifest.id,
                        item: replacement
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func commitPreparedDeletion(manifestID: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    guard let data = try? Data(contentsOf: deletionManifestURL(for: manifestID)),
                          let manifest = try? JSONDecoder().decode(
                              DeletionRecoveryManifest.self,
                              from: data
                          ) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    guard try commitDeletionManifest(manifest) != .replaced else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func purgeTrash(olderThan age: TimeInterval = 7 * 24 * 60 * 60) {
        ioQueue.async { [self] in
            try? ensureDirectories()
            purgeContents(of: trashDirectory, olderThan: age)
            purgeContents(of: importingDirectory, olderThan: 24 * 60 * 60)
        }
    }

    func isManagedFile(at path: String) -> Bool {
        isManagedFile(URL(fileURLWithPath: path))
    }

    func isManagedFileAsync(at path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: isManagedFile(at: path))
            }
        }
    }

    func isReusableClipboardImage(
        at path: String,
        matching expectedFingerprint: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                let url = URL(fileURLWithPath: path)
                guard isDescendant(url, of: imagesDirectory),
                      fileManager.isReadableFile(atPath: url.path),
                      let values = try? url.resourceValues(forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                          .fileSizeKey
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= ClipboardPNGEncoder.maximumSourceBytes,
                      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                      let fingerprint = try? ClipboardPNGEncoder.fingerprint(from: data),
                      fingerprint == expectedFingerprint else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
        }
    }

    private func isManagedFile(_ url: URL) -> Bool {
        isDescendant(url, of: storageDirectory) || isDescendant(url, of: imagesDirectory)
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/")
    }

    private func uniqueDestination(for sourceURL: URL, in directory: URL) -> URL {
        let preferred = directory.appendingPathComponent(sourceURL.lastPathComponent)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }

        let fileExtension = sourceURL.pathExtension
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        let name = fileExtension.isEmpty
            ? "\(stem)-\(suffix)"
            : "\(stem)-\(suffix).\(fileExtension)"
        return directory.appendingPathComponent(name)
    }

    private func ensureDirectories() throws {
        for directory in [
            appRoot,
            storageDirectory,
            imagesDirectory,
            importingDirectory,
            manifestsDirectory,
            deletionManifestsDirectory,
            trashDirectory
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func purgeContents(of directory: URL, olderThan age: TimeInterval) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    @MainActor
    func openFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}

final class FileImportProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (@Sendable (FileImportProgress) -> Void)?
    private var lastEmissionTime: TimeInterval?
    private var pendingProgress: FileImportProgress?

    init(_ handler: (@Sendable (FileImportProgress) -> Void)?) {
        self.handler = handler
    }

    func emit(_ progress: FileImportProgress) {
        guard let handler else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let valueToEmit = lock.withLock { () -> FileImportProgress? in
            pendingProgress = progress
            if let lastEmissionTime, now - lastEmissionTime < 0.1 {
                return nil
            }
            lastEmissionTime = now
            let value = pendingProgress
            pendingProgress = nil
            return value
        }
        if let valueToEmit {
            handler(valueToEmit)
        }
    }

    func finish() {
        guard let handler else { return }
        let wait = lock.withLock { () -> TimeInterval? in
            guard pendingProgress != nil else { return nil }
            guard let lastEmissionTime else { return 0 }
            return max(0, 0.1 - (ProcessInfo.processInfo.systemUptime - lastEmissionTime))
        }
        guard let wait else { return }
        if wait > 0 {
            Thread.sleep(forTimeInterval: wait)
        }
        let valueToEmit = lock.withLock { () -> FileImportProgress? in
            guard let pendingProgress else { return nil }
            self.pendingProgress = nil
            lastEmissionTime = ProcessInfo.processInfo.systemUptime
            return pendingProgress
        }
        if let valueToEmit {
            handler(valueToEmit)
        }
    }
}

private struct SourceImportPlan {
    let sourceURL: URL
    let byteCount: Int64
    let entryCount: Int
    let isDirectory: Bool
}

private struct ItemMeasurement {
    let byteCount: Int64
    let entryCount: Int
    let isDirectory: Bool
}

private struct ImportedFileResult {
    let item: StashItem
    let copiedBytes: Int64
    let copiedEntries: Int
}

private enum FileImportOperationError: Error, LocalizedError {
    case cancelled
    case invalidSource(String)
    case limitExceeded(String)
    case quotaExceeded(String)
    case insufficientDiskSpace(String)
    case copyFailed(String)
    case posix(code: Int32, path: String)
    case cleanupRequired(
        message: String,
        underlyingKind: FileImportFailureKind?,
        wasCancelled: Bool,
        failures: [FileCleanupFailure]
    )

    var failureKind: FileImportFailureKind? {
        switch self {
        case .cancelled:
            return nil
        case .invalidSource:
            return .invalidSource
        case .limitExceeded:
            return .limitExceeded
        case .quotaExceeded:
            return .quotaExceeded
        case .insufficientDiskSpace:
            return .insufficientDiskSpace
        case .copyFailed:
            return .copyFailed
        case .cleanupRequired(_, let underlyingKind, _, _):
            return underlyingKind ?? .copyFailed
        case .posix(let code, _):
            switch code {
            case ENOSPC:
                return .insufficientDiskSpace
            case EDQUOT:
                return .quotaExceeded
            case ENOENT, ESTALE, ELOOP:
                return .invalidSource
            case EFBIG:
                return .limitExceeded
            default:
                return .copyFailed
            }
        }
    }

    var isCancellation: Bool {
        switch self {
        case .cancelled:
            return true
        case .cleanupRequired(_, _, let wasCancelled, _):
            return wasCancelled
        default:
            return false
        }
    }

    var cleanupFailures: [FileCleanupFailure] {
        if case .cleanupRequired(_, _, _, let failures) = self {
            return failures
        }
        return []
    }

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消存入"
        case .invalidSource(let message),
             .limitExceeded(let message),
             .quotaExceeded(let message),
             .insufficientDiskSpace(let message),
             .copyFailed(let message):
            return message
        case .cleanupRequired(let message, _, _, let failures):
            return "\(message)；另有 \(failures.count) 个路径清理失败"
        case .posix(let code, let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            switch code {
            case ECANCELED:
                return "复制已取消"
            case ENOSPC:
                return "磁盘空间不足"
            case EDQUOT:
                return "磁盘配额不足"
            case EACCES, EPERM:
                return "没有权限读取或写入 \(name)"
            case ENOENT, ESTALE:
                return "源项目已移动或不可用：\(name)"
            case ELOOP:
                return "检测到符号链接：\(name)"
            case EEXIST:
                return "目标项目已存在：\(name)"
            case EROFS:
                return "目标磁盘为只读"
            case EMFILE, ENFILE:
                return "打开的文件过多，请稍后重试"
            case EFBIG:
                return "项目超过文件系统允许的大小"
            case 0:
                return "复制 \(name) 时被系统中止"
            default:
                let detail = strerror(code).map { String(cString: $0) } ?? "错误码 \(code)"
                return "复制 \(name) 失败：\(detail)"
            }
        }
    }
}

private final class CopyOperationContext: @unchecked Sendable {
    let token: ImportCancellationToken
    private let policy: ImportPolicy
    private let completedBatchBytes: Int64
    private let completedBatchEntries: Int
    private let existingStorageBytes: Int64
    private let maximumWritableBytes: Int64
    private let reservedDiskBytes: Int64
    private let capacityURL: URL
    private let availableCapacityProvider: @Sendable (URL) throws -> Int64
    private let completedItems: Int
    private let totalItems: Int
    private let totalBytes: Int64
    private let progress: (@Sendable (FileImportProgress) -> Void)?
    private var copiedByPath: [String: Int64] = [:]
    private var lastCapacityCheckTime: TimeInterval = 0
    private var lastCapacityCheckBytes: Int64 = 0

    private(set) var copiedBytes: Int64 = 0
    private(set) var copiedEntries = 0
    private(set) var abortError: FileImportOperationError?

    init(
        token: ImportCancellationToken,
        policy: ImportPolicy,
        completedBatchBytes: Int64,
        completedBatchEntries: Int,
        existingStorageBytes: Int64,
        maximumWritableBytes: Int64,
        reservedDiskBytes: Int64,
        capacityURL: URL,
        availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64,
        completedItems: Int,
        totalItems: Int,
        totalBytes: Int64,
        progress: (@Sendable (FileImportProgress) -> Void)?
    ) {
        self.token = token
        self.policy = policy
        self.completedBatchBytes = completedBatchBytes
        self.completedBatchEntries = completedBatchEntries
        self.existingStorageBytes = existingStorageBytes
        self.maximumWritableBytes = maximumWritableBytes
        self.reservedDiskBytes = reservedDiskBytes
        self.capacityURL = capacityURL
        self.availableCapacityProvider = availableCapacityProvider
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.progress = progress
    }

    func abort(with error: FileImportOperationError) {
        if abortError == nil {
            abortError = error
        }
    }

    func beginEntry(path: String) throws {
        if token.isCancelled {
            throw FileImportOperationError.cancelled
        }
        try checkCapacityIfNeeded(force: copiedEntries == 0)
        let (newSourceCount, sourceOverflow) = copiedEntries.addingReportingOverflow(1)
        let (newBatchCount, batchOverflow) = completedBatchEntries.addingReportingOverflow(newSourceCount)
        guard !sourceOverflow, !batchOverflow, newBatchCount <= policy.maximumEntries else {
            throw FileImportOperationError.limitExceeded(
                "复制期间项目数量增长，超过 \(policy.maximumEntries) 个限制"
            )
        }
        copiedEntries = newSourceCount
        emitProgress(currentPath: path)
    }

    func updateCopiedBytes(state: copyfile_state_t, path: String) throws {
        if token.isCancelled {
            throw FileImportOperationError.cancelled
        }

        var copied: off_t = 0
        guard copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 else {
            throw FileImportOperationError.posix(code: errno, path: path)
        }

        let current = max(0, Int64(copied))
        let previous = copiedByPath[path] ?? 0
        let delta = current >= previous ? current - previous : current
        copiedByPath[path] = current
        let (newCopiedBytes, overflow) = copiedBytes.addingReportingOverflow(delta)
        guard !overflow else {
            throw FileImportOperationError.limitExceeded("复制大小超出可计算范围")
        }
        copiedBytes = newCopiedBytes
        try enforceByteLimits()
        try checkCapacityIfNeeded()
        emitProgress(currentPath: path)
    }

    func emitProgress(currentPath: String, force _: Bool = false) {
        guard let progress else { return }
        let displayedBytes = completedBatchBytes.addingReportingOverflow(copiedBytes).partialValue
        progress(FileImportProgress(
            phase: .importing,
            completedBytes: max(0, displayedBytes),
            totalBytes: totalBytes,
            completedItems: completedItems,
            totalItems: totalItems,
            currentItemName: currentPath.isEmpty ? nil : URL(fileURLWithPath: currentPath).lastPathComponent
        ))
    }

    func checkCapacityIfNeeded(force: Bool = false) throws {
        let now = ProcessInfo.processInfo.systemUptime
        let bytesSinceLastCheck = copiedBytes - lastCapacityCheckBytes
        guard force || lastCapacityCheckTime == 0 || now - lastCapacityCheckTime >= 0.2 || bytesSinceLastCheck >= 16 * 1_024 * 1_024 else {
            return
        }
        lastCapacityCheckTime = now
        lastCapacityCheckBytes = copiedBytes
        do {
            let freeBytes = try availableCapacityProvider(capacityURL)
            guard freeBytes >= reservedDiskBytes else {
                throw FileImportOperationError.insufficientDiskSpace("复制期间磁盘预留空间不足")
            }
        } catch let error as FileImportOperationError {
            throw error
        } catch {
            throw FileImportOperationError.copyFailed("无法复查磁盘空间：\(error.localizedDescription)")
        }
    }

    private func enforceByteLimits() throws {
        guard copiedBytes <= policy.maximumSingleItemBytes else {
            throw FileImportOperationError.limitExceeded(
                "复制期间项目增长，超过单项大小限制"
            )
        }

        let (batchBytes, batchOverflow) = completedBatchBytes.addingReportingOverflow(copiedBytes)
        guard !batchOverflow, batchBytes <= policy.maximumBatchBytes else {
            throw FileImportOperationError.limitExceeded(
                "复制期间批次增长，超过总大小限制"
            )
        }

        let (quotaBytes, quotaOverflow) = existingStorageBytes.addingReportingOverflow(batchBytes)
        guard !quotaOverflow, quotaBytes <= policy.storageQuotaBytes else {
            throw FileImportOperationError.quotaExceeded("复制期间项目增长，超过应用存储配额")
        }

        guard batchBytes <= maximumWritableBytes else {
            throw FileImportOperationError.insufficientDiskSpace("复制期间可用磁盘空间不足")
        }
    }
}
