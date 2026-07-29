#if DEBUG
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO

enum DebugScreenshotStressHarness {
    private static let reportEnvironmentKey = "QUICKSTASH_REAL_CAPTURE_STRESS_REPORT"
    private static let cycleCount = 100
    private static let maximumCancellationAttempts = 5

    @MainActor
    static func launchIfRequested() -> Bool {
        guard let rawReportPath = ProcessInfo.processInfo.environment[reportEnvironmentKey] else {
            return false
        }

        NSApp.setActivationPolicy(.accessory)
        Task.detached(priority: .userInitiated) {
            let exitCode = await run(rawReportPath: rawReportPath)
            Darwin.exit(exitCode)
        }
        return true
    }

    private static func run(rawReportPath: String) async -> Int32 {
        guard let reportURL = validatedReportURL(rawReportPath) else {
            logError("QuickStash real-capture stress report must be a standardized /tmp/*.json regular-file path")
            return 1
        }

        let outputDirectory = reportURL.deletingLastPathComponent().appendingPathComponent(
            ".quickstash-real-capture-\(UUID().uuidString)",
            isDirectory: true
        )
        var report = StressReport(
            status: .running,
            processID: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            startedAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            requestedCycles: cycleCount,
            completedCycles: 0,
            cancellationAttempts: 0,
            cancelledCaptures: 0,
            successfulCaptureSessions: 0,
            capturedDisplayImages: 0,
            clipboardPNGWrites: 0,
            pngSaves: 0,
            jpegSaves: 0,
            roundedCornerCycles: 0,
            stage: "permission",
            lastCancellationPhase: nil,
            displays: [],
            error: nil
        )

        do {
            try writeReport(report, to: reportURL)
        } catch {
            logError("Could not create real-capture stress report: \(error.localizedDescription)")
            return 1
        }

        let hasScreenCaptureAccess = await MainActor.run {
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        }
        guard hasScreenCaptureAccess else {
            report.status = .needsPermission
            report.updatedAt = Date().timeIntervalSince1970
            report.error = "Enable QuickStash in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch this exact build."
            do {
                try writeReport(report, to: reportURL)
            } catch {
                logError("Could not write screen-capture permission result: \(error.localizedDescription)")
                return 1
            }
            return 77
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            report.status = .failed
            report.stage = "setup"
            report.error = "Could not create isolated output directory: \(error.localizedDescription)"
            report.updatedAt = Date().timeIntervalSince1970
            try? writeReport(report, to: reportURL)
            return 1
        }

        let pasteboardProcessID = report.processID
        let pasteboardSink = await MainActor.run {
            NamedPasteboardSink(
                name: NSPasteboard.Name(
                    "com.quickstash.debug.capture-stress.\(pasteboardProcessID).\(UUID().uuidString)"
                )
            )
        }
        let successfulCapturer = ScreenCaptureKitScreenshotCapturer()
        let outputGate = ScreenshotOutputCommitGate()
        var sessionGate = ScreenshotSessionGate()

        do {
            for index in 0..<cycleCount {
                let displayNumber = index + 1
                let cancellationPhase: DebugScreenCaptureRequestPhase = index.isMultiple(of: 2)
                    ? .shareableContent
                    : .image
                report.stage = "cycle \(displayNumber): cancel \(cancellationPhase.rawValue)"
                report.lastCancellationPhase = cancellationPhase.rawValue

                let cancellationToken = sessionGate.begin()
                outputGate.activate(cancellationToken)
                let attempts = try await performObservedCancellation(phase: cancellationPhase)
                report.cancellationAttempts += attempts
                report.cancelledCaptures += 1
                sessionGate.end()
                outputGate.invalidate(generation: cancellationToken.generation)
                guard !sessionGate.accepts(cancellationToken) else {
                    throw HarnessError.message("Cancelled session token remained valid")
                }

                report.stage = "cycle \(displayNumber): capture displays"
                let captureToken = sessionGate.begin()
                outputGate.activate(captureToken)
                let captures = try await successfulCapturer.captureDisplays().sorted {
                    $0.displayID < $1.displayID
                }
                guard !captures.isEmpty else {
                    throw HarnessError.message("ScreenCaptureKit returned no displays")
                }
                for capture in captures {
                    guard capture.image.width > 0, capture.image.height > 0 else {
                        throw HarnessError.message(
                            "Display \(capture.displayID) returned an empty image"
                        )
                    }
                }
                guard sessionGate.accepts(captureToken) else {
                    throw HarnessError.message("Successful capture token became stale")
                }
                report.successfulCaptureSessions += 1
                report.capturedDisplayImages += captures.count
                report.displays = captures.map {
                    DisplaySummary(
                        displayID: $0.displayID,
                        width: $0.image.width,
                        height: $0.image.height
                    )
                }

                let selectedCapture = captures[index % captures.count]
                let crop = centeredStressCrop(for: selectedCapture.image)
                let cornerRadius = index.isMultiple(of: 2)
                    ? 0
                    : ScreenshotCropStylePolicy.clampedCornerRadius(24, for: crop)
                let request = ScreenshotRenderRequest(
                    sourceImage: selectedCapture.image,
                    cropRect: crop,
                    annotations: [],
                    cornerRadius: cornerRadius
                )
                let outputToken = sessionGate.mutate()
                outputGate.activate(outputToken)

                report.stage = "cycle \(displayNumber): named pasteboard PNG"
                let pngData = try await ScreenshotRenderExecutor.shared.renderAndEncode(
                    request,
                    format: .png
                )
                try validateEncodedImage(
                    pngData,
                    format: .png,
                    expectedWidth: crop.width,
                    expectedHeight: crop.height,
                    expectedCornerRadius: cornerRadius
                )
                try await pasteboardSink.writeAndVerifyPNG(pngData)
                report.clipboardPNGWrites += 1

                let pngDestination = outputDirectory.appendingPathComponent(
                    "cycle-\(displayNumber).png"
                )
                report.stage = "cycle \(displayNumber): save PNG"
                try await saveAndValidate(
                    request,
                    format: .png,
                    destinationURL: pngDestination,
                    token: outputToken,
                    outputGate: outputGate,
                    expectedWidth: crop.width,
                    expectedHeight: crop.height,
                    expectedCornerRadius: cornerRadius
                )
                report.pngSaves += 1

                let jpegDestination = outputDirectory.appendingPathComponent(
                    "cycle-\(displayNumber).jpg"
                )
                report.stage = "cycle \(displayNumber): save JPEG"
                try await saveAndValidate(
                    request,
                    format: .jpeg,
                    destinationURL: jpegDestination,
                    token: outputToken,
                    outputGate: outputGate,
                    expectedWidth: crop.width,
                    expectedHeight: crop.height,
                    expectedCornerRadius: cornerRadius
                )
                report.jpegSaves += 1
                if cornerRadius > 0 {
                    report.roundedCornerCycles += 1
                }

                try fileManager.removeItem(at: pngDestination)
                try fileManager.removeItem(at: jpegDestination)
                try assertOutputDirectoryIsEmpty(outputDirectory, fileManager: fileManager)

                sessionGate.end()
                outputGate.invalidate(generation: outputToken.generation)
                guard !sessionGate.accepts(outputToken) else {
                    throw HarnessError.message("Completed output token remained valid")
                }

                report.completedCycles = displayNumber
                report.stage = "cycle \(displayNumber): complete"
                report.updatedAt = Date().timeIntervalSince1970
                try writeReport(report, to: reportURL)
            }

            guard report.cancelledCaptures == cycleCount,
                  report.successfulCaptureSessions == cycleCount,
                  report.clipboardPNGWrites == cycleCount,
                  report.pngSaves == cycleCount,
                  report.jpegSaves == cycleCount,
                  report.roundedCornerCycles == cycleCount / 2 else {
                throw HarnessError.message("Final stress counters did not reach \(cycleCount)")
            }

            await pasteboardSink.clear()
            try assertOutputDirectoryIsEmpty(outputDirectory, fileManager: fileManager)
            try fileManager.removeItem(at: outputDirectory)
            report.status = .passed
            report.stage = "complete"
            report.updatedAt = Date().timeIntervalSince1970
            try writeReport(report, to: reportURL)
            return 0
        } catch {
            await pasteboardSink.clear()
            try? fileManager.removeItem(at: outputDirectory)
            report.status = .failed
            report.updatedAt = Date().timeIntervalSince1970
            report.error = error.localizedDescription
            do {
                try writeReport(report, to: reportURL)
            } catch {
                logError("Could not write failed stress result: \(error.localizedDescription)")
            }
            return 1
        }
    }

