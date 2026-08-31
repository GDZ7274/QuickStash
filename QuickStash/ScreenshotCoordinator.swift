import AppKit
import CoreGraphics
import Darwin
import Foundation
import UniformTypeIdentifiers

private enum ScreenshotOutputError: LocalizedError {
    case clipboardWriteFailed

    var errorDescription: String? {
        "系统剪贴板拒绝了 PNG 数据"
    }
}

private final class ScreenshotOutputCommitState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentToken: ScreenshotSessionToken?
    private var minimumGeneration: UInt64 = 0

    func activate(_ token: ScreenshotSessionToken) {
        lock.lock()
        defer { lock.unlock() }
        guard token.generation >= minimumGeneration else { return }
        if let currentToken,
           currentToken.generation == token.generation,
           currentToken.revision > token.revision {
            return
        }
        minimumGeneration = max(minimumGeneration, token.generation)
        currentToken = token
    }

    func invalidate(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        minimumGeneration = max(minimumGeneration, generation &+ 1)
        if currentToken?.generation == generation {
            currentToken = nil
        }
    }

    func accepts(_ token: ScreenshotSessionToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.generation >= minimumGeneration && currentToken == token
    }
}

typealias ScreenshotFileCommitOperation = @Sendable (URL, URL) throws -> Void

