import Foundation
import Darwin

enum ClipboardPasteboardHelperMode: String, Sendable {
    case data
    case string
}

enum ClipboardPasteboardHelperRead: Sendable {
    case value(Data)
    case unavailable
    case unstable
    case oversized
    case timedOut
    case failed
}

final class ClipboardPasteboardHelperClient: @unchecked Sendable {
    static let executableName = "QuickStashClipboardReader"
    static let executablePathEnvironmentKey = "QUICKSTASH_CLIPBOARD_HELPER_PATH"

    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var finished = false
        private var didTimeOut = false

        init(process: Process) {
            self.process = process
        }

        func expire() {
            let processToTerminate = lock.withLock { () -> Process? in
                guard !finished, process.isRunning else { return nil }
                didTimeOut = true
                return process
            }
            guard let processToTerminate else { return }
            let processIdentifier = processToTerminate.processIdentifier
            processToTerminate.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.forceKillIfNeeded(processIdentifier: processIdentifier)
            }
        }

        func finish() {
            lock.withLock { finished = true }
        }

        func timedOut() -> Bool {
            lock.withLock { didTimeOut }
        }

        private func forceKillIfNeeded(processIdentifier: Int32) {
            let shouldKill = lock.withLock {
                !finished && didTimeOut && process.isRunning
            }
            if shouldKill {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    private let explicitExecutableURL: URL?
    private let readTimeout: TimeInterval

    init(executableURL: URL? = nil, readTimeout: TimeInterval = 0.3) {
        explicitExecutableURL = executableURL
        self.readTimeout = max(0.05, readTimeout)
    }

    func read(
        pasteboardName: String,
        type: String,
        expectedChangeCount: Int,
        mode: ClipboardPasteboardHelperMode,
        maximumBytes: Int,
        timeout: TimeInterval? = nil
    ) -> ClipboardPasteboardHelperRead {
        guard maximumBytes > 0, let executableURL = resolvedExecutableURL() else {
            return .failed
        }
        let effectiveTimeout = max(0.05, timeout ?? readTimeout)

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "--pasteboard-name", pasteboardName,
            "--type", type,
            "--expected-change-count", String(expectedChangeCount),
            "--mode", mode.rawValue,
            "--maximum-bytes", String(maximumBytes),
            "--self-timeout-milliseconds", String(helperSelfTimeoutMilliseconds(for: effectiveTimeout))
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            return .failed
        }
        // The parent owns a duplicate of the pipe's write endpoint. Close it immediately so a
        // terminated or timed-out helper produces EOF for readDataToEndOfFile().
        outputPipe.fileHandleForWriting.closeFile()

        let timeoutState = TimeoutState(process: process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + effectiveTimeout) {
            timeoutState.expire()
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutState.finish()

        if timeoutState.timedOut() {
            return .timedOut
        }
        switch process.terminationStatus {
        case 0:
            return data.count <= maximumBytes ? .value(data) : .oversized
        case 10:
            return .unavailable
        case 11:
            return .unstable
        case 12:
            return .oversized
        case 14:
            return .timedOut
        default:
            return .failed
        }
    }

    private func helperSelfTimeoutMilliseconds(for timeout: TimeInterval) -> Int {
        let seconds = min(max(timeout + 0.5, 0.5), 60)
        return Int((seconds * 1_000).rounded(.up))
    }

    private func resolvedExecutableURL() -> URL? {
        if let explicitExecutableURL {
            return explicitExecutableURL
        }
        if let path = ProcessInfo.processInfo.environment[Self.executablePathEnvironmentKey],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(Self.executableName, isDirectory: false)
    }
}