    private static func performObservedCancellation(
        phase: DebugScreenCaptureRequestPhase
    ) async throws -> Int {
        for attempt in 1...maximumCancellationAttempts {
            let probe = CaptureSubmissionProbe()
            let capturer = ScreenCaptureKitScreenshotCapturer(
                requestObserver: { observedPhase in
                    guard observedPhase == phase else { return }
                    probe.markSubmitted()
                }
            )
            let task = Task(priority: .userInitiated) { () throws -> [CapturedDisplay] in
                defer { probe.markCompleted() }
                return try await capturer.captureDisplays()
            }

            switch await probe.wait() {
            case .completed:
                do {
                    _ = try await task.value
                } catch {
                    throw HarnessError.message(
                        "Capture completed before submitting \(phase.rawValue): \(error.localizedDescription)"
                    )
                }
                throw HarnessError.message(
                    "Capture completed before submitting \(phase.rawValue)"
                )
            case .submitted:
                task.cancel()
                do {
                    _ = try await task.value
                } catch is CancellationError {
                    return attempt
                } catch {
                    throw HarnessError.message(
                        "Submitted \(phase.rawValue) cancellation failed: \(error.localizedDescription)"
                    )
                }
            }
        }

        throw HarnessError.message(
            "A submitted \(phase.rawValue) request completed before cancellation won \(maximumCancellationAttempts) times"
        )
    }