actor ScreenshotOutputCommitGate {
    private nonisolated let state = ScreenshotOutputCommitState()
    private let commitOperation: ScreenshotFileCommitOperation

    init() {
        commitOperation = { temporaryURL, destinationURL in
            try Self.renameTemporaryFile(temporaryURL, destinationURL)
        }
    }

    init(commitOperation: @escaping ScreenshotFileCommitOperation) {
        self.commitOperation = commitOperation
    }

    private static func renameTemporaryFile(
        _ temporaryURL: URL,
        _ destinationURL: URL
    ) throws {
        let result = temporaryURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    nonisolated func activate(_ token: ScreenshotSessionToken) {
        state.activate(token)
    }

    nonisolated func invalidate(generation: UInt64) {
        state.invalidate(generation: generation)
    }

    func commitTemporaryFile(
        at temporaryURL: URL,
        to destinationURL: URL,
        token: ScreenshotSessionToken
    ) throws {
        do {
            guard !Task.isCancelled else { throw CancellationError() }
            // Token acceptance is the commit's linearization point. The file-system
            // operation stays on this actor and never holds the main-thread state lock.
            guard state.accepts(token) else { throw CancellationError() }
            try commitOperation(temporaryURL, destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func discardTemporaryFile(at temporaryURL: URL) {
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}

@MainActor
final class ScreenshotCoordinator: ObservableObject, ScreenshotCanvasDelegate {
    static let shared = ScreenshotCoordinator()

    private let capturer: ScreenshotCapturing
    private let outputGate = ScreenshotOutputCommitGate()
    private var sessionGate = ScreenshotSessionGate()
    private var startupTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var tasksAwaitingShutdown: [Task<Void, Never>] = []
    private var activeOutputID: UUID?
    private var overlays: [ScreenshotOverlayController] = []
    private weak var activeCanvas: ScreenshotCanvasView?
    private var isStarting = false
    private var isOutputInProgress: Bool { activeOutputID != nil }
    private var isConfigured = false
    private var activityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var errorHandler: (@MainActor @Sendable (String) -> Void)?

    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    init(capturer: ScreenshotCapturing = ScreenCaptureKitScreenshotCapturer()) {
        self.capturer = capturer
    }

    func configure(
        activityHandler: @escaping @MainActor @Sendable (Bool) -> Void,
        errorHandler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.activityHandler = activityHandler
        self.errorHandler = errorHandler
        guard !isConfigured else { return }
        isConfigured = true
        if !GlobalHotKeyManager.shared.start(action: { [weak self] in
            self?.startCapture()
        }), let error = GlobalHotKeyManager.shared.registrationError {
            report(error)
        }
    }

    func startCapture() {
        guard !isActive, !isStarting else { return }
        isStarting = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.beginCapture()
        }
        startupTask = task
    }

    func cancelCapture() {
        guard isActive || isStarting else { return }
        let endingGeneration = sessionGate.generation
        if let startupTask {
            startupTask.cancel()
            tasksAwaitingShutdown.append(startupTask)
        }
        startupTask = nil
        if let captureTask {
            captureTask.cancel()
            tasksAwaitingShutdown.append(captureTask)
        }
        captureTask = nil
        if let outputTask {
            outputTask.cancel()
            tasksAwaitingShutdown.append(outputTask)
        }
        outputTask = nil
        activeOutputID = nil
        closeOverlays()
        if sessionGate.isActive {
            sessionGate.end()
        }
        isActive = false
        isStarting = false
        activityHandler?(false)
        outputGate.invalidate(generation: endingGeneration)
    }

    func shutdown() {
        cancelCapture()
        GlobalHotKeyManager.shared.stop()
    }

    func drainAfterShutdown() async {
        let tasks = tasksAwaitingShutdown
        tasksAwaitingShutdown.removeAll(keepingCapacity: false)
        for task in tasks {
            await task.value
        }
    }

    private func beginCapture() async {
        guard isStarting, !isActive, !Task.isCancelled else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            isStarting = false
            startupTask = nil
            presentPermissionHelp()
            return
        }

        let token = sessionGate.begin()
        outputGate.activate(token)
        guard sessionGate.accepts(token), isStarting, !Task.isCancelled else {
            outputGate.invalidate(generation: token.generation)
            return
        }
        startupTask = nil
        isActive = true
        isStarting = false
        lastError = nil
        activityHandler?(true)

        let task = Task { [weak self, capturer] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let captures = try await capturer.captureDisplays()
                try Task.checkCancellation()
                guard let self, self.sessionGate.accepts(token) else { return }
                try self.presentOverlays(for: captures, generation: token.generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.sessionGate.generation == token.generation else { return }
                self.report("截图失败：\(error.localizedDescription)")
                self.cancelCapture()
            }
        }
        captureTask = task
    }

    private func presentOverlays(for captures: [CapturedDisplay], generation: UInt64) throws {
        let screensByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen)
        })
        let mapped = captures.compactMap { capture -> (CapturedDisplay, NSScreen)? in
            guard let screen = screensByID[capture.displayID] else { return nil }
            return (capture, screen)
        }
        guard !mapped.isEmpty else { throw ScreenshotCaptureError.noDisplays }

        closeOverlays()
        overlays = mapped.map { capture, screen in
            ScreenshotOverlayController(
                capture: capture,
                screen: screen,
                generation: generation,
                delegate: self
            )
        }
        let mouseLocation = NSEvent.mouseLocation
        let keyIndex = mapped.firstIndex(where: { $0.1.frame.contains(mouseLocation) }) ?? 0
        for (index, overlay) in overlays.enumerated() where index != keyIndex {
            overlay.setActive(false)
            overlay.show(makeKey: false)
        }
        overlays[keyIndex].show(makeKey: true)
        activeCanvas = overlays[keyIndex].canvas
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOverlays() {
        for overlay in overlays {
            overlay.close()
        }
        overlays.removeAll()
        activeCanvas = nil
    }

    // MARK: - ScreenshotCanvasDelegate

    func screenshotCanvasDidActivate(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot?
    ) {
        guard canvas.generation == sessionGate.generation else { return }
        let changedDisplay = activeCanvas !== canvas
        activeCanvas = canvas
        // A click after copy/save begins can immediately turn into a drag, resize,
        // text edit, or outside-click copy. Cancel the older output before that
        // preview can diverge from its immutable snapshot.
        if (changedDisplay || isOutputInProgress), sessionGate.isActive {
            advanceRevision()
        }
        for overlay in overlays {
            overlay.setActive(overlay.canvas === canvas)
        }
    }

    func screenshotCanvasDidMutate(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot?
    ) {
        guard canvas.generation == sessionGate.generation, sessionGate.isActive else { return }
        activeCanvas = canvas
        advanceRevision()
    }

    func screenshotCanvasDidRequestCancel(canvas: ScreenshotCanvasView, generation: UInt64) {
        guard generation == sessionGate.generation else { return }
        cancelCapture()
    }

    func screenshotCanvasDidRequestCopy(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot
    ) {
        guard canvas === activeCanvas else { return }
        beginCopy(snapshot)
    }

    func screenshotCanvasDidRequestSave(
        canvas: ScreenshotCanvasView,
        snapshot: ScreenshotCanvasSnapshot,
        format: ScreenshotOutputFormat
    ) {
        guard canvas === activeCanvas, !isOutputInProgress else { return }
        let token = sessionGate.token
        guard sessionGate.accepts(token), snapshot.generation == token.generation else { return }

        let panel = NSSavePanel()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = defaultFilename(format: format)
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url else { return }
                self.beginSave(snapshot, format: format, destinationURL: url, token: token)
            }
        }
    }

    private func beginCopy(_ snapshot: ScreenshotCanvasSnapshot) {
        guard !isOutputInProgress else { return }
        let token = sessionGate.token
        guard sessionGate.accepts(token), snapshot.generation == token.generation else { return }
        let operationID = UUID()
        activeOutputID = operationID
        let task = Task { [weak self] in
            var preparedHistoryItem: StashItem?
            do {
                let data = try await ScreenshotRenderExecutor.shared.renderAndEncode(
                    ScreenshotRenderRequest(
                        sourceImage: snapshot.sourceImage,
                        cropRect: snapshot.cropRect,
                        annotations: snapshot.annotations,
                        cornerRadius: snapshot.cornerRadius
                    ),
                    format: .png
                )
                try Task.checkCancellation()
                guard let self,
                      self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else { return }

                let clipboardMonitor = ClipboardMonitor.shared
                var historyWarning: String?
                do {
                    preparedHistoryItem = try await clipboardMonitor.prepareImageRecord(
                        data: data,
                        observedAt: Date()
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    historyWarning = "截图已复制，但未写入 QuickStash 历史：\(error.localizedDescription)"
                }

                try Task.checkCancellation()
                guard self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else {
                    if let preparedHistoryItem {
                        await clipboardMonitor.discardPreparedImageRecord(preparedHistoryItem)
                    }
                    return
                }

                let didWrite = clipboardMonitor.performInternalWrite {
                    let changeCount = NSPasteboard.general.clearContents()
                    let result = NSPasteboard.general.setData(data, forType: .png)
                    return (result, changeCount)
                }
                guard didWrite else {
                    if let preparedHistoryItem {
                        await clipboardMonitor.discardPreparedImageRecord(preparedHistoryItem)
                    }
                    throw ScreenshotOutputError.clipboardWriteFailed
                }

                if let preparedHistoryItem {
                    let didCommitHistory = await clipboardMonitor.commitPreparedImageRecord(
                        preparedHistoryItem,
                        isStillValid: { [weak self] in
                            guard let self else { return false }
                            return self.activeOutputID == operationID
                                && self.sessionGate.accepts(token)
                        }
                    )
                    if !didCommitHistory {
                        await clipboardMonitor.discardPreparedImageRecord(preparedHistoryItem)
                        historyWarning = "截图已复制，但 QuickStash 历史暂时不可用"
                    }
                }
                try Task.checkCancellation()
                guard self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else { return }
                if let historyWarning {
                    self.report(historyWarning)
                }
                self.finishSuccessfulOutput(operationID: operationID, token: token)
            } catch is CancellationError {
                if let preparedHistoryItem {
                    await ClipboardMonitor.shared.discardPreparedImageRecord(preparedHistoryItem)
                }
                self?.finishAbandonedOutput(operationID: operationID)
            } catch {
                if let preparedHistoryItem {
                    await ClipboardMonitor.shared.discardPreparedImageRecord(preparedHistoryItem)
                }
                guard let self,
                      self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else { return }
                self.finishAbandonedOutput(operationID: operationID)
                self.report("复制截图失败：\(error.localizedDescription)")
            }
        }
        outputTask = task
    }

    private func beginSave(
        _ snapshot: ScreenshotCanvasSnapshot,
        format: ScreenshotOutputFormat,
        destinationURL: URL,
        token: ScreenshotSessionToken
    ) {
        guard !isOutputInProgress, sessionGate.accepts(token) else { return }
        let operationID = UUID()
        activeOutputID = operationID
        let outputGate = self.outputGate
        let task = Task { [weak self] in
            var pendingTemporaryURL: URL?
            do {
                let temporaryURL = try await ScreenshotRenderExecutor.shared.renderEncodeAndWriteTemporary(
                    ScreenshotRenderRequest(
                        sourceImage: snapshot.sourceImage,
                        cropRect: snapshot.cropRect,
                        annotations: snapshot.annotations,
                        cornerRadius: snapshot.cornerRadius
                    ),
                    format: format,
                    destinationURL: destinationURL
                )
                pendingTemporaryURL = temporaryURL
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                guard self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else { throw CancellationError() }
                try await outputGate.commitTemporaryFile(
                    at: temporaryURL,
                    to: destinationURL,
                    token: token
                )
                pendingTemporaryURL = nil
                guard self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else { return }
                self.finishSuccessfulOutput(operationID: operationID, token: token)
            } catch is CancellationError {
                if let pendingTemporaryURL {
                    await outputGate.discardTemporaryFile(at: pendingTemporaryURL)
                }
                self?.finishAbandonedOutput(operationID: operationID)
            } catch {
                if let pendingTemporaryURL {
                    await outputGate.discardTemporaryFile(at: pendingTemporaryURL)
                }
                guard let self,
                      self.activeOutputID == operationID,
                      self.sessionGate.accepts(token) else { return }
                self.finishAbandonedOutput(operationID: operationID)
                self.report("保存截图失败：\(error.localizedDescription)")
            }
        }
        outputTask = task
    }

    private func finishSuccessfulOutput(
        operationID: UUID,
        token: ScreenshotSessionToken
    ) {
        guard activeOutputID == operationID, sessionGate.accepts(token) else { return }
        cancelCapture()
    }

    private func finishAbandonedOutput(operationID: UUID) {
        guard activeOutputID == operationID else { return }
        activeOutputID = nil
        outputTask = nil
    }

    private func advanceRevision() {
        if let outputTask {
            outputTask.cancel()
            tasksAwaitingShutdown.append(outputTask)
        }
        outputTask = nil
        activeOutputID = nil
        let token = sessionGate.mutate()
        outputGate.activate(token)
    }

    private func defaultFilename(format: ScreenshotOutputFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Screenshot_\(formatter.string(from: Date())).\(format.filenameExtension)"
    }

    private func report(_ message: String) {
        lastError = message
        errorHandler?(message)
    }

    private func presentPermissionHelp() {
        let message = "QuickStash 需要“屏幕与系统音频录制”权限才能截图"
        report(message)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在“系统设置 > 隐私与安全性 > 屏幕与系统音频录制”中启用 QuickStash。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
