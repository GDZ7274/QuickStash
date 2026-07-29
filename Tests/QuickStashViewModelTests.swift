import Foundation
import Combine
import AppKit

private enum ViewModelTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private final class RetryCancellationImportScript: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func importFiles(_ urls: [URL], cancellationToken: ImportCancellationToken) async -> FileImportBatch {
        let invocation = lock.withLock {
            invocationCount += 1
            return invocationCount
        }
        if invocation == 1 {
            return FileImportBatch(
                items: [],
                failures: [FileImportFailure(
                    sourceURL: urls[0],
                    kind: .copyFailed,
                    message: "injected initial failure"
                )]
            )
        }

        while !cancellationToken.isCancelled {
            await Task.yield()
        }
        return FileImportBatch(
            items: [],
            failures: [],
            wasCancelled: true,
            retryURLs: urls
        )
    }
}

private final class BlockingReadStorageFileStore: StorageFileStore, @unchecked Sendable {
    private let wrapped = LocalStorageFileStore()
    private let lock = NSLock()
    private var readHasStarted = false
    let allowRead = DispatchSemaphore(value: 0)

    var hasStartedReading: Bool { lock.withLock { readHasStarted } }

    func createDirectory(at url: URL) throws { try wrapped.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { wrapped.fileExists(at: url) }
    func readData(at url: URL) throws -> Data {
        lock.withLock { readHasStarted = true }
        allowRead.wait()
        return try wrapped.readData(at: url)
    }
    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try wrapped.writeDataAtomically(data, to: url)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try wrapped.copyItem(at: sourceURL, to: destinationURL)
    }
}

private final class VMFailOnceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failNext = true

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            defer { failNext = false }
            return failNext
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: [.atomic])
    }
}

private final class FakeClipboardPasteboard: ClipboardPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var storedChangeCount = 0
    private var storedPNGData: Data?
    private var storedTIFFData: Data?
    private var storedText: String?
    private var storedPayloadReadCount = 0
    private var storedEmptyReadsRemaining = 0
    private var activeReaders = 0
    private var storedMaximumConcurrentReaders = 0
    private var storedReadOccurredOnMainThread = false
    private var storedForcedSnapshots: [ClipboardPayloadSnapshot] = []
    var readGate: DispatchSemaphore?
    let readStarted = DispatchSemaphore(value: 0)

    @MainActor var changeCount: Int {
        get { lock.withLock { storedChangeCount } }
        set { lock.withLock { storedChangeCount = newValue } }
    }

    @MainActor var pngData: Data? {
        get { lock.withLock { storedPNGData } }
        set { lock.withLock { storedPNGData = newValue } }
    }

    @MainActor var tiffData: Data? {
        get { lock.withLock { storedTIFFData } }
        set { lock.withLock { storedTIFFData = newValue } }
    }

    @MainActor var text: String? {
        get { lock.withLock { storedText } }
        set { lock.withLock { storedText = newValue } }
    }

    @MainActor var payloadReadCount: Int { lock.withLock { storedPayloadReadCount } }
    @MainActor var emptyReadsRemaining: Int {
        get { lock.withLock { storedEmptyReadsRemaining } }
        set { lock.withLock { storedEmptyReadsRemaining = max(0, newValue) } }
    }
    @MainActor var maximumConcurrentReaders: Int { lock.withLock { storedMaximumConcurrentReaders } }
    @MainActor var readOccurredOnMainThread: Bool { lock.withLock { storedReadOccurredOnMainThread } }
    @MainActor func enqueueForcedSnapshot(_ snapshot: ClipboardPayloadSnapshot) {
        lock.withLock { storedForcedSnapshots.append(snapshot) }
    }

    func readPayloadSnapshot(
        maximumImageBytes: Int,
        maximumTextCharacters: Int
    ) -> ClipboardPayloadSnapshot? {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            storedPayloadReadCount += 1
            activeReaders += 1
            storedMaximumConcurrentReaders = max(storedMaximumConcurrentReaders, activeReaders)
            storedReadOccurredOnMainThread = storedReadOccurredOnMainThread || Thread.isMainThread
            defer { readGate = nil }
            return readGate
        }
        readStarted.signal()
        gate?.wait()
        return lock.withLock {
            defer { activeReaders -= 1 }
            if !storedForcedSnapshots.isEmpty {
                return storedForcedSnapshots.removeFirst()
            }
            let payload: ClipboardPayloadRead
            if storedEmptyReadsRemaining > 0 {
                storedEmptyReadsRemaining -= 1
                payload = .none
            } else if let data = storedPNGData {
                payload = data.count <= maximumImageBytes
                    ? .image(data, fileExtension: "png")
                    : .rejected("image too large")
            } else if let data = storedTIFFData {
                payload = data.count <= maximumImageBytes
                    ? .image(data, fileExtension: "tiff")
                    : .rejected("image too large")
            } else if let text = storedText {
                payload = text.count <= maximumTextCharacters ? .text(text) : .rejected("text too large")
            } else {
                payload = .none
            }
            return ClipboardPayloadSnapshot(changeCount: storedChangeCount, payload: payload)
        }
    }
}

private final class FailSelectedQuarantine: @unchecked Sendable {
    private let lock = NSLock()
    private var selectedSourceURL: URL?
    private var hasFailed = false

    func select(_ sourceURL: URL) {
        lock.withLock {
            selectedSourceURL = sourceURL.standardizedFileURL
            hasFailed = false
        }
    }

    func inject(_ operation: FileCleanupOperation) throws {
        guard operation.kind == .committedQuarantine else { return }
        let shouldFail = lock.withLock {
            guard !hasFailed,
                  operation.sourceURL.standardizedFileURL == selectedSourceURL else { return false }
            hasFailed = true
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }
}

private final class ImageDateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Date?
    func record(_ date: Date) { lock.withLock { recorded = date } }
    var value: Date? { lock.withLock { recorded } }
}

@MainActor
private final class ManualRetentionScheduler: ClipboardRetentionScheduling {
    private(set) var scheduledDate: Date?
    private var action: (@MainActor @Sendable () -> Void)?
    private(set) var scheduleCount = 0

    func schedule(at date: Date, action: @escaping @MainActor @Sendable () -> Void) {
        scheduledDate = date
        self.action = action
        scheduleCount += 1
    }

    func cancel() {
        scheduledDate = nil
        action = nil
    }

    func fire() {
        let pendingAction = action
        action = nil
        scheduledDate = nil
        pendingAction?()
    }
}

@MainActor
private final class TestClock {
    var now: Date
    init(now: Date) { self.now = now }
}

private final class BlockingImageSaveScript: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StashItem, Never>?
    private let destination: URL
    private let data: Data
    private(set) var hasStarted = false

    init(destination: URL, data: Data = Data([7, 8, 9])) {
        self.destination = destination
        self.data = data
    }

    func save(observedAt: Date) async -> StashItem {
        await withCheckedContinuation { continuation in
            lock.withLock {
                hasStarted = true
                self.continuation = continuation
            }
        }
    }

    func finish() throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        let continuation = lock.withLock { () -> CheckedContinuation<StashItem, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: StashItem(
            type: .image,
            content: destination.path,
            preview: "blocked image",
            managedOrigin: .clipboard
        ))
    }

    var started: Bool { lock.withLock { hasStarted } }
}

private final class ImageDiscardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    func discard(_ item: StashItem) async {
        try? FileManager.default.removeItem(atPath: item.content)
        lock.withLock { storedCount += 1 }
    }

    var count: Int { lock.withLock { storedCount } }
}

private final class BlockingQuarantineScript: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStarted = false
    let release = DispatchSemaphore(value: 0)

    func inject(_ operation: FileCleanupOperation) {
        guard operation.kind == .committedQuarantine else { return }
        lock.withLock { storedStarted = true }
        release.wait()
    }

    var started: Bool { lock.withLock { storedStarted } }
}

private struct ImportManifestFixture: Codable {
    let id: UUID
    let createdAt: Date
    let sourceURLs: [URL]
    var currentPartialPath: String?
    var currentFinalPath: String?
    var committedItems: [StashItem]
    var cleanupFailures: [FileCleanupFailure]
    var requiresCleanup: Bool?
}

