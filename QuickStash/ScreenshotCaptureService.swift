@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

struct CapturedDisplay: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let image: CGImage
    let windowRegions: [ScreenshotWindowRegion]

    init(
        displayID: CGDirectDisplayID,
        image: CGImage,
        windowRegions: [ScreenshotWindowRegion] = []
    ) {
        self.displayID = displayID
        self.image = image
        self.windowRegions = windowRegions
    }

    var pixelSize: PixelSize {
        PixelSize(width: image.width, height: image.height)
    }
}

protocol ScreenshotCapturing: Sendable {
    func captureDisplays() async throws -> [CapturedDisplay]
}

enum ScreenshotCaptureError: LocalizedError {
    case timedOut
    case noDisplays
    case missingImage

    var errorDescription: String? {
        switch self {
        case .timedOut: return "截图请求超时，请重试"
        case .noDisplays: return "没有找到可截图的显示器"
        case .missingImage: return "系统没有返回截图图像"
        }
    }
}

#if DEBUG
enum DebugScreenCaptureRequestPhase: String, Sendable {
    case shareableContent
    case image
}
#endif

final class ScreenCaptureKitScreenshotCapturer: ScreenshotCapturing, @unchecked Sendable {
    private let timeout: TimeInterval
    private let timeoutQueue = DispatchQueue(
        label: "com.quickstash.screenshot-timeout",
        qos: .userInitiated
    )

    #if DEBUG
    private let requestObserver: (@Sendable (DebugScreenCaptureRequestPhase) -> Void)?

    init(
        timeout: TimeInterval = 10,
        requestObserver: (@Sendable (DebugScreenCaptureRequestPhase) -> Void)? = nil
    ) {
        self.timeout = max(1, timeout)
        self.requestObserver = requestObserver
    }
    #else
    init(timeout: TimeInterval = 10) {
        self.timeout = max(1, timeout)
    }
    #endif

    func captureDisplays() async throws -> [CapturedDisplay] {
        let content = try await loadShareableContent()
        guard !content.displays.isEmpty else { throw ScreenshotCaptureError.noDisplays }
        let processID = getpid()
        let excludedApplications = content.applications.filter { $0.processID == processID }
        let frontToBackOrder = Self.frontToBackWindowOrder()
        var captures: [CapturedDisplay] = []
        captures.reserveCapacity(content.displays.count)

        for display in content.displays {
            try Task.checkCancellation()
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let scale = max(1, CGFloat(filter.pointPixelScale))
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
            configuration.width = Int((CGFloat(display.width) * scale).rounded())
            configuration.height = Int((CGFloat(display.height) * scale).rounded())
            configuration.showsCursor = false
            configuration.shouldBeOpaque = true
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            let image = try await captureImage(filter: filter, configuration: configuration)
            let imageSize = PixelSize(width: image.width, height: image.height)
            let regions = content.windows.compactMap { window -> ScreenshotWindowRegion? in
                guard window.isOnScreen,
                      window.windowLayer == 0,
                      let application = window.owningApplication,
                      application.processID != processID,
                      window.frame.width >= 24,
                      window.frame.height >= 24,
                      let pixelRect = ScreenshotGeometry.windowPixelRect(
                          windowFrame: window.frame,
                          displayFrame: display.frame,
                          imageSize: imageSize
                      ) else { return nil }
                return ScreenshotWindowRegion(
                    windowID: window.windowID,
                    pixelRect: pixelRect,
                    order: frontToBackOrder[window.windowID] ?? Int.max,
                    cornerRadius: ScreenshotCropStylePolicy.automaticWindowCornerRadius(
                        windowFrame: window.frame,
                        displayFrame: display.frame,
                        imageSize: imageSize,
                        pixelRect: pixelRect
                    )
                )
            }.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.windowID < rhs.windowID
            }
            captures.append(CapturedDisplay(
                displayID: display.displayID,
                image: image,
                windowRegions: regions
            ))
        }
        return captures
    }

    private static func frontToBackWindowOrder() -> [CGWindowID: Int] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var order: [CGWindowID: Int] = [:]
        order.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            order[CGWindowID(number.uint32Value)] = index
        }
        return order
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        let resolution = OneShotContinuation<SCShareableContent>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard resolution.install(continuation) else { return }
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                    if let content {
                        resolution.resolve(.success(content))
                    } else {
                        resolution.resolve(.failure(error ?? ScreenshotCaptureError.noDisplays))
                    }
                }
                #if DEBUG
                requestObserver?(.shareableContent)
                #endif
                let timeoutWork = DispatchWorkItem {
                    resolution.resolve(.failure(ScreenshotCaptureError.timedOut))
                }
                resolution.setTimeoutWorkItem(timeoutWork)
                timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            resolution.resolve(.failure(CancellationError()))
        }
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let resolution = OneShotContinuation<CGImage>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard resolution.install(continuation) else { return }
                SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                ) { image, error in
                    if let image {
                        resolution.resolve(.success(image))
                    } else {
                        resolution.resolve(.failure(error ?? ScreenshotCaptureError.missingImage))
                    }
                }
                #if DEBUG
                requestObserver?(.image)
                #endif
                let timeoutWork = DispatchWorkItem {
                    resolution.resolve(.failure(ScreenshotCaptureError.timedOut))
                }
                resolution.setTimeoutWorkItem(timeoutWork)
                timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        } onCancel: {
            resolution.resolve(.failure(CancellationError()))
        }
    }
}

private final class OneShotContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        var pending: Result<Value, Error>?
        let shouldStart = lock.withLock {
            guard !isFinished else {
                pending = pendingResult
                pendingResult = nil
                return false
            }
            self.continuation = continuation
            return true
        }
        if let pending {
            continuation.resume(with: pending)
        }
        return shouldStart
    }

    func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        let shouldCancel = lock.withLock {
            guard !isFinished else { return true }
            timeoutWorkItem = workItem
            return false
        }
        if shouldCancel {
            workItem.cancel()
        }
    }

    func resolve(_ result: sending Result<Value, Error>) {
        let resolved = lock.withLock {
            guard !isFinished else {
                return (continuation: Optional<CheckedContinuation<Value, Error>>.none,
                        timeout: Optional<DispatchWorkItem>.none)
            }
            isFinished = true
            let installed = continuation
            continuation = nil
            if installed == nil {
                pendingResult = result
            }
            let timeout = timeoutWorkItem
            timeoutWorkItem = nil
            return (continuation: installed, timeout: timeout)
        }
        resolved.timeout?.cancel()
        resolved.continuation?.resume(with: result)
    }
}