    private static func centeredStressCrop(for image: CGImage) -> PixelRect {
        let width = min(512, image.width)
        let height = min(384, image.height)
        return PixelRect(
            x: max(0, (image.width - width) / 2),
            y: max(0, (image.height - height) / 2),
            width: width,
            height: height
        )
    }

    private static func saveAndValidate(
        _ request: ScreenshotRenderRequest,
        format: ScreenshotOutputFormat,
        destinationURL: URL,
        token: ScreenshotSessionToken,
        outputGate: ScreenshotOutputCommitGate,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedCornerRadius: Int
    ) async throws {
        let temporaryURL = try await ScreenshotRenderExecutor.shared
            .renderEncodeAndWriteTemporary(
                request,
                format: format,
                destinationURL: destinationURL
            )
        do {
            try await outputGate.commitTemporaryFile(
                at: temporaryURL,
                to: destinationURL,
                token: token
            )
        } catch {
            await outputGate.discardTemporaryFile(at: temporaryURL)
            throw error
        }

        let data = try Data(contentsOf: destinationURL)
        try validateEncodedImage(
            data,
            format: format,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            expectedCornerRadius: expectedCornerRadius
        )
    }

    private static func validateEncodedImage(
        _ data: Data,
        format: ScreenshotOutputFormat,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedCornerRadius: Int
    ) throws {
        switch format {
        case .png:
            guard data.prefix(8).elementsEqual([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
            ]) else {
                throw HarnessError.message("Encoded PNG signature is invalid")
            }
        case .jpeg:
            guard data.prefix(2).elementsEqual([0xFF, 0xD8]),
                  data.suffix(2).elementsEqual([0xFF, 0xD9]) else {
                throw HarnessError.message("Encoded JPEG markers are invalid")
            }
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == expectedWidth,
              image.height == expectedHeight else {
            throw HarnessError.message(
                "Encoded \(format.rawValue) dimensions do not match the physical-pixel crop"
            )
        }

        guard expectedCornerRadius > 0 else { return }
        let cornerPixel = try rgbaPixel(in: image, x: 0, y: 0)
        switch format {
        case .png:
            guard cornerPixel.alpha == 0 else {
                throw HarnessError.message("Rounded PNG corner is not transparent")
            }
        case .jpeg:
            guard cornerPixel.red >= 230,
                  cornerPixel.green >= 230,
                  cornerPixel.blue >= 230,
                  cornerPixel.alpha == 255 else {
                throw HarnessError.message("Rounded JPEG corner is not opaque white")
            }
        }
    }

    private static func rgbaPixel(in image: CGImage, x: Int, y: Int) throws -> RgbaPixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        return try bytes.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                throw HarnessError.message("Could not sample encoded image pixels")
            }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(
                    x: -CGFloat(x),
                    y: -CGFloat(y),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            let sampledBytes = rawBuffer.bindMemory(to: UInt8.self)
            return RgbaPixel(
                red: sampledBytes[0],
                green: sampledBytes[1],
                blue: sampledBytes[2],
                alpha: sampledBytes[3]
            )
        }
    }

    private static func assertOutputDirectoryIsEmpty(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        let leftovers = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard leftovers.isEmpty else {
            throw HarnessError.message(
                "Stress output cleanup left files behind: \(leftovers.map(\.lastPathComponent).joined(separator: ", "))"
            )
        }
    }

    private static func validatedReportURL(_ rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/tmp/"), !rawPath.contains("\n") else { return nil }
        let reportURL = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        guard reportURL.path == rawPath,
              reportURL.pathExtension.lowercased() == "json" else { return nil }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: reportURL.path) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: reportURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                return nil
            }
        }
        let parent = reportURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let resolvedTemporaryRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedParent == resolvedTemporaryRoot
            || resolvedParent.hasPrefix(resolvedTemporaryRoot + "/")
            ? reportURL
            : nil
    }

    private static func writeReport(_ report: StressReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private static func logError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

private enum StressStatus: String, Encodable, Sendable {
    case running
    case passed
    case failed
    case needsPermission = "needs_permission"
}

private struct StressReport: Encodable, Sendable {
    let schemaVersion = 1
    var status: StressStatus
    let processID: Int32
    let bundleIdentifier: String
    let startedAt: TimeInterval
    var updatedAt: TimeInterval
    let requestedCycles: Int
    var completedCycles: Int
    var cancellationAttempts: Int
    var cancelledCaptures: Int
    var successfulCaptureSessions: Int
    var capturedDisplayImages: Int
    var clipboardPNGWrites: Int
    var pngSaves: Int
    var jpegSaves: Int
    var roundedCornerCycles: Int
    var stage: String
    var lastCancellationPhase: String?
    var displays: [DisplaySummary]
    var error: String?
}

private struct RgbaPixel: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private struct DisplaySummary: Encodable, Sendable {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
}

private enum HarnessError: LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

private final class CaptureSubmissionProbe: @unchecked Sendable {
    enum Outcome: Sendable {
        case submitted
        case completed
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func markSubmitted() {
        resolve(.submitted)
    }

    func markCompleted() {
        resolve(.completed)
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            var immediate: Outcome?
            lock.withLock {
                if let outcome {
                    immediate = outcome
                } else {
                    waiter = continuation
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    private func resolve(_ newOutcome: Outcome) {
        let continuation = lock.withLock { () -> CheckedContinuation<Outcome, Never>? in
            guard outcome == nil else { return nil }
            outcome = newOutcome
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(returning: newOutcome)
    }
}

@MainActor
private final class NamedPasteboardSink {
    private let pasteboard: NSPasteboard

    init(name: NSPasteboard.Name) {
        pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
    }

    func writeAndVerifyPNG(_ data: Data) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png),
              pasteboard.data(forType: .png) == data else {
            throw HarnessError.message("Named pasteboard rejected or changed PNG data")
        }
    }

    func clear() {
        pasteboard.clearContents()
    }
}
#endif