@main
struct QuickStashViewModelTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await testRetryDebounceAndErrorOwnership(in: root)
        try await testCancelledRetryKeepsOriginalImportError(in: root)
        try await testProgressCoalescesToOnePublishedMutation(in: root)
        try await testBootstrapMergesInputWithoutWritingEmptyState(in: root)
        try await testRecoveryJobsCannotBeDismissedOrTrimmed(in: root)
        try await testStorageRetryClearsOwnedErrorAndAcknowledgesManifest(in: root)
        try await testResolvedCleanupJobIsRemovedAfterBootstrap(in: root)
        try await testClipboardConsentMigrationAndReadBoundary()
        try await testClipboardBaselineInternalWritesAndOrigins()
        try await testInternalWriteReceiptDoesNotSuppressExternalCopy()
        try await testClipboardTimerCapturesTextLinkAndImage()
        try await testClipboardRetriesEmptySnapshotWithoutChangeCountAdvance()
        try await testSameCountTextUpgradesToImage()
        try await testInFlightImageBeatsProvisionalText(in: root)
        try await testCompletedTextSurvivesNewerClipboardCount(in: root)
        try await testProvisionalTextFinalizesBeforeNextCopy(in: root)
        try await testPreparedClipboardImageTransaction()
        try await testClipboardImageSurvivesLaterText(in: root)
        try await testClipboardStopRejectsLateRead()
        try await testClipboardReadTimeoutRecoversForLaterCopy()
        try testSystemClipboardReadsExplicitURLType()
        try await testClipboardReaderIsSerialAndDoesNotBlockMainActor()
        try await testClipboardShutdownDrainsImageSave(in: root)
        try await testClipboardGracefulTerminationPersistsFinalTextAndURL(in: root)
        try await testClipboardGracefulTerminationDrainsImageSave(in: root)
        try await testPendingImageIsDiscardedAfterDisableAndClear(in: root)
        try testClipboardRetentionPlanner()
        try await testClipboardRetentionTimer()
        try await testPinIsRejectedDuringClipboardCleanup(in: root)
        try await testClipboardImageOrphanRecoveryRetentionClearAndRestart(in: root)
        try await testPartialClipboardClear(in: root)

        print("QuickStash view-model tests passed")
    }

    @MainActor
    private static func testClipboardConsentMigrationAndReadBoundary() async throws {
        let freshSuite = "QuickStashTests.clipboard.fresh.\(UUID().uuidString)"
        guard let freshDefaults = UserDefaults(suiteName: freshSuite) else {
            throw ViewModelTestFailure.assertion("Could not create isolated defaults")
        }
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let freshPreferences = ClipboardPreferences(defaults: freshDefaults)
        try expect(freshPreferences.consent == .undecided, "Fresh consent was not undecided")
        try expect(freshPreferences.retentionPolicy == .default, "Fresh retention defaults changed")

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 4
        pasteboard.text = "secret-before-consent"
        let monitor = ClipboardMonitor(
            preferences: freshPreferences,
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        pasteboard.changeCount = 5
        monitor.checkClipboard()
        try expect(pasteboard.payloadReadCount == 0, "Undecided monitor read pasteboard payload")
        monitor.setConsent(.disabled)
        pasteboard.changeCount = 6
        monitor.checkClipboard()
        try expect(pasteboard.payloadReadCount == 0, "Disabled monitor read pasteboard payload")

        let legacySuite = "QuickStashTests.clipboard.legacy.\(UUID().uuidString)"
        guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else {
            throw ViewModelTestFailure.assertion("Could not create legacy defaults")
        }
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(true, forKey: "clipboardMonitoringEnabled")
        let migrated = ClipboardPreferences(defaults: legacyDefaults)
        try expect(migrated.consent == .enabled, "Legacy enabled preference did not migrate")
        try expect(
            legacyDefaults.string(forKey: "clipboardMonitoringConsent") == "enabled",
            "Migrated consent was not persisted"
        )
        try expect(
            legacyDefaults.object(forKey: "clipboardMonitoringEnabled") == nil,
            "Legacy clipboard preference remained after migration"
        )

        let disabledSuite = "QuickStashTests.clipboard.legacy-disabled.\(UUID().uuidString)"
        guard let disabledDefaults = UserDefaults(suiteName: disabledSuite) else {
            throw ViewModelTestFailure.assertion("Could not create disabled legacy defaults")
        }
        defer { disabledDefaults.removePersistentDomain(forName: disabledSuite) }
        disabledDefaults.set(false, forKey: "clipboardMonitoringEnabled")
        let migratedDisabled = ClipboardPreferences(defaults: disabledDefaults)
        try expect(migratedDisabled.consent == .disabled, "Legacy disabled preference did not migrate")
    }

    @MainActor
    private static func testClipboardBaselineInternalWritesAndOrigins() async throws {
        let suite = "QuickStashTests.clipboard.baseline.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ClipboardPreferences(defaults: defaults)
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 10
        pasteboard.text = "before-enable"
        var received: [StashItem] = []
        let imageDateRecorder = ImageDateRecorder()
        let monitor = ClipboardMonitor(
            preferences: preferences,
            pasteboard: pasteboard,
            imageSaver: { data, _, observedAt in
                imageDateRecorder.record(observedAt)
                return StashItem(
                    type: .image,
                    content: "/tmp/injected-\(data.count).png",
                    preview: "image",
                    createdAt: .distantFuture,
                    managedOrigin: .imported
                )
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)
        monitor.checkClipboard()
        try expect(received.isEmpty, "Enabling captured content copied before consent")
        try expect(pasteboard.payloadReadCount == 0, "Baseline check read pre-consent payload")

        let textObservedAt = Date(timeIntervalSince1970: 1_700_123_456)
        pasteboard.changeCount = 11
        pasteboard.text = "https://example.com/privacy"
        monitor.checkClipboard(observedAt: textObservedAt)
        try await waitUntil { received.count == 1 }
        try expect(received.count == 1, "New clipboard text was not captured")
        try expect(received[0].type == .url, "Clipboard URL classification changed")
        try expect(received[0].managedOrigin == .clipboard, "Clipboard URL origin was not recorded")
        try expect(received[0].createdAt == textObservedAt, "Clipboard URL observation time changed")

        let readsBeforeInternalWrite = pasteboard.payloadReadCount
        monitor.performInternalWrite {
            pasteboard.changeCount = 12
            return ((), 12)
        }
        monitor.checkClipboard()
        try expect(
            pasteboard.payloadReadCount == readsBeforeInternalWrite,
            "Internal app write was captured by the monitor"
        )

        monitor.setConsent(.disabled)
        pasteboard.changeCount = 13
        pasteboard.text = "copied-while-disabled"
        monitor.setConsent(.enabled)
        monitor.checkClipboard()
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(received.count == 1, "Re-enabling captured content from the disabled interval")

        let imageObservedAt = Date(timeIntervalSince1970: 1_700_123_999)
        pasteboard.text = nil
        pasteboard.pngData = Data([1, 2, 3])
        pasteboard.changeCount = 14
        monitor.checkClipboard(observedAt: imageObservedAt)
        let deadline = Date().addingTimeInterval(2)
        while received.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(received.count == 2, "Clipboard image was not captured")
        try expect(received[1].managedOrigin == .clipboard, "Clipboard image origin was not recorded")
        try expect(received[1].createdAt == imageObservedAt, "Async image lost its observation time")
        try expect(imageDateRecorder.value == imageObservedAt, "Image saver received the completion time")
    }

    @MainActor
    private static func testInternalWriteReceiptDoesNotSuppressExternalCopy() async throws {
        let suite = "QuickStashTests.clipboard.internal-receipt.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create internal-receipt defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 10
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        monitor.performInternalWrite {
            pasteboard.changeCount = 11
            let internalReceipt = 11
            pasteboard.text = "抢在内部写入返回前的外部复制"
            pasteboard.changeCount = 12
            return ((), internalReceipt)
        }
        monitor.checkClipboard()
        try await waitUntil(description: "external copy after internal receipt") {
            received.count == 1
        }
        try expect(
            received[0].content == "抢在内部写入返回前的外部复制",
            "Internal write receipt suppressed a later external clipboard change"
        )
        try expect(pasteboard.payloadReadCount == 5, "External clipboard text did not complete its stability window")
    }

    @MainActor
    private static func testClipboardTimerCapturesTextLinkAndImage() async throws {
        let suite = "QuickStashTests.clipboard.timer.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create timer defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 100
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            pollingInterval: 0.05,
            imageSaver: { data, fileExtension, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/timer-image-\(data.count).\(fileExtension)",
                    preview: "timer image",
                    createdAt: observedAt,
                    managedOrigin: .clipboard
                )
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }

        pasteboard.text = "实时文字"
        pasteboard.changeCount = 101
        try await waitUntil { received.count == 1 }
        try expect(received[0].type == .text, "Timer did not classify plain clipboard text")

        pasteboard.text = "https://example.com/realtime"
        pasteboard.changeCount = 102
        try await waitUntil { received.count == 2 }
        try expect(received[1].type == .url, "Timer did not classify a clipboard link")

        pasteboard.text = nil
        pasteboard.pngData = Data([1, 2, 3, 4])
        pasteboard.changeCount = 103
        try await waitUntil { received.count == 3 }
        try expect(received[2].type == .image, "Timer did not capture a clipboard image")

        pasteboard.pngData = nil
        pasteboard.tiffData = Data([0x49, 0x49, 0x2A, 0x00])
        pasteboard.changeCount = 104
        try await waitUntil { received.count == 4 }
        try expect(received[3].type == .image, "Timer did not capture a TIFF clipboard image")
        try expect(received[3].content.hasSuffix(".tiff"), "TIFF clipboard data lost its format")
        try expect(received.allSatisfy { $0.managedOrigin == .clipboard }, "Timer changed clipboard origins")
    }

    @MainActor
    private static func testClipboardRetriesEmptySnapshotWithoutChangeCountAdvance() async throws {
        let suite = "QuickStashTests.clipboard.empty-retry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create empty-retry defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 400
        pasteboard.emptyReadsRemaining = 1
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            pollingInterval: 0.05,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/same-count-\(data.count).png",
                    preview: "same-count image",
                    createdAt: observedAt,
                    managedOrigin: .clipboard
                )
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.changeCount = 401
        monitor.checkClipboard()
        try await waitUntil(description: "forced empty clipboard read") {
            pasteboard.payloadReadCount == 1 && pasteboard.emptyReadsRemaining == 0
        }

        pasteboard.text = "同一计数稍后发布的文字"
        try await waitUntil(description: "same-count clipboard retry") { received.count == 1 }
        try expect(received[0].content == "同一计数稍后发布的文字", "Retry changed clipboard text")
        try expect(received[0].type == .text, "Retry changed clipboard item type")
        try expect(pasteboard.changeCount == 401, "Test advanced changeCount while publishing payload")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 1, "Same-count clipboard payload was published more than once")
        try expect(pasteboard.payloadReadCount == 6, "Late text did not complete its stability window")

        pasteboard.text = nil
        pasteboard.emptyReadsRemaining = 1
        pasteboard.changeCount = 402
        monitor.checkClipboard()
        try await waitUntil(description: "forced empty image read") {
            pasteboard.payloadReadCount == 7 && pasteboard.emptyReadsRemaining == 0
        }

        pasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        try await waitUntil(description: "same-count image retry") { received.count == 2 }
        try expect(received[1].type == .image, "Retry did not publish the same-count clipboard image")
        try expect(pasteboard.changeCount == 402, "Image test advanced changeCount while publishing payload")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 2, "Same-count clipboard image was published more than once")
        try expect(pasteboard.payloadReadCount == 8, "Empty image snapshot was not retried exactly once")
    }

    @MainActor
    private static func testSameCountTextUpgradesToImage() async throws {
        let suite = "QuickStashTests.clipboard.same-count-upgrade.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create same-count upgrade defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 450
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/upgraded-\(data.count).png",
                    preview: "upgraded image",
                    createdAt: observedAt,
                    managedOrigin: .clipboard
                )
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "图片发布前的中间文字表示"
        pasteboard.changeCount = 451
        monitor.checkClipboard()
        try await waitUntil(description: "slow same-count image publication window") {
            pasteboard.payloadReadCount == 4 && received.isEmpty
        }

        pasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        try await waitUntil(description: "same-count text upgraded to image") {
            received.count == 1
        }
        try expect(received[0].type == .image, "Intermediate text was recorded instead of the final image")
        try expect(pasteboard.changeCount == 451, "Upgrade test changed the pasteboard count")
        try expect(pasteboard.payloadReadCount == 5, "Slow same-count image upgrade was read redundantly")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 1, "Same-count image upgrade produced duplicate history items")
    }

    @MainActor
    private static func testInFlightImageBeatsProvisionalText(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.inflight-image.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create in-flight image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 700
        let viewModelRoot = root.appendingPathComponent("inflight-image-order", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: viewModelRoot.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: viewModelRoot.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/inflight-image-\(data.count).png",
                    preview: "in-flight image",
                    createdAt: observedAt,
                    managedOrigin: .clipboard
                )
            }
        )
        monitor.onNewItem = {
            received.append($0)
            viewModel.addItem($0)
        }
        monitor.setConsent(.enabled)

        let imageObservedAt = Date(timeIntervalSince1970: 1_701_000_000)
        pasteboard.text = "图片尚未完成时的文字表示"
        pasteboard.changeCount = 701
        monitor.checkClipboard(observedAt: imageObservedAt)
        try await waitUntil(description: "initial provisional image text") {
            pasteboard.payloadReadCount == 1
        }

        let blockedImageRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = blockedImageRead
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 701,
            payload: .image(Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")
        ))
        try await waitUntil(description: "in-flight image confirmation") {
            pasteboard.payloadReadCount == 2
        }

        let textObservedAt = imageObservedAt.addingTimeInterval(1)
        pasteboard.text = "图片之后的新文字"
        pasteboard.changeCount = 702
        monitor.checkClipboard(observedAt: textObservedAt)
        try expect(received.isEmpty, "New count finalized text while its image read was in flight")
        blockedImageRead.signal()

        try await waitUntil(description: "image and later text publication") { received.count == 2 }
        try expect(received.filter { $0.type == .image }.count == 1, "In-flight image was downgraded to text")
        try expect(
            !received.contains(where: { $0.content == "图片尚未完成时的文字表示" }),
            "Provisional image text leaked into history"
        )
        try expect(
            viewModel.items.map(\.type) == [.text, .image],
            "In-flight image and later text were not ordered by copy time"
        )
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testCompletedTextSurvivesNewerClipboardCount(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.completed-text.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create completed-text defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 600
        let blockedRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = blockedRead
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 601,
            payload: .text("已经稳定读取的旧文字")
        ))
        let viewModelRoot = root.appendingPathComponent("completed-text-order", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: viewModelRoot.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: viewModelRoot.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = {
            received.append($0)
            viewModel.addItem($0)
        }
        monitor.setConsent(.enabled)

        let oldObservedAt = Date(timeIntervalSince1970: 1_700_800_000)
        pasteboard.text = "已经稳定读取的旧文字"
        pasteboard.changeCount = 601
        monitor.checkClipboard(observedAt: oldObservedAt)
        try await waitUntil(description: "old text read in flight") {
            pasteboard.payloadReadCount == 1
        }

        let newObservedAt = oldObservedAt.addingTimeInterval(1)
        pasteboard.text = "后复制的新文字"
        pasteboard.changeCount = 602
        monitor.checkClipboard(observedAt: newObservedAt)
        blockedRead.signal()

        try await waitUntil(description: "old and new text publication") { received.count == 2 }
        try expect(
            Set(received.map(\.content)) == Set(["已经稳定读取的旧文字", "后复制的新文字"]),
            "Advancing changeCount dropped a stable clipboard text payload"
        )
        try expect(
            viewModel.items.map(\.content) == ["后复制的新文字", "已经稳定读取的旧文字"],
            "Clipboard text items were not ordered by their observed copy time"
        )
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testProvisionalTextFinalizesBeforeNextCopy(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.provisional-text.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create provisional-text defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 650
        let viewModelRoot = root.appendingPathComponent("provisional-text-order", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: viewModelRoot.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: viewModelRoot.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = {
            received.append($0)
            viewModel.addItem($0)
        }
        monitor.setConsent(.enabled)

        let oldObservedAt = Date(timeIntervalSince1970: 1_700_900_000)
        pasteboard.text = "确认窗口中的旧文字"
        pasteboard.changeCount = 651
        monitor.checkClipboard(observedAt: oldObservedAt)
        try await waitUntil(description: "provisional text confirmation") {
            pasteboard.payloadReadCount >= 2 && received.isEmpty
        }

        let newObservedAt = oldObservedAt.addingTimeInterval(1)
        pasteboard.text = "确认窗口之后的新文字"
        pasteboard.changeCount = 652
        monitor.checkClipboard(observedAt: newObservedAt)
        try expect(received.map(\.content) == ["确认窗口中的旧文字"], "Advancing count did not finalize provisional text")

        try await waitUntil(description: "new text after provisional finalization") {
            received.count == 2
        }
        try expect(
            viewModel.items.map(\.content) == ["确认窗口之后的新文字", "确认窗口中的旧文字"],
            "Provisional and newer text were not ordered by copy time"
        )
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testPreparedClipboardImageTransaction() async throws {
        let suite = "QuickStashTests.clipboard.prepared.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create prepared-image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        let discarder = ImageDiscardRecorder()
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/prepared-\(UUID().uuidString)-\(data.count).png",
                    preview: "prepared image",
                    createdAt: observedAt,
                    managedOrigin: .imported
                )
            },
            imageDiscarder: { await discarder.discard($0) }
        )
        monitor.onNewItem = { received.append($0) }

        let observedAt = Date(timeIntervalSince1970: 1_700_555_000)
        let prepared = try await monitor.prepareImageRecord(
            data: Data([9, 8, 7]),
            observedAt: observedAt
        )
        try expect(received.isEmpty, "Prepared screenshot image was published before clipboard write")
        try expect(monitor.commitPreparedImageRecord(prepared), "Prepared screenshot image did not commit")
        try expect(!monitor.commitPreparedImageRecord(prepared), "Prepared screenshot image committed twice")
        try expect(received.count == 1, "Prepared screenshot image was not recorded exactly once")
        try expect(received[0].managedOrigin == .clipboard, "Prepared screenshot image origin changed")
        try expect(received[0].createdAt == observedAt, "Prepared screenshot image lost its copy time")

        let abandoned = try await monitor.prepareImageRecord(data: Data([6, 5, 4]))
        await monitor.discardPreparedImageRecord(abandoned)
        try expect(discarder.count == 1, "Abandoned screenshot history file was not discarded")
        try expect(!monitor.commitPreparedImageRecord(abandoned), "Discarded screenshot history item committed late")

        let pendingAtShutdown = try await monitor.prepareImageRecord(data: Data([3, 2, 1]))
        await monitor.shutdownAndDrain()
        try expect(discarder.count == 2, "Shutdown did not discard an uncommitted screenshot history image")
        try expect(!monitor.commitPreparedImageRecord(pendingAtShutdown), "Shutdown image committed after cleanup")
    }

    @MainActor
    private static func testClipboardImageSurvivesLaterText(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.image-then-text.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create image-then-text defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 200
        let imagePath = root.appendingPathComponent("clipboard-image-before-text.png")
        let saver = BlockingImageSaveScript(destination: imagePath)
        var received: [StashItem] = []
        let viewModelRoot = root.appendingPathComponent("clipboard-image-order", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: viewModelRoot.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: viewModelRoot.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, observedAt in await saver.save(observedAt: observedAt) }
        )
        monitor.onNewItem = {
            received.append($0)
            viewModel.addItem($0)
        }
        monitor.setConsent(.enabled)

        let imageObservedAt = Date(timeIntervalSince1970: 1_700_700_000)
        pasteboard.pngData = Data([1, 2, 3])
        pasteboard.changeCount = 201
        monitor.checkClipboard(observedAt: imageObservedAt)
        try await waitUntil { saver.started }

        let textObservedAt = imageObservedAt.addingTimeInterval(1)
        pasteboard.pngData = nil
        pasteboard.text = "图片之后复制的文字"
        pasteboard.changeCount = 202
        monitor.checkClipboard(observedAt: textObservedAt)
        try await waitUntil { received.contains(where: { $0.type == .text }) }

        try saver.finish()
        try await waitUntil { received.contains(where: { $0.type == .image }) }
        try expect(received.filter { $0.type == .image }.count == 1, "Earlier clipboard image was lost or duplicated")
        try expect(received.filter { $0.type == .text }.count == 1, "Later clipboard text was lost or duplicated")
        try expect(viewModel.items.map(\.type) == [.text, .image], "Delayed image reordered clipboard history")
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testClipboardStopRejectsLateRead() async throws {
        let suite = "QuickStashTests.clipboard.stop.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create stop-monitor defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 300
        let readGate = DispatchSemaphore(value: 0)
        pasteboard.readGate = readGate
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            pollingInterval: 0.05,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "in flight before stop"
        pasteboard.changeCount = 301
        monitor.checkClipboard()
        try await waitUntil { pasteboard.payloadReadCount == 1 }
        monitor.stopMonitoring()
        pasteboard.text = "copied while stopped"
        pasteboard.changeCount = 302
        readGate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.checkClipboard()
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.isEmpty, "A stopped clipboard monitor published a late read")
        try expect(pasteboard.payloadReadCount == 1, "A stopped clipboard monitor scheduled another read")

        monitor.startMonitoring()
        pasteboard.text = "captured after restart"
        pasteboard.changeCount = 303
        try await waitUntil { received.count == 1 }
        monitor.stopMonitoring()
        try expect(received[0].content == "captured after restart", "Restart captured stopped-interval content")
    }

    @MainActor
    private static func testClipboardReadTimeoutRecoversForLaterCopy() async throws {
        let suite = "QuickStashTests.clipboard.read-timeout.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create read-timeout defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 500
        let blockedRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = blockedRead
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            pollingInterval: 0.05,
            readTimeoutInterval: 0.05,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "永远阻塞的旧提供者"
        pasteboard.changeCount = 501
        monitor.checkClipboard()
        try await waitUntil(description: "blocked clipboard provider") {
            pasteboard.payloadReadCount == 1
        }

        pasteboard.text = "超时后仍然记录的新文字"
        pasteboard.changeCount = 502
        monitor.checkClipboard()
        try await waitUntil(description: "clipboard timeout recovery") {
            received.count == 1
        }
        try expect(received[0].content == "超时后仍然记录的新文字", "Timeout recovery published stale text")
        try expect(pasteboard.maximumConcurrentReaders == 2, "Timed-out reader prevented a replacement read")

        blockedRead.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 1, "Timed-out clipboard read published after its replacement")
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testSystemClipboardReadsExplicitURLType() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writeReceipt = pasteboard.clearContents()
        let expected = "https://example.com/url-only"
        try expect(pasteboard.setString(expected, forType: .URL), "Named pasteboard rejected URL data")
        try expect(
            pasteboard.changeCount == writeReceipt,
            "Pasteboard content publication changed the clearContents write receipt"
        )
        let snapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: 1024,
            maximumTextCharacters: 1024
        )
        guard let snapshot else {
            throw ViewModelTestFailure.assertion("URL-only pasteboard did not produce a stable snapshot")
        }
        guard case .text(let content) = snapshot.payload else {
            throw ViewModelTestFailure.assertion("URL-only pasteboard was not read as text")
        }
        try expect(content == expected, "URL-only pasteboard content changed")
    }

    @MainActor
    private static func testClipboardReaderIsSerialAndDoesNotBlockMainActor() async throws {
        let suite = "QuickStashTests.clipboard.slow-reader.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create slow-reader defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1
        let gate = DispatchSemaphore(value: 0)
        pasteboard.readGate = gate
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "first"
        pasteboard.changeCount = 2
        let start = ProcessInfo.processInfo.systemUptime
        monitor.checkClipboard()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try expect(elapsed < 0.1, "Slow pasteboard provider blocked the main actor")
        try await waitUntil { pasteboard.payloadReadCount == 1 }

        pasteboard.text = "second"
        pasteboard.changeCount = 3
        monitor.checkClipboard()
        pasteboard.text = "latest"
        pasteboard.changeCount = 4
        monitor.checkClipboard()
        try expect(pasteboard.payloadReadCount == 1, "More than one payload reader ran in flight")
        try expect(pasteboard.maximumConcurrentReaders == 1, "Payload readers were not serialized")

        gate.signal()
        try await waitUntil { received.count == 1 }
        try expect(received[0].content == "latest", "Latest pending clipboard change was not retained")
        try expect(pasteboard.payloadReadCount == 5, "Stable latest text did not complete its stability window")
        try expect(pasteboard.maximumConcurrentReaders == 1, "Pending payload overlapped the active reader")
        try expect(!pasteboard.readOccurredOnMainThread, "Pasteboard payload was read on the main thread")
    }

    @MainActor
    private static func testClipboardShutdownDrainsImageSave(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.shutdown-drain.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create shutdown-drain defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 800
        let imagePath = root.appendingPathComponent("shutdown-drain-image.png")
        let saver = BlockingImageSaveScript(destination: imagePath)
        let discarder = ImageDiscardRecorder()
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, observedAt in await saver.save(observedAt: observedAt) },
            imageDiscarder: { await discarder.discard($0) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        pasteboard.changeCount = 801
        monitor.checkClipboard()
        try await waitUntil(description: "shutdown image save started") { saver.started }

        let shutdown = Task { await monitor.shutdownAndDrain() }
        try await Task.sleep(nanoseconds: 20_000_000)
        try saver.finish()
        await shutdown.value
        try expect(received.isEmpty, "Shutdown published an image that was still saving")
        try expect(discarder.count == 1, "Shutdown did not wait for and discard the image save")
        try expect(!FileManager.default.fileExists(atPath: imagePath.path), "Shutdown left an image orphan")
    }

    @MainActor
    private static func testClipboardGracefulTerminationPersistsFinalTextAndURL(
        in root: URL
    ) async throws {
        try await verifyGracefulTerminationPersistence(
            content: "退出前最后一条文字",
            expectedType: .text,
            baseName: "graceful-final-text",
            in: root
        )
        try await verifyGracefulTerminationPersistence(
            content: "https://example.com/graceful-final-link",
            expectedType: .url,
            baseName: "graceful-final-link",
            in: root
        )
    }

    @MainActor
    private static func verifyGracefulTerminationPersistence(
        content: String,
        expectedType: ItemType,
        baseName: String,
        in root: URL
    ) async throws {
        let suite = "QuickStashTests.clipboard.\(baseName).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create graceful-termination defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let base = root.appendingPathComponent(baseName, isDirectory: true)
        let metadata = base.appendingPathComponent("metadata", isDirectory: true)
        let files = base.appendingPathComponent("files", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: files)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadata),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 900
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { viewModel.addItem($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = content
        pasteboard.changeCount = 901
        monitor.checkClipboard()
        try await waitUntil(description: "graceful provisional \(expectedType.rawValue)") {
            pasteboard.payloadReadCount >= 2 && viewModel.items.isEmpty
        }

        await monitor.shutdownForTermination(settleNanoseconds: 0)
        try expect(viewModel.items.count == 1, "Graceful termination lost or duplicated \(expectedType.rawValue)")
        try expect(viewModel.items[0].content == content, "Graceful termination changed clipboard content")
        try expect(viewModel.items[0].type == expectedType, "Graceful termination changed clipboard type")
        try expect(viewModel.items[0].managedOrigin == .clipboard, "Graceful termination changed clipboard origin")
        await viewModel.flushForTermination()

        let restarted = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadata),
            fileManager: QuickStashFileManager(baseDirectory: files),
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "graceful \(expectedType.rawValue) restart") {
            restarted.items.contains(where: { $0.content == content })
        }
        let matches = restarted.items.filter { $0.content == content }
        try expect(matches.count == 1, "Restart duplicated graceful clipboard content")
        try expect(matches[0].type == expectedType, "Restart changed graceful clipboard type")
    }

    @MainActor
    private static func testClipboardGracefulTerminationDrainsImageSave(
        in root: URL
    ) async throws {
        let suite = "QuickStashTests.clipboard.graceful-image.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create graceful-image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let base = root.appendingPathComponent("graceful-final-image", isDirectory: true)
        let metadata = base.appendingPathComponent("metadata", isDirectory: true)
        let files = base.appendingPathComponent("files", isDirectory: true)
        let imagePath = files.appendingPathComponent("final-image.png")
        let saver = BlockingImageSaveScript(destination: imagePath)
        let discarder = ImageDiscardRecorder()
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadata),
            fileManager: QuickStashFileManager(baseDirectory: files),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 950
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, observedAt in await saver.save(observedAt: observedAt) },
            imageDiscarder: { await discarder.discard($0) }
        )
        monitor.onNewItem = { viewModel.addItem($0) }
        monitor.setConsent(.enabled)

        pasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        pasteboard.changeCount = 951
        monitor.checkClipboard()
        try await waitUntil(description: "graceful image save started") { saver.started }

        let shutdown = Task {
            await monitor.shutdownForTermination(settleNanoseconds: 0)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        try saver.finish()
        await shutdown.value

        try expect(discarder.count == 0, "Graceful termination discarded an accepted image")
        try expect(viewModel.items.count == 1, "Graceful termination lost or duplicated an image")
        try expect(viewModel.items[0].type == .image, "Graceful termination changed image type")
        try expect(FileManager.default.fileExists(atPath: imagePath.path), "Graceful termination removed the final image")
        await viewModel.flushForTermination()

        let restarted = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadata),
            fileManager: QuickStashFileManager(baseDirectory: files),
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "graceful image restart") {
            restarted.items.contains(where: { $0.content == imagePath.path })
        }
        try expect(
            restarted.items.filter { $0.content == imagePath.path }.count == 1,
            "Restart duplicated graceful clipboard image"
        )
    }

    @MainActor
    private static func testPendingImageIsDiscardedAfterDisableAndClear(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.pending-image.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create pending-image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let disablePasteboard = FakeClipboardPasteboard()
        disablePasteboard.changeCount = 20
        let disablePath = root.appendingPathComponent("stale-after-disable.png")
        let disableSaver = BlockingImageSaveScript(destination: disablePath)
        let disableDiscarder = ImageDiscardRecorder()
        var disabledItems: [StashItem] = []
        let disableMonitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: disablePasteboard,
            imageSaver: { _, _, observedAt in await disableSaver.save(observedAt: observedAt) },
            imageDiscarder: { await disableDiscarder.discard($0) }
        )
        disableMonitor.onNewItem = { disabledItems.append($0) }
        disableMonitor.setConsent(.enabled)
        disablePasteboard.pngData = Data([1])
        disablePasteboard.changeCount = 21
        disableMonitor.checkClipboard()
        try await waitUntil { disableSaver.started }
        disableMonitor.setConsent(.disabled)
        try disableSaver.finish()
        try await waitUntil { disableDiscarder.count == 1 }
        try expect(disabledItems.isEmpty, "Disabled monitor accepted a late image save")
        try expect(!FileManager.default.fileExists(atPath: disablePath.path), "Stale disabled image became an orphan")

        let clearPasteboard = FakeClipboardPasteboard()
        clearPasteboard.changeCount = 30
        let clearPath = root.appendingPathComponent("stale-after-clear.png")
        let clearSaver = BlockingImageSaveScript(destination: clearPath)
        let clearDiscarder = ImageDiscardRecorder()
        var clearedItems: [StashItem] = []
        let clearMonitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: clearPasteboard,
            imageSaver: { _, _, observedAt in await clearSaver.save(observedAt: observedAt) },
            imageDiscarder: { await clearDiscarder.discard($0) }
        )
        clearMonitor.onNewItem = { clearedItems.append($0) }
        clearMonitor.setConsent(.enabled)
        clearPasteboard.pngData = Data([2])
        clearPasteboard.changeCount = 31
        clearMonitor.checkClipboard()
        try await waitUntil { clearSaver.started }

        let vmBase = root.appendingPathComponent("pending-image-clear-vm", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: vmBase.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: vmBase.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: { clearMonitor.invalidatePendingCaptures() }
        )
        viewModel.addItem(StashItem(
            type: .text,
            content: "clear existing",
            preview: "clear existing",
            managedOrigin: .clipboard
        ))
        let clearResult = await viewModel.clearUnpinnedClipboardItems()
        try expect(clearResult.removedCount == 1, "Clear did not remove existing clipboard metadata")
        try clearSaver.finish()
        try await waitUntil { clearDiscarder.count == 1 }
        try expect(clearedItems.isEmpty, "Clear accepted a late image save")
        try expect(!FileManager.default.fileExists(atPath: clearPath.path), "Stale cleared image became an orphan")
    }

    private static func testClipboardRetentionPlanner() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let equalDate = now.addingTimeInterval(-60)
        let stableLowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let stableHigherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let old = StashItem(
            type: .text,
            content: "old",
            preview: "old",
            createdAt: now.addingTimeInterval(-7 * 86_400),
            managedOrigin: .clipboard
        )
        let equalA = StashItem(
            id: stableLowerID,
            type: .url,
            content: "https://a.example",
            preview: "a",
            createdAt: equalDate,
            managedOrigin: .clipboard
        )
        let equalB = StashItem(
            id: stableHigherID,
            type: .image,
            content: "/tmp/b.png",
            preview: "b",
            createdAt: equalDate,
            managedOrigin: .clipboard
        )
        let pinned = StashItem(
            type: .text,
            content: "pinned",
            preview: "pinned",
            createdAt: .distantPast,
            isPinned: true,
            managedOrigin: .clipboard
        )
        let imported = StashItem(
            type: .text,
            content: "imported",
            preview: "imported",
            createdAt: .distantPast,
            managedOrigin: .imported
        )
        let legacy = StashItem(
            type: .image,
            content: "/tmp/legacy.png",
            preview: "legacy",
            createdAt: .distantPast,
            managedOrigin: .legacyUnknown
        )
        let removals = ClipboardRetentionPlanner.itemIDsToRemove(
            from: [equalB, imported, old, pinned, equalA, legacy],
            policy: ClipboardRetentionPolicy(maximumItemCount: 1, maximumAgeDays: 7),
            now: now
        )
        try expect(removals.contains(old.id), "Age boundary item was not expired")
        try expect(removals.contains(equalB.id), "Stable UUID tie-break did not remove the second item")
        try expect(!removals.contains(equalA.id), "Stable UUID tie-break did not retain the first item")
        try expect(!removals.contains(pinned.id), "Pinned clipboard item was expired")
        try expect(!removals.contains(imported.id), "Imported item was expired")
        try expect(!removals.contains(legacy.id), "Legacy item was expired")
    }

    @MainActor
    private static func testClipboardRetentionTimer() async throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let clock = TestClock(now: now)
        let scheduler = ManualRetentionScheduler()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashRetentionTimer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: base.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: 1),
            retentionScheduler: scheduler,
            retentionNowProvider: { clock.now },
            clipboardCaptureInvalidator: {}
        )
        let expiring = StashItem(
            type: .text,
            content: "timer-expiring",
            preview: "timer-expiring",
            createdAt: now.addingTimeInterval(-86_400 + 10),
            managedOrigin: .clipboard
        )
        viewModel.addItem(expiring)
        guard let scheduledDate = scheduler.scheduledDate else {
            throw ViewModelTestFailure.assertion("Retention timer was not scheduled")
        }
        try expect(scheduledDate > now, "Retention timer was scheduled in the past")

        clock.now = scheduledDate.addingTimeInterval(1)
        scheduler.fire()
        try await waitUntil { !viewModel.items.contains(where: { $0.id == expiring.id }) }

        let imported = StashItem(type: .text, content: "same", preview: "imported")
        let legacy = StashItem(
            type: .text,
            content: "same",
            preview: "legacy",
            managedOrigin: .legacyUnknown
        )
        let clipboard = StashItem(
            type: .text,
            content: "same",
            preview: "clipboard",
            managedOrigin: .clipboard
        )
        viewModel.updateClipboardRetentionPolicy(
            ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil)
        )
        viewModel.addItem(imported)
        viewModel.addItem(legacy)
        viewModel.addItem(clipboard)
        try expect(scheduler.scheduledDate == nil, "Unlimited age policy left a timer scheduled")
        try expect(
            viewModel.items.filter { $0.content == "same" }.count == 3,
            "Cross-origin deduplication replaced imported or legacy metadata"
        )
    }

    @MainActor
    private static func testPinIsRejectedDuringClipboardCleanup(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-pin-race", isDirectory: true)
        let blocker = BlockingQuarantineScript()
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            cleanupFaultInjector: { blocker.inject($0) }
        )
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        let image = try await fileManager.saveClipboardImage(
            data: Data([4, 5, 6]),
            fileExtension: "png",
            createdAt: oldDate
        )
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: 1),
            retentionNowProvider: { Date(timeIntervalSince1970: 2_000_000) },
            clipboardCaptureInvalidator: {}
        )
        viewModel.addItem(image)
        try await waitUntil { blocker.started }
        viewModel.togglePin(image)
        try expect(
            viewModel.lastError == "该记录正在清理，暂时无法更改固定状态",
            "Pin attempt during cleanup was not reported"
        )
        try expect(
            viewModel.items.first(where: { $0.id == image.id })?.isPinned == false,
            "Item appeared pinned while its file was being quarantined"
        )
        blocker.release.signal()
        try await waitUntil { !viewModel.items.contains(where: { $0.id == image.id }) }
        try expect(!FileManager.default.fileExists(atPath: image.content), "Cleanup did not quarantine the image")
    }

    @MainActor
    private static func testClipboardImageOrphanRecoveryRetentionClearAndRestart(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-orphan-recovery", isDirectory: true)
        let filesBase = base.appendingPathComponent("files", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: filesBase)
        let oldOrphan = try await fileManager.saveClipboardImage(data: Data([1]), fileExtension: "png")
        let freshOrphan = try await fileManager.saveClipboardImage(data: Data([2]), fileExtension: "png")
        let oldFileName = URL(fileURLWithPath: oldOrphan.content).lastPathComponent
        let freshFileName = URL(fileURLWithPath: freshOrphan.content).lastPathComponent
        let now = Date(timeIntervalSince1970: 2_200_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 86_400)],
            ofItemAtPath: oldOrphan.content
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshOrphan.content
        )
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadataBase),
            fileManager: fileManager,
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: 1),
            retentionNowProvider: { now },
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "fresh orphan recovery") {
            viewModel.items.contains(where: {
                URL(fileURLWithPath: $0.content).lastPathComponent == freshFileName
            })
        }
        try await waitUntil(description: "expired orphan quarantine") {
            !FileManager.default.fileExists(atPath: oldOrphan.content)
        }
        try expect(
            viewModel.items.first(where: {
                URL(fileURLWithPath: $0.content).lastPathComponent == freshFileName
            })?.managedOrigin == .clipboard,
            "Recovered Images orphan was not marked as clipboard"
        )
        try expect(
            !viewModel.items.contains(where: {
                URL(fileURLWithPath: $0.content).lastPathComponent == oldFileName
            }),
            "Expired recovered clipboard image survived retention"
        )

        let marker = StashItem(type: .text, content: "restart-marker", preview: "restart-marker")
        viewModel.addItem(marker)
        let clear = await viewModel.clearUnpinnedClipboardItems()
        try expect(clear.removedCount == 1 && clear.failedCount == 0, "Recovered image clear failed")
        try expect(!FileManager.default.fileExists(atPath: freshOrphan.content), "Recovered image was not quarantined")
        await viewModel.flushForTermination()

        let restarted = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadataBase),
            fileManager: fileManager,
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: 1),
            retentionNowProvider: { now },
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "clipboard cleanup persistence restart") {
            restarted.items.contains(where: { $0.id == marker.id })
        }
        try expect(
            !restarted.items.contains(where: {
                URL(fileURLWithPath: $0.content).lastPathComponent == freshFileName
            }),
            "Cleared clipboard image returned after restart"
        )
    }

    @MainActor
    private static func testPartialClipboardClear(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-clear", isDirectory: true)
        let injector = FailSelectedQuarantine()
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            cleanupFaultInjector: { try injector.inject($0) }
        )
        let firstImage = try await fileManager.saveClipboardImage(data: Data([1]), fileExtension: "png")
        let secondImage = try await fileManager.saveClipboardImage(data: Data([2]), fileExtension: "png")
        injector.select(URL(fileURLWithPath: secondImage.content))
        let text = StashItem(
            type: .text,
            content: "clipboard text",
            preview: "clipboard text",
            managedOrigin: .clipboard
        )
        let pinned = StashItem(
            type: .url,
            content: "https://pinned.example",
            preview: "pinned",
            isPinned: true,
            managedOrigin: .clipboard
        )
        let imported = StashItem(type: .text, content: "imported", preview: "imported")
        let legacy = StashItem(
            type: .text,
            content: "legacy",
            preview: "legacy",
            managedOrigin: .legacyUnknown
        )
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        [firstImage, secondImage, text, pinned, imported, legacy].forEach(viewModel.addItem)

        let result = await viewModel.clearUnpinnedClipboardItems()
        try expect(result == ClipboardClearResult(removedCount: 2, failedCount: 1), "Partial clear counts changed")
        try expect(!viewModel.items.contains(where: { $0.id == firstImage.id }), "Quarantined image metadata remained")
        try expect(viewModel.items.contains(where: { $0.id == secondImage.id }), "Failed image metadata was removed")
        try expect(!viewModel.items.contains(where: { $0.id == text.id }), "Clipboard text was not cleared")
        try expect(viewModel.items.contains(where: { $0.id == pinned.id }), "Pinned clipboard item was cleared")
        try expect(viewModel.items.contains(where: { $0.id == imported.id }), "Imported item was cleared")
        try expect(viewModel.items.contains(where: { $0.id == legacy.id }), "Legacy item was cleared")
        try expect(!FileManager.default.fileExists(atPath: firstImage.content), "Successful image was not quarantined")
        try expect(FileManager.default.fileExists(atPath: secondImage.content), "Failed image was moved anyway")
    }

    @MainActor
    private static func testCancelledRetryKeepsOriginalImportError(in root: URL) async throws {
        let base = root.appendingPathComponent("cancelled-retry", isDirectory: true)
        let storage = StorageManager(baseDirectory: base.appendingPathComponent("metadata", isDirectory: true))
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            importPolicy: testPolicy,
            availableCapacityProvider: { _ in Int64.max }
        )
        let script = RetryCancellationImportScript()
        let viewModel = StashViewModel(
            storageManager: storage,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            importHandler: { urls, token, _ in
                await script.importFiles(urls, cancellationToken: token)
            }
        )
        let source = base.appendingPathComponent("cancelled-retry.txt")

        await viewModel.importFiles([source])
        guard let failedJob = viewModel.importJobs.first,
              let originalError = viewModel.lastError else {
            throw ViewModelTestFailure.assertion("Initial retry failure did not record its error")
        }
        viewModel.retryImport(failedJob.id)

        let retryJobID = try await waitForRetryToStart(in: viewModel, originalJobID: failedJob.id)
        viewModel.cancelImport(retryJobID)
        try await waitForImports(in: viewModel, expectedJobCount: 2)

        let retryJob = viewModel.importJobs.first { $0.id == retryJobID }
        try expect(retryJob?.state == .cancelled, "Cancelled retry did not finish as cancelled")
        try expect(viewModel.lastError == originalError, "Cancelled retry cleared the original import error")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ViewModelTestFailure.assertion(message) }
    }

    @MainActor
    private static func testRetryDebounceAndErrorOwnership(in root: URL) async throws {
        let base = root.appendingPathComponent("retry", isDirectory: true)
        let storage = StorageManager(baseDirectory: base.appendingPathComponent("metadata", isDirectory: true))
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            importPolicy: testPolicy,
            availableCapacityProvider: { _ in Int64.max }
        )
        let viewModel = StashViewModel(
            storageManager: storage,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false
        )

        let sourceDirectory = base.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("retry.txt")

        await viewModel.importFiles([source])
        guard let failedJob = viewModel.importJobs.first else {
            throw ViewModelTestFailure.assertion("Initial failed job is missing")
        }
        try expect(failedJob.state == .failed, "Missing source did not create a failed job")
        try Data("retry".utf8).write(to: source)

        for _ in 0..<10 {
            viewModel.retryImport(failedJob.id)
        }
        try await waitForImports(in: viewModel, expectedJobCount: 2)

        try expect(viewModel.importJobs.count == 2, "Rapid retry created more than one task")
        let original = viewModel.importJobs.first { $0.id == failedJob.id }
        try expect(original?.state == .retrying, "Original failed task was not locked after retry")
        try expect(original?.retryURLs.isEmpty == true, "Original retry URLs were not consumed")
        try expect(viewModel.importJobs.contains { $0.retryOfJobID == failedJob.id && $0.state == .completed }, "Retry task did not complete")
        try expect(viewModel.items.count == 1, "Rapid retry produced duplicate metadata items")
        let managedFiles = try FileManager.default.contentsOfDirectory(
            at: fileManager.storageDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(managedFiles.count == 1, "Rapid retry copied the source more than once")
        try expect(viewModel.lastError == nil, "Successful retry did not clear its own import error")

        let secondSource = sourceDirectory.appendingPathComponent("retry-persistent-error.txt")
        await viewModel.importFiles([secondSource])
        guard let secondFailure = viewModel.importJobs.first, secondFailure.state == .failed else {
            throw ViewModelTestFailure.assertion("Second failed job is missing")
        }
        viewModel.lastError = "保存失败：fixture"
        try Data("second".utf8).write(to: secondSource)
        for _ in 0..<10 {
            viewModel.retryImport(secondFailure.id)
        }
        try await waitForImports(in: viewModel, expectedJobCount: 4)
        try expect(viewModel.importJobs.count == 4, "Second rapid retry created duplicate tasks")
        try expect(viewModel.lastError == "保存失败：fixture", "Successful retry cleared an unrelated persistent error")
    }

    @MainActor
    private static func testProgressCoalescesToOnePublishedMutation(in root: URL) async throws {
        let base = root.appendingPathComponent("progress", isDirectory: true)
        let storage = StorageManager(baseDirectory: base.appendingPathComponent("metadata", isDirectory: true))
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            importPolicy: testPolicy,
            availableCapacityProvider: { _ in Int64.max }
        )
        let handler: StashImportHandler = { urls, _, progress in
            for value in 1...100 {
                progress(FileImportProgress(
                    phase: .importing,
                    completedBytes: Int64(value),
                    totalBytes: 100,
                    completedItems: 0,
                    totalItems: urls.count,
                    currentItemName: urls.first?.lastPathComponent
                ))
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            return FileImportBatch(items: [], failures: [])
        }
        let viewModel = StashViewModel(
            storageManager: storage,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            importHandler: handler
        )

        var importingPublications = 0
        let observation = viewModel.$importJobs.sink { jobs in
            if jobs.first?.state == .importing {
                importingPublications += 1
            }
        }
        await viewModel.importFiles([URL(fileURLWithPath: "/tmp/progress-fixture")])
        withExtendedLifetime(observation) {}

        try expect(
            importingPublications == 1,
            "Expected one importing publication, observed \(importingPublications)"
        )
        try expect(viewModel.importJobs.first?.state == .completed, "Progress test job did not complete")
        try expect(viewModel.importJobs.first?.completedBytes == 100, "Progress relay did not keep the latest value")
    }

    @MainActor
    private static func testBootstrapMergesInputWithoutWritingEmptyState(in root: URL) async throws {
        let base = root.appendingPathComponent("bootstrap-merge", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let oldItem = StashItem(type: .text, content: "persisted", preview: "persisted")
        let seedStorage = StorageManager(baseDirectory: metadataBase)
        try seedStorage.flushSynchronously(StorageSnapshot(revision: 9, items: [oldItem], importJobs: []))

        let blockingStore = BlockingReadStorageFileStore()
        let loadingStorage = StorageManager(baseDirectory: metadataBase, fileStore: blockingStore)
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            importPolicy: testPolicy,
            availableCapacityProvider: { _ in Int64.max }
        )
        let viewModel = StashViewModel(
            storageManager: loadingStorage,
            fileManager: fileManager,
            loadOnInit: true,
            purgeOnInit: false
        )
        let newItem = StashItem(type: .text, content: "during-bootstrap", preview: "during-bootstrap")
        viewModel.addItem(newItem)

        while !blockingStore.hasStartedReading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        blockingStore.allowRead.signal()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !(viewModel.items.contains(where: { $0.id == oldItem.id })
                && viewModel.items.contains(where: { $0.id == newItem.id })) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(viewModel.items.count == 2, "Bootstrap overwrote input received during background load")
        await viewModel.flushForTermination()

        let verifyStorage = StorageManager(baseDirectory: metadataBase)
        guard case .loaded(let snapshot) = verifyStorage.loadSnapshotSynchronously() else {
            throw ViewModelTestFailure.assertion("Merged bootstrap snapshot did not persist")
        }
        try expect(snapshot.items.count == 2, "Bootstrap flush wrote an empty or stale snapshot")
        try expect(snapshot.revision > 9, "Bootstrap did not advance the stored revision")
    }

    @MainActor
    private static func testRecoveryJobsCannotBeDismissedOrTrimmed(in root: URL) async throws {
        let base = root.appendingPathComponent("recovery-job-retention", isDirectory: true)
        let storage = StorageManager(baseDirectory: base.appendingPathComponent("metadata", isDirectory: true))
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            importPolicy: testPolicy,
            availableCapacityProvider: { _ in Int64.max }
        )
        let handler: StashImportHandler = { urls, _, _ in
            let needsRecovery = urls.first?.lastPathComponent == "needs-recovery"
            return FileImportBatch(
                items: [],
                failures: [],
                cleanupFailures: needsRecovery
                    ? [FileCleanupFailure(path: "/tmp/needs-recovery.partial", message: "fixture")]
                    : []
            )
        }
        let viewModel = StashViewModel(
            storageManager: storage,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            importHandler: handler
        )
        await viewModel.importFiles([URL(fileURLWithPath: "/tmp/needs-recovery")])
        guard let recoveryJob = viewModel.importJobs.first else {
            throw ViewModelTestFailure.assertion("Recovery job was not created")
        }
        viewModel.dismissImportJob(recoveryJob.id)
        try expect(viewModel.importJobs.contains(where: { $0.id == recoveryJob.id }), "Recovery job was dismissible")

        for index in 0..<12 {
            await viewModel.importFiles([URL(fileURLWithPath: "/tmp/completed-\(index)")])
        }
        try expect(
            viewModel.importJobs.contains(where: { $0.id == recoveryJob.id && $0.needsRecovery }),
            "Recovery job was trimmed from history"
        )
    }

    @MainActor
    private static func testStorageRetryClearsOwnedErrorAndAcknowledgesManifest(in root: URL) async throws {
        let base = root.appendingPathComponent("storage-retry-manifest-ack", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let writer = VMFailOnceWriter()
        let storage = StorageManager(
            baseDirectory: metadataBase,
            debounceInterval: 0,
            retryInterval: 0.05,
            writer: { data, url in try writer.write(data, to: url) }
        )
        let filesBase = base.appendingPathComponent("files", isDirectory: true)
        let fileManager = QuickStashFileManager(
            baseDirectory: filesBase,
            importPolicy: testPolicy,
            availableCapacityProvider: { _ in Int64.max }
        )
        let viewModel = StashViewModel(
            storageManager: storage,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false
        )
        var observedSaveFailure = false
        let observation = viewModel.$lastError.sink { error in
            if error?.hasPrefix("保存失败：") == true {
                observedSaveFailure = true
            }
        }
        let sourceDirectory = base.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("retry-ack.txt")
        try Data("retry-ack".utf8).write(to: source)
        await viewModel.importFiles([source])

        let manifestsDirectory = filesBase.appendingPathComponent("QuickStash/ImportManifests", isDirectory: true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let manifests = (try? FileManager.default.contentsOfDirectory(
                at: manifestsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            if observedSaveFailure, viewModel.lastError == nil, manifests.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        withExtendedLifetime(observation) {}
        try expect(observedSaveFailure, "ViewModel did not receive the injected storage failure")
        try expect(viewModel.lastError == nil, "Automatic retry success did not clear its owned save error")
        let remainingManifests = (try? FileManager.default.contentsOfDirectory(
            at: manifestsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        try expect(remainingManifests.isEmpty, "Automatic retry success did not acknowledge import manifest")
        guard case .loaded(let snapshot) = storage.loadSnapshotSynchronously() else {
            throw ViewModelTestFailure.assertion("Retried ViewModel snapshot did not persist")
        }
        try expect(snapshot.items.count == 1, "Retried ViewModel snapshot lost imported metadata")
    }

    @MainActor
    private static func testResolvedCleanupJobIsRemovedAfterBootstrap(in root: URL) async throws {
        let base = root.appendingPathComponent("resolved-cleanup-bootstrap", isDirectory: true)
        let filesBase = base.appendingPathComponent("files", isDirectory: true)
        let appRoot = filesBase.appendingPathComponent("QuickStash", isDirectory: true)
        let filesDirectory = appRoot.appendingPathComponent("Files", isDirectory: true)
        let manifestsDirectory = appRoot.appendingPathComponent("ImportManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        let leftover = filesDirectory.appendingPathComponent("cancelled-leftover.txt")
        try Data("cancelled".utf8).write(to: leftover)
        let manifestID = UUID()
        let cleanupFailure = FileCleanupFailure(path: leftover.path, message: "previous cleanup failure")
        let manifest = ImportManifestFixture(
            id: manifestID,
            createdAt: Date(),
            sourceURLs: [URL(fileURLWithPath: "/tmp/cancelled-source")],
            currentPartialPath: nil,
            currentFinalPath: leftover.path,
            committedItems: [],
            cleanupFailures: [cleanupFailure],
            requiresCleanup: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let cleanupManifestURL = manifestsDirectory
            .appendingPathComponent("\(manifestID.uuidString).cleanup.json")
        try encoder.encode(manifest).write(to: cleanupManifestURL, options: [.atomic])

        var cleanupJob = ImportJob(sourceURLs: manifest.sourceURLs)
        cleanupJob.state = .cancelled
        cleanupJob.cleanupFailures = [cleanupFailure]
        cleanupJob.recoveryManifestID = manifestID
        let storedItem = StashItem(
            type: .file,
            content: leftover.path,
            preview: "cancelled leftover",
            isPinned: true
        )
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let seedStorage = StorageManager(baseDirectory: metadataBase)
        try seedStorage.flushSynchronously(StorageSnapshot(
            revision: 7,
            items: [storedItem],
            importJobs: [cleanupJob]
        ))

        let loadingStorage = StorageManager(baseDirectory: metadataBase)
        let fileManager = QuickStashFileManager(baseDirectory: filesBase)
        let viewModel = StashViewModel(
            storageManager: loadingStorage,
            fileManager: fileManager,
            loadOnInit: true,
            purgeOnInit: false
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let manifestExists = FileManager.default.fileExists(atPath: cleanupManifestURL.path)
            if !FileManager.default.fileExists(atPath: leftover.path),
               !viewModel.importJobs.contains(where: { $0.id == cleanupJob.id }),
               !viewModel.items.contains(where: { $0.content == leftover.path }),
               !manifestExists {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(!FileManager.default.fileExists(atPath: leftover.path), "Bootstrap did not resolve leftover cleanup")
        try expect(
            !viewModel.importJobs.contains(where: { $0.id == cleanupJob.id }),
            "Resolved cleanup job remained permanently needsRecovery"
        )
        try expect(
            !viewModel.items.contains(where: { $0.content == leftover.path }),
            "Resolved cleanup path remained as unavailable metadata"
        )
        await viewModel.flushForTermination()
        guard case .loaded(let persisted) = loadingStorage.loadSnapshotSynchronously() else {
            throw ViewModelTestFailure.assertion("Resolved cleanup snapshot did not persist")
        }
        try expect(!persisted.importJobs.contains(where: { $0.id == cleanupJob.id }), "Resolved cleanup job remained on disk")
    }

    @MainActor
    private static func waitUntil(
        timeout: TimeInterval = 5,
        description: String = "asynchronous condition",
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ViewModelTestFailure.assertion("Timed out waiting for \(description)")
    }

    @MainActor
    private static func waitForImports(
        in viewModel: StashViewModel,
        expectedJobCount: Int
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if viewModel.importJobs.count == expectedJobCount,
               !viewModel.importJobs.contains(where: { $0.state.isActive }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ViewModelTestFailure.assertion("Timed out waiting for import tasks")
    }

    @MainActor
    private static func waitForRetryToStart(
        in viewModel: StashViewModel,
        originalJobID: UUID
    ) async throws -> UUID {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let job = viewModel.importJobs.first(where: {
                $0.retryOfJobID == originalJobID && $0.state.isActive
            }) {
                return job.id
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ViewModelTestFailure.assertion("Timed out waiting for retry to start")
    }

    private static let testPolicy = ImportPolicy(
        maximumSourceItems: 100,
        maximumEntries: 1_000,
        maximumSingleItemBytes: 64 * 1_024 * 1_024,
        maximumBatchBytes: 128 * 1_024 * 1_024,
        storageQuotaBytes: 256 * 1_024 * 1_024,
        minimumFreeSpaceBytes: 0,
        diskHeadroomFraction: 0
    )
}
