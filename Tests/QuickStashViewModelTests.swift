import Foundation
import Combine
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

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
    private var storedPayloadReadCompletionCount = 0
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
    @MainActor var payloadReadCompletionCount: Int {
        lock.withLock { storedPayloadReadCompletionCount }
    }
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
        let (gate, forcedSnapshot) = lock.withLock { () -> (DispatchSemaphore?, ClipboardPayloadSnapshot?) in
            storedPayloadReadCount += 1
            activeReaders += 1
            storedMaximumConcurrentReaders = max(storedMaximumConcurrentReaders, activeReaders)
            storedReadOccurredOnMainThread = storedReadOccurredOnMainThread || Thread.isMainThread
            defer { readGate = nil }
            let snapshot = storedForcedSnapshots.isEmpty ? nil : storedForcedSnapshots.removeFirst()
            return (readGate, snapshot)
        }
        readStarted.signal()
        gate?.wait()
        return lock.withLock {
            defer {
                activeReaders -= 1
                storedPayloadReadCompletionCount += 1
            }
            if let forcedSnapshot {
                return forcedSnapshot
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

@MainActor
private final class BlockingDuplicateImagePromoter {
    private(set) var observedDates: [Date] = []
    private(set) var fingerprints: [String] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?

    var firstCallIsBlocked: Bool { firstContinuation != nil }

    func promote(fingerprint: String, observedAt: Date) async -> Bool {
        fingerprints.append(fingerprint)
        observedDates.append(observedAt)
        if observedDates.count == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return true
    }

    func releaseFirstCall() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class AsyncValidityGate {
    var isValid = true
    private(set) var checkCount = 0

    func check() -> Bool {
        checkCount += 1
        return isValid
    }
}

@MainActor
private final class ClipboardImageReservationRecorder {
    private(set) var events: [ClipboardImageReservationEvent] = []

    func record(_ event: ClipboardImageReservationEvent) {
        events.append(event)
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class SlowPNGDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var storedInvocationCount = 0

    init(delay: TimeInterval = 0.6) {
        self.delay = delay
    }

    var invocationCount: Int { lock.withLock { storedInvocationCount } }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .png else { return }
        lock.withLock { storedInvocationCount += 1 }
        Thread.sleep(forTimeInterval: delay)
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

private final class FailOnceClipboardImageSaver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int { lock.withLock { storedCallCount } }

    func save(data: Data, observedAt: Date) async throws -> StashItem {
        let attempt = lock.withLock { () -> Int in
            storedCallCount += 1
            return storedCallCount
        }
        if attempt == 1 {
            throw CocoaError(.fileWriteUnknown)
        }
        return StashItem(
            type: .image,
            content: "/tmp/retried-clipboard-image-\(data.count).png",
            preview: "retried image",
            createdAt: observedAt,
            managedOrigin: .clipboard
        )
    }
}

private final class AlwaysFailClipboardImageSaver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int { lock.withLock { storedCallCount } }

    func save() async throws -> StashItem {
        lock.withLock { storedCallCount += 1 }
        throw CocoaError(.fileWriteUnknown)
    }
}

private actor BlockingClipboardImageReader {
    private let payload: ClipboardImagePayload
    private var continuation: CheckedContinuation<ClipboardImagePayload, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private var observedCancellation = false

    init(payload: ClipboardImagePayload) {
        self.payload = payload
    }

    func read(_ path: String) async throws -> ClipboardImagePayload {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        observedCancellation = Task.isCancelled
        return result
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: payload)
    }

    func wasCancelledBeforeCompletion() -> Bool {
        observedCancellation
    }
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
        if CommandLine.arguments.contains("--expected-change-count") {
            _ = Darwin.signal(SIGTERM, SIG_IGN)
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await testRetryDebounceAndErrorOwnership(in: root)
        try await testCancelledRetryKeepsOriginalImportError(in: root)
        try await testProgressCoalescesToOnePublishedMutation(in: root)
        try await testBootstrapMergesInputWithoutWritingEmptyState(in: root)
        try await testBootstrapDuplicateAliasReplaysDelete(in: root)
        try await testBootstrapDuplicateAliasResolvesTogglePin(in: root)
        try await testBootstrapDuplicateAliasCompletesAsyncImageCopy(in: root)
        try await testBootstrapReplacesCorruptClipboardCanonicalAfterMetadataFlush(in: root)
        try await testRecoveryJobsCannotBeDismissedOrTrimmed(in: root)
        try await testStorageRetryClearsOwnedErrorAndAcknowledgesManifest(in: root)
        try await testResolvedCleanupJobIsRemovedAfterBootstrap(in: root)
        try await testClipboardConsentMigrationAndReadBoundary()
        try await testClipboardBaselineInternalWritesAndOrigins()
        try await testInternalWriteReceiptDoesNotSuppressExternalCopy()
        try await testClipboardTimerCapturesTextLinkAndImage()
        try testSystemClipboardNormalizesImageFormatsAndFallback()
        try testAutoGeneratedClipboardImageIsCapturedAsPNG()
        try await testClipboardHelperForceKillsBlockedProcessAtTimeout()
        try await testClipboardHelperSelfWatchdogTerminatesBlockedProvider()
        try await testSystemClipboardHelperTimesOutBlockedFlavorAndUsesFallback()
        try testClipboardPNGEncoderBoundariesAndMetadata()
        try await testPromisedImageFallsBackToText()
        try await testPendingImageRetryReportsTerminalError()
        try await testClipboardRetriesEmptySnapshotWithoutChangeCountAdvance()
        try await testSameCountTextUpgradesToImage()
        try await testInFlightImageBeatsProvisionalText(in: root)
        try await testCompletedTextSurvivesNewerClipboardCount(in: root)
        try await testProvisionalTextFinalizesBeforeNextCopy(in: root)
        try await testPreparedClipboardImageTransaction()
        try await testPreparedClipboardImageRejectsInvalidatedPromotion()
        try await testPreparedClipboardImageSaveCannotOutliveShutdown(in: root)
        try await testPreparedClipboardImageRevalidatesCanonical(in: root)
        try await testDuplicateImagePromotionChecksValidityAfterFileIO(in: root)
        try await testClipboardImageSurvivesLaterText(in: root)
        try await testClipboardStopRejectsLateRead()
        try await testClipboardAcceptsLateImageAfterSoftTimeout()
        try await testTimedOutImageUpgradeSurvivesNewerCopy(in: root)
        try await testLateReadCannotConsumeNewerCount()
        try await testLateTextStillWaitsForSameCountImage()
        try await testClipboardReadTimeoutRecoversForLaterCopy()
        try await testClipboardPayloadReadLaneCapAndBoundedDrain()
        try await testClipboardImageSaveRetriesTransientFailure()
        try await testClipboardImageSaveCancellationStopsRetry()
        try testSystemClipboardReadsExplicitURLType()
        try await testClipboardReaderIsSerialAndDoesNotBlockMainActor()
        try await testClipboardShutdownDrainsImageSave(in: root)
        try await testClipboardGracefulTerminationPersistsFinalTextAndURL(in: root)
        try await testClipboardGracefulTerminationDrainsLastSlowRead()
        try await testClipboardGracefulTerminationTimesOutBlockedRead()
        try await testClipboardGracefulTerminationDrainsImageSave(in: root)
        try await testPendingImageIsDiscardedAfterDisableAndClear(in: root)
        try testClipboardRetentionPlanner()
        try await testClipboardRetentionTimer()
        try await testPinIsRejectedDuringClipboardCleanup(in: root)
        try await testTerminationWaitsForManualClipboardClear(in: root)
        try await testManualDeletePreservesConcurrentDuplicateImage(in: root)
        try await testClipboardImageOrphanRecoveryRetentionClearAndRestart(in: root)
        try await testClipboardStorageAndLegacyRepublishUsePNG(in: root)
        try await testClipboardDuplicateTextAndURLPromotion(in: root)
        try await testClipboardInternalCopyPromotesOnlyAfterSuccess(in: root)
        try testClipboardImageFingerprintsUseDecodedPixels()
        try await testClipboardDuplicateImageKeepsCanonicalBacking(in: root)
        try await testClipboardAsyncImageCopyRejectsStaleCompletion(in: root)
        try await testClipboardImageCopyClaimBlocksCleanup(in: root)
        try await testClipboardDuplicateImagePromotionCoalescesWhileBlocked()
        try await testClipboardDuplicateTextURLPromotionStress(in: root)
        try await testPartialClipboardClear(in: root)

        print("QuickStash view-model tests passed")
    }

    @MainActor
    private static func testClipboardDuplicateTextAndURLPromotion(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-duplicate-text-url", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: base.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        let start = Date(timeIntervalSince1970: 10_000)
        let textID = UUID()
        let textA = StashItem(
            id: textID,
            type: .text,
            content: "alpha",
            preview: "alpha",
            createdAt: start,
            isPinned: true,
            managedOrigin: .clipboard
        )
        viewModel.addItem(textA)
        viewModel.addItem(StashItem(
            type: .text,
            content: "beta",
            preview: "beta",
            createdAt: start.addingTimeInterval(1),
            managedOrigin: .clipboard
        ))
        viewModel.addItem(StashItem(
            type: .text,
            content: "alpha",
            preview: "replacement",
            createdAt: start.addingTimeInterval(2),
            managedOrigin: .clipboard
        ))
        try expect(viewModel.items.count == 2, "Text A-B-A created a duplicate record")
        try expect(viewModel.items[0].id == textID, "Text A-B-A did not promote the original record")
        try expect(viewModel.items[0].isPinned, "Text A-B-A lost the original pin")

        let urlID = UUID()
        viewModel.addItem(StashItem(
            id: urlID,
            type: .url,
            content: "https://example.com/a",
            preview: "a",
            createdAt: start.addingTimeInterval(3),
            isPinned: true,
            managedOrigin: .clipboard
        ))
        viewModel.addItem(StashItem(
            type: .url,
            content: "https://example.com/b",
            preview: "b",
            createdAt: start.addingTimeInterval(4),
            managedOrigin: .clipboard
        ))
        viewModel.addItem(StashItem(
            type: .url,
            content: "https://example.com/a",
            preview: "replacement",
            createdAt: start.addingTimeInterval(5),
            managedOrigin: .clipboard
        ))
        try expect(viewModel.items[0].id == urlID, "URL A-B-A did not promote the original record")
        try expect(viewModel.items[0].isPinned, "URL A-B-A lost the original pin")
        try expect(viewModel.items.filter { $0.content == "https://example.com/a" }.count == 1, "URL A-B-A created a duplicate record")

        viewModel.addItem(StashItem(
            type: .url,
            content: "https://example.com/a",
            preview: "imported",
            createdAt: start.addingTimeInterval(6),
            managedOrigin: .imported
        ))
        try expect(
            viewModel.items.filter { $0.content == "https://example.com/a" }.count == 2,
            "Clipboard duplicate matching crossed origin boundaries"
        )
    }

    @MainActor
    private static func testClipboardInternalCopyPromotesOnlyAfterSuccess(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-copy-promotion", isDirectory: true)
        var shouldWrite = false
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: base.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {},
            clipboardTextWriter: { _ in shouldWrite }
        )
        let start = Date(timeIntervalSince1970: 20_000)
        let first = StashItem(type: .text, content: "first", preview: "first", createdAt: start, isPinned: true, managedOrigin: .clipboard)
        let second = StashItem(type: .text, content: "second", preview: "second", createdAt: start.addingTimeInterval(1), managedOrigin: .clipboard)
        viewModel.addItem(first)
        viewModel.addItem(second)

        viewModel.copyToClipboard(first)
        try expect(viewModel.items[0].id == second.id, "Failed internal write promoted clipboard history")
        try expect(viewModel.lastError != nil, "Failed internal write did not report an error")

        shouldWrite = true
        viewModel.copyToClipboard(first)
        try expect(viewModel.items[0].id == first.id, "Successful internal write did not promote clipboard history")
        try expect(viewModel.items[0].isPinned, "Internal-copy promotion lost the original pin")
    }

    @MainActor
    private static func testClipboardImageFingerprintsUseDecodedPixels() throws {
        let png = try makeBitmapImageData(width: 32, height: 24, fileType: .png, isOpaque: true)
        let tiff = try makeBitmapImageData(width: 32, height: 24, fileType: .tiff, isOpaque: true)
        let different = try makeBitmapImageData(width: 33, height: 24, fileType: .png, isOpaque: true)
        let pngFingerprint = try ClipboardPNGEncoder.fingerprint(from: png)
        let tiffFingerprint = try ClipboardPNGEncoder.fingerprint(from: tiff)
        let differentFingerprint = try ClipboardPNGEncoder.fingerprint(from: different)
        try expect(
            pngFingerprint == tiffFingerprint,
            "Same-pixel PNG and TIFF produced different fingerprints"
        )
        try expect(
            pngFingerprint != differentFingerprint,
            "Different image pixels produced the same fingerprint"
        )
    }

    @MainActor
    private static func testClipboardDuplicateImageKeepsCanonicalBacking(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-image-dedup", isDirectory: true)
        let quarantineFailure = FailSelectedQuarantine()
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files"),
            cleanupFaultInjector: { try quarantineFailure.inject($0) }
        )
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        let pixels = try makeBitmapImageData(width: 48, height: 36, fileType: .png)
        let canonical = try await fileManager.saveClipboardImage(data: pixels, fileExtension: "png")
        var pinnedCanonical = canonical
        pinnedCanonical.isPinned = true
        viewModel.addItem(pinnedCanonical)
        let duplicate = try await fileManager.saveClipboardImage(data: pixels, fileExtension: "png")
        viewModel.addItem(duplicate)

        try expect(viewModel.items.count == 1, "Same-pixel image created a duplicate history record")
        try expect(viewModel.items[0].id == canonical.id, "Duplicate image replaced the canonical ID")
        try expect(viewModel.items[0].content == canonical.content, "Duplicate image replaced the canonical backing path")
        try expect(viewModel.items[0].isPinned, "Duplicate image lost the canonical pin")
        try await waitUntil(description: "duplicate image backing deletion") {
            !FileManager.default.fileExists(atPath: duplicate.content)
        }
        try expect(FileManager.default.fileExists(atPath: canonical.content), "Duplicate cleanup deleted the canonical image")

        let differentPixels = try makeBitmapImageData(width: 49, height: 36, fileType: .png)
        let different = try await fileManager.saveClipboardImage(data: differentPixels, fileExtension: "png")
        viewModel.addItem(different)
        try expect(viewModel.items.count == 2, "Different image pixels were incorrectly deduplicated")

        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: URL(fileURLWithPath: canonical.content),
            options: .atomic
        )
        let promotedCorrupt = await viewModel.promoteDuplicateClipboardImage(
            fingerprint: canonical.contentFingerprint ?? "",
            observedAt: Date()
        )
        try expect(!promotedCorrupt, "Corrupt canonical image was incorrectly considered reusable")
        try expect(
            viewModel.items.first(where: { $0.id == canonical.id })?.availability == .unavailable,
            "Corrupt canonical image was not marked unavailable"
        )

        let replacement = try await fileManager.saveClipboardImage(data: pixels, fileExtension: "png")
        quarantineFailure.select(URL(fileURLWithPath: canonical.content))
        viewModel.addItem(replacement)
        try await waitUntil(description: "valid replacement backing commit") {
            viewModel.items.contains(where: {
                $0.id == canonical.id && $0.content == replacement.content
            })
        }
        guard let repaired = viewModel.items.first(where: { $0.id == canonical.id }) else {
            throw ViewModelTestFailure.assertion("Replacement image lost the canonical history ID")
        }
        try expect(repaired.content == replacement.content, "Valid replacement did not take over the corrupt backing path")
        try expect(repaired.availability == .available, "Valid replacement remained unavailable")
        try expect(repaired.isPinned, "Valid replacement lost the canonical pin")
        try await waitUntil(description: "replaced corrupt backing deletion") {
            !FileManager.default.fileExists(atPath: canonical.content)
        }
        let replacementIsReusable = await fileManager.isReusableClipboardImage(
            at: repaired.content,
            matching: repaired.contentFingerprint ?? ""
        )
        try expect(
            replacementIsReusable,
            "Replacement backing did not pass decoded fingerprint validation"
        )
    }

    @MainActor
    private static func testClipboardAsyncImageCopyRejectsStaleCompletion(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-stale-image-copy", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: base.appendingPathComponent("files"))
        let image = try await fileManager.saveClipboardImage(
            data: try makeBitmapImageData(width: 40, height: 30, fileType: .png),
            fileExtension: "png"
        )
        let imageReader = BlockingClipboardImageReader(
            payload: try await fileManager.readManagedImage(at: image.content)
        )
        var imageWriteCount = 0
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {},
            clipboardTextWriter: { _ in true },
            clipboardImageReader: { path in
                try await imageReader.read(path)
            },
            clipboardImageWriter: { _ in
                imageWriteCount += 1
                return true
            }
        )
        let text = StashItem(type: .text, content: "newer", preview: "newer", managedOrigin: .clipboard)
        viewModel.addItem(image)
        viewModel.addItem(text)
        viewModel.copyToClipboard(image)
        await imageReader.waitUntilStarted()
        viewModel.copyToClipboard(text)
        await imageReader.finish()
        await viewModel.flushForTermination()

        let imageReadWasCancelled = await imageReader.wasCancelledBeforeCompletion()
        try expect(
            imageReadWasCancelled,
            "Newer clipboard copy did not cancel the pending image read"
        )
        try expect(imageWriteCount == 0, "Stale async image copy wrote over the newer clipboard value")
        try expect(viewModel.items[0].id == text.id, "Stale async image copy promoted old history")
    }

    @MainActor
    private static func testClipboardImageCopyClaimBlocksCleanup(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-image-copy-claim", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: base.appendingPathComponent("files"))
        let image = try await fileManager.saveClipboardImage(
            data: try makeBitmapImageData(width: 44, height: 33, fileType: .png),
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 60_000)
        )
        let imageReader = BlockingClipboardImageReader(
            payload: try await fileManager.readManagedImage(at: image.content)
        )
        var imageWriteCount = 0
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {},
            clipboardImageReader: { path in try await imageReader.read(path) },
            clipboardImageWriter: { _ in
                imageWriteCount += 1
                return true
            }
        )
        let newerText = StashItem(
            type: .text,
            content: "newer-than-image",
            preview: "newer-than-image",
            createdAt: Date(timeIntervalSince1970: 60_001),
            managedOrigin: .clipboard
        )
        viewModel.addItem(image)
        viewModel.addItem(newerText)
        viewModel.copyToClipboard(image)
        await imageReader.waitUntilStarted()

        viewModel.deleteItem(image)
        try expect(
            viewModel.lastError == "该记录正在复制，暂时无法删除",
            "Manual delete was not rejected while an image copy was in flight"
        )
        viewModel.updateClipboardRetentionPolicy(
            ClipboardRetentionPolicy(maximumItemCount: 1, maximumAgeDays: nil)
        )
        try expect(viewModel.items.count == 2, "Retention removed an actively copied image")
        try expect(FileManager.default.fileExists(atPath: image.content), "Active copy backing was quarantined")

        await imageReader.finish()
        try await waitUntil(description: "successful claimed image copy") {
            imageWriteCount == 1
                && viewModel.items.count == 1
                && viewModel.items.first?.id == image.id
        }
        try expect(viewModel.items[0].createdAt > newerText.createdAt, "Claimed image copy was not promoted")
        try expect(FileManager.default.fileExists(atPath: image.content), "Promoted image backing was removed")
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testClipboardDuplicateImagePromotionCoalescesWhileBlocked() async throws {
        let suite = "QuickStashTests.clipboard.image-coalesce.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create duplicate-image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        let promoter = BlockingDuplicateImagePromoter()
        let reservations = ClipboardImageReservationRecorder()
        let saveCounter = LockedInvocationCounter()
        let newItemCounter = LockedInvocationCounter()
        pasteboard.changeCount = 4_000
        pasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in
                saveCounter.increment()
                throw CocoaError(.fileWriteUnknown)
            },
            imageFingerprinter: { _ in "same-fingerprint" },
            imageReservationObserver: { event in reservations.record(event) }
        )
        monitor.onPromoteDuplicateImage = { fingerprint, observedAt, isStillValid in
            let promoted = await promoter.promote(fingerprint: fingerprint, observedAt: observedAt)
            return isStillValid() && promoted
        }
        monitor.onNewItem = { _ in newItemCounter.increment() }
        monitor.setConsent(.enabled)

        let firstObservedAt = Date(timeIntervalSince1970: 40_001)
        let secondObservedAt = Date(timeIntervalSince1970: 40_002)
        let thirdObservedAt = Date(timeIntervalSince1970: 40_003)
        pasteboard.changeCount = 4_001
        monitor.checkClipboard(observedAt: firstObservedAt)
        try await waitUntil(description: "first duplicate promotion blocked") {
            promoter.firstCallIsBlocked
                && reservations.events == [
                    .reserved(fingerprint: "same-fingerprint", changeCount: 4_001)
                ]
        }

        pasteboard.changeCount = 4_002
        monitor.checkClipboard(observedAt: secondObservedAt)
        try await waitUntil(description: "second duplicate image reservation") {
            reservations.events == [
                .reserved(fingerprint: "same-fingerprint", changeCount: 4_001),
                .coalesced(fingerprint: "same-fingerprint", changeCount: 4_002)
            ]
        }
        pasteboard.changeCount = 4_003
        monitor.checkClipboard(observedAt: thirdObservedAt)
        try await waitUntil(description: "all duplicate image reservations") {
            reservations.events == [
                .reserved(fingerprint: "same-fingerprint", changeCount: 4_001),
                .coalesced(fingerprint: "same-fingerprint", changeCount: 4_002),
                .coalesced(fingerprint: "same-fingerprint", changeCount: 4_003)
            ]
        }
        try expect(promoter.observedDates.count == 1, "Concurrent duplicate images bypassed the blocked promotion")

        promoter.releaseFirstCall()
        try await waitUntil(description: "coalesced duplicate promotion completion") {
            reservations.events.last == .released(fingerprint: "same-fingerprint")
        }
        try expect(
            promoter.observedDates == [firstObservedAt, thirdObservedAt],
            "Coalesced promotion did not use the latest observed time"
        )
        try expect(
            promoter.fingerprints == ["same-fingerprint", "same-fingerprint"],
            "Promoter received an unexpected image fingerprint"
        )
        try expect(promoter.observedDates.count == 2, "Duplicate image requests were not coalesced")
        try expect(saveCounter.value == 0, "Promoted duplicate image unexpectedly invoked imageSaver")
        try expect(newItemCounter.value == 0, "Promoted duplicate image unexpectedly emitted onNewItem")

        await monitor.shutdownAndDrain()
        try expect(saveCounter.value == 0, "Shutdown restarted a coalesced image save")

        let shutdownPasteboard = FakeClipboardPasteboard()
        let shutdownPromoter = BlockingDuplicateImagePromoter()
        let shutdownReservations = ClipboardImageReservationRecorder()
        let shutdownSaveCounter = LockedInvocationCounter()
        let shutdownNewItemCounter = LockedInvocationCounter()
        shutdownPasteboard.changeCount = 5_000
        shutdownPasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let shutdownMonitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: shutdownPasteboard,
            imageSaver: { _, _, _ in
                shutdownSaveCounter.increment()
                throw CocoaError(.fileWriteUnknown)
            },
            imageFingerprinter: { _ in "shutdown-fingerprint" },
            imageReservationObserver: { event in shutdownReservations.record(event) }
        )
        shutdownMonitor.onPromoteDuplicateImage = { fingerprint, observedAt, isStillValid in
            let promoted = await shutdownPromoter.promote(fingerprint: fingerprint, observedAt: observedAt)
            return isStillValid() && promoted
        }
        shutdownMonitor.onNewItem = { _ in shutdownNewItemCounter.increment() }
        shutdownMonitor.setConsent(.enabled)

        shutdownPasteboard.changeCount = 5_001
        shutdownMonitor.checkClipboard(observedAt: Date(timeIntervalSince1970: 50_001))
        try await waitUntil(description: "shutdown duplicate promotion blocked") {
            shutdownPromoter.firstCallIsBlocked
                && shutdownReservations.events == [
                    .reserved(fingerprint: "shutdown-fingerprint", changeCount: 5_001)
                ]
        }

        let shutdownTask = Task { await shutdownMonitor.shutdownAndDrain() }
        try await waitUntil(description: "shutdown reservation invalidation") {
            shutdownReservations.events.last == .released(fingerprint: "shutdown-fingerprint")
        }
        try expect(shutdownPromoter.firstCallIsBlocked, "Shutdown test released the promoter prematurely")
        shutdownPromoter.releaseFirstCall()
        await shutdownTask.value

        try expect(shutdownSaveCounter.value == 0, "Shutdown allowed a blocked duplicate image save")
        try expect(shutdownNewItemCounter.value == 0, "Shutdown published a blocked duplicate image")
        try expect(
            shutdownReservations.events == [
                .reserved(fingerprint: "shutdown-fingerprint", changeCount: 5_001),
                .released(fingerprint: "shutdown-fingerprint")
            ],
            "Shutdown left or recreated a duplicate-image reservation"
        )
    }

    @MainActor
    private static func testClipboardDuplicateTextURLPromotionStress(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-duplicate-text-url-stress", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: base.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {},
            clipboardTextWriter: { _ in true }
        )
        let textID = UUID()
        let urlID = UUID()
        let text = StashItem(
            id: textID,
            type: .text,
            content: "stress-text",
            preview: "stress-text",
            createdAt: Date(timeIntervalSince1970: 30_000),
            isPinned: true,
            managedOrigin: .clipboard
        )
        let url = StashItem(
            id: urlID,
            type: .url,
            content: "https://example.com/stress",
            preview: "stress-url",
            createdAt: Date(timeIntervalSince1970: 30_001),
            isPinned: true,
            managedOrigin: .clipboard
        )
        viewModel.addItem(text)
        viewModel.addItem(url)

        for iteration in 0..<100 {
            let canonical = iteration.isMultiple(of: 2) ? text : url
            viewModel.addItem(StashItem(
                type: canonical.type,
                content: canonical.content,
                preview: "duplicate-\(iteration)",
                createdAt: Date(timeIntervalSince1970: 31_000 + Double(iteration)),
                managedOrigin: .clipboard
            ))
            guard let retained = viewModel.items.first(where: { $0.content == canonical.content }) else {
                throw ViewModelTestFailure.assertion("Stress promotion lost \(canonical.content)")
            }
            viewModel.copyToClipboard(retained)
            guard let promoted = viewModel.items.first(where: { $0.id == canonical.id }) else {
                throw ViewModelTestFailure.assertion("Stress promotion lost the canonical item")
            }
            try expect(
                viewModel.items.filter { $0.type == canonical.type && $0.content == canonical.content }.count == 1,
                "Stress promotion duplicated \(canonical.type.rawValue) at iteration \(iteration)"
            )
            try expect(retained.id == canonical.id, "Stress promotion replaced the original ID")
            try expect(promoted.isPinned, "Stress promotion lost the original pin")
            try expect(viewModel.items[0].id == canonical.id, "Stress promotion produced the wrong front item")
        }

        try expect(viewModel.items.count == 2, "Stress promotion changed the number of clipboard records")
        try expect(viewModel.items[0].id == urlID, "Final stress ordering did not reflect the last URL promotion")
        try expect(viewModel.items[1].id == textID, "Final stress ordering changed the text record")
    }

    private static func testClipboardHelperForceKillsBlockedProcessAtTimeout() async throws {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let client = ClipboardPasteboardHelperClient(
            executableURL: executableURL,
            readTimeout: 0.1
        )
        let startedAt = Date()
        let result = await Task.detached {
            client.read(
                pasteboardName: NSPasteboard.Name.general.rawValue,
                type: NSPasteboard.PasteboardType.png.rawValue,
                expectedChangeCount: 0,
                mode: .data,
                maximumBytes: 1_024
            )
        }.value
        guard case .timedOut = result else {
            throw ViewModelTestFailure.assertion("Blocked clipboard helper was not terminated at timeout")
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        try expect(elapsed >= 0.15, "Blocked clipboard helper exited before the SIGKILL grace period")
        try expect(
            elapsed < 1,
            "Blocked clipboard helper did not terminate promptly"
        )
    }

    @MainActor
    private static func testClipboardHelperSelfWatchdogTerminatesBlockedProvider() async throws {
        guard let helperPath = ProcessInfo.processInfo.environment[
            ClipboardPasteboardHelperClient.executablePathEnvironmentKey
        ], FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw ViewModelTestFailure.assertion("Compiled clipboard helper is unavailable to watchdog test")
        }

        let pasteboard = NSPasteboard.withUniqueName()
        let provider = SlowPNGDataProvider()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        pasteboard.clearContents()
        try expect(pasteboard.writeObjects([item]), "Could not publish self-watchdog provider fixture")
        let arguments = [
            "--pasteboard-name", pasteboard.name.rawValue,
            "--type", NSPasteboard.PasteboardType.png.rawValue,
            "--expected-change-count", String(pasteboard.changeCount),
            "--mode", ClipboardPasteboardHelperMode.data.rawValue,
            "--maximum-bytes", "1024",
            "--self-timeout-milliseconds", "300"
        ]
        let status = try await Task.detached { () throws -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        try expect(status == 14, "Clipboard helper self-watchdog did not return exit status 14")
        try expect(provider.invocationCount > 0, "Self-watchdog provider fixture was not requested")
    }

    @MainActor
    private static func makeBitmapImageData(
        width: Int = 64,
        height: Int = 48,
        fileType: NSBitmapImageRep.FileType,
        isOpaque: Bool = false
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bytes = bitmap.bitmapData else {
            throw ViewModelTestFailure.assertion("Could not create bitmap fixture")
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8((x * 3) % 255)
                bytes[offset + 1] = UInt8((y * 5) % 255)
                bytes[offset + 2] = 160
                bytes[offset + 3] = isOpaque ? 255 : UInt8(128 + ((x + y) % 127))
            }
        }
        let properties: [NSBitmapImageRep.PropertyKey: Any] = fileType == .jpeg
            ? [.compressionFactor: 0.95]
            : [:]
        guard let data = bitmap.representation(using: fileType, properties: properties) else {
            throw ViewModelTestFailure.assertion("Could not encode bitmap fixture")
        }
        return data
    }

    @MainActor
    private static func makeImageIOData(
        width: Int,
        height: Int,
        type: UTType,
        orientation: Int = 1
    ) throws -> Data {
        let jpegData = try makeBitmapImageData(width: width, height: height, fileType: .jpeg)
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ViewModelTestFailure.assertion("Could not decode ImageIO source fixture")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ViewModelTestFailure.assertion("Could not create \(type.identifier) fixture destination")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ViewModelTestFailure.assertion("Could not encode \(type.identifier) fixture")
        }
        return output as Data
    }

    @MainActor
    private static func makeAlphaTIFFData() throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bytes = bitmap.bitmapData else {
            throw ViewModelTestFailure.assertion("Could not create alpha TIFF fixture")
        }
        let alphaValues: [UInt8] = [0, 64, 128, 255]
        for (x, alpha) in alphaValues.enumerated() {
            let offset = x * 4
            bytes[offset] = 40
            bytes[offset + 1] = 120
            bytes[offset + 2] = 220
            bytes[offset + 3] = alpha
        }
        guard let data = bitmap.representation(using: .tiff, properties: [:]) else {
            throw ViewModelTestFailure.assertion("Could not encode alpha TIFF fixture")
        }
        return data
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
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
        try expect(pasteboard.payloadReadCount == 1, "Stable external clipboard text was read more than once")
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
        let pngFixture = try makeBitmapImageData(fileType: .png)
        let tiffFixture = try makeBitmapImageData(fileType: .tiff)
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            pollingInterval: 0.05,
            imageSaver: { data, _, observedAt in
                let pngData = try ClipboardPNGEncoder.pngData(from: data)
                return StashItem(
                    type: .image,
                    content: "/tmp/timer-image-\(pngData.count).png",
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
        pasteboard.pngData = pngFixture
        pasteboard.changeCount = 103
        try await waitUntil { received.count == 3 }
        try expect(received[2].type == .image, "Timer did not capture a clipboard image")

        pasteboard.pngData = nil
        pasteboard.tiffData = tiffFixture
        pasteboard.changeCount = 104
        try await waitUntil { received.count == 4 }
        try expect(received[3].type == .image, "Timer did not capture a TIFF clipboard image")
        try expect(received[3].content.hasSuffix(".png"), "TIFF clipboard image was not normalized to PNG")
        try expect(received.allSatisfy { $0.managedOrigin == .clipboard }, "Timer changed clipboard origins")
    }

    @MainActor
    private static func testSystemClipboardNormalizesImageFormatsAndFallback() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let tiffData = try makeBitmapImageData(width: 128, height: 96, fileType: .tiff)
        let expectedPNG = try ClipboardPNGEncoder.pngData(from: tiffData)
        try expect(tiffData.count > expectedPNG.count, "TIFF fixture was not larger than normalized PNG")

        let tiffReceipt = pasteboard.declareTypes([.png, .tiff], owner: nil)
        try expect(pasteboard.setData(tiffData, forType: .tiff), "Named pasteboard rejected TIFF fixture")
        try expect(pasteboard.changeCount == tiffReceipt, "TIFF fixture changed its declaration receipt")
        let tiffSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: expectedPNG.count,
            maximumTextCharacters: 1_024
        )
        guard let tiffSnapshot,
              case .image(let normalizedTIFF, let tiffExtension) = tiffSnapshot.payload else {
            throw ViewModelTestFailure.assertion("Unavailable PNG flavor did not fall back to TIFF")
        }
        try expect(tiffExtension == "png", "TIFF fallback did not report PNG storage")
        try expect(isPNG(normalizedTIFF), "TIFF fallback did not produce PNG bytes")
        let tiffBitmap = NSBitmapImageRep(data: normalizedTIFF)
        try expect(
            tiffBitmap?.pixelsWide == 128 && tiffBitmap?.pixelsHigh == 96,
            "TIFF normalization changed physical pixel dimensions"
        )

        let jpegData = try makeBitmapImageData(width: 73, height: 41, fileType: .jpeg)
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        _ = pasteboard.declareTypes([jpegType], owner: nil)
        try expect(pasteboard.setData(jpegData, forType: jpegType), "Named pasteboard rejected JPEG fixture")
        let jpegSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let jpegSnapshot,
              case .image(let normalizedJPEG, let jpegExtension) = jpegSnapshot.payload else {
            throw ViewModelTestFailure.assertion("JPEG-only pasteboard image was not captured")
        }
        try expect(jpegExtension == "png", "JPEG-only image did not report PNG storage")
        try expect(isPNG(normalizedJPEG), "JPEG-only image did not produce PNG bytes")
        let jpegBitmap = NSBitmapImageRep(data: normalizedJPEG)
        try expect(
            jpegBitmap?.pixelsWide == 73 && jpegBitmap?.pixelsHigh == 41,
            "JPEG normalization changed physical pixel dimensions"
        )

        let oversizedPreferredPNG = try makeBitmapImageData(width: 512, height: 512, fileType: .png)
        try expect(
            oversizedPreferredPNG.count > expectedPNG.count,
            "Preferred PNG fixture was not larger than its TIFF fallback"
        )
        _ = pasteboard.declareTypes([.png, .tiff], owner: nil)
        try expect(
            pasteboard.setData(oversizedPreferredPNG, forType: .png),
            "Named pasteboard rejected oversized preferred PNG"
        )
        try expect(pasteboard.setData(tiffData, forType: .tiff), "Named pasteboard rejected TIFF fallback")
        let oversizedPreferredSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: expectedPNG.count,
            maximumTextCharacters: 1_024
        )
        guard let oversizedPreferredSnapshot,
              case .image(let fallbackPNG, _) = oversizedPreferredSnapshot.payload else {
            throw ViewModelTestFailure.assertion("Oversized preferred PNG prevented a valid TIFF fallback")
        }
        try expect(isPNG(fallbackPNG), "Oversized preferred PNG fallback did not produce PNG bytes")

        _ = pasteboard.declareTypes([.png, .tiff], owner: nil)
        try expect(
            pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png),
            "Named pasteboard rejected invalid preferred PNG"
        )
        let pendingFallbackSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let pendingFallbackSnapshot,
              case .pendingImage = pendingFallbackSnapshot.payload else {
            throw ViewModelTestFailure.assertion(
                "Invalid preferred flavor rejected an image before its declared fallback materialized"
            )
        }
        let pendingFallbackCount = pasteboard.changeCount
        try expect(
            pasteboard.setData(tiffData, forType: .tiff),
            "Named pasteboard rejected delayed TIFF fallback"
        )
        try expect(
            pasteboard.changeCount == pendingFallbackCount,
            "Delayed TIFF fallback unexpectedly changed the pasteboard generation"
        )
        let materializedFallbackSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let materializedFallbackSnapshot,
              case .image(let materializedFallback, let materializedExtension) = materializedFallbackSnapshot.payload else {
            throw ViewModelTestFailure.assertion("Delayed same-count TIFF fallback was not captured")
        }
        try expect(
            materializedExtension == "png" && isPNG(materializedFallback),
            "Delayed TIFF fallback was not normalized to PNG"
        )

        guard let webPData = Data(base64Encoded:
            "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEALmk0mk0iIiIiIgBoSygABc6zbAAA"
        ) else {
            throw ViewModelTestFailure.assertion("Could not decode embedded WebP fixture")
        }
        let additionalFormats: [(UTType, Data, Int, Int)] = [
            (.heic, try makeImageIOData(width: 37, height: 29, type: .heic), 37, 29),
            (.webP, webPData, 1, 1)
        ]
        for (type, sourceData, width, height) in additionalFormats {
            let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
            _ = pasteboard.declareTypes([pasteboardType], owner: nil)
            try expect(
                pasteboard.setData(sourceData, forType: pasteboardType),
                "Named pasteboard rejected \(type.identifier) fixture"
            )
            let snapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
                maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
                maximumTextCharacters: 1_024
            )
            guard let snapshot,
                  case .image(let normalizedData, let fileExtension) = snapshot.payload else {
                throw ViewModelTestFailure.assertion("\(type.identifier)-only image was not captured")
            }
            let bitmap = NSBitmapImageRep(data: normalizedData)
            try expect(fileExtension == "png" && isPNG(normalizedData), "\(type.identifier) was not normalized to PNG")
            try expect(
                bitmap?.pixelsWide == width && bitmap?.pixelsHigh == height,
                "\(type.identifier) normalization changed pixel dimensions"
            )
        }

        _ = pasteboard.declareTypes([.png, .string], owner: nil)
        try expect(
            pasteboard.setString("https://fallback.example", forType: .string),
            "Named pasteboard rejected promised-image fallback text"
        )
        let promisedImageSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let promisedImageSnapshot,
              case .pendingImage(let fallbackText, _) = promisedImageSnapshot.payload else {
            throw ViewModelTestFailure.assertion("Unavailable promised image did not retain fallback text")
        }
        try expect(fallbackText == "https://fallback.example", "Promised image fallback text changed")

        _ = pasteboard.declareTypes([.png, .string], owner: nil)
        try expect(
            pasteboard.setData(Data([1, 2, 3, 4]), forType: .png),
            "Named pasteboard rejected invalid PNG text-fallback fixture"
        )
        let delayedTextCount = pasteboard.changeCount
        let delayedTextPending = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let delayedTextPending,
              case .pendingImage = delayedTextPending.payload else {
            throw ViewModelTestFailure.assertion("Unavailable text flavor did not keep an invalid image event pending")
        }
        try expect(
            pasteboard.setString("same-count delayed text", forType: .string),
            "Named pasteboard rejected delayed text fallback"
        )
        try expect(
            pasteboard.changeCount == delayedTextCount,
            "Delayed text fallback unexpectedly changed the pasteboard generation"
        )
        let delayedTextSnapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let delayedTextSnapshot,
              case .text(let delayedText) = delayedTextSnapshot.payload,
              delayedText == "same-count delayed text" else {
            throw ViewModelTestFailure.assertion("Invalid image permanently suppressed its delayed text fallback")
        }
    }

    @MainActor
    private static func testAutoGeneratedClipboardImageIsCapturedAsPNG() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sourceTIFF = try makeBitmapImageData(width: 91, height: 57, fileType: .tiff)
        let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        _ = pasteboard.declareTypes([.tiff, autoGeneratedType], owner: nil)
        try expect(pasteboard.setData(sourceTIFF, forType: .tiff), "Named pasteboard rejected TIFF fixture")
        try expect(
            pasteboard.setData(Data(), forType: autoGeneratedType),
            "Named pasteboard rejected auto-generated marker"
        )

        let snapshot = SystemClipboardPasteboard(pasteboard: pasteboard).readPayloadSnapshot(
            maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
            maximumTextCharacters: 1_024
        )
        guard let snapshot,
              case .image(let normalizedData, let fileExtension) = snapshot.payload else {
            throw ViewModelTestFailure.assertion(
                "Auto-generated marker incorrectly suppressed a valid clipboard image"
            )
        }
        try expect(fileExtension == "png", "Auto-generated clipboard image did not use PNG storage")
        try expect(isPNG(normalizedData), "Auto-generated clipboard image bytes were not PNG")
    }

    @MainActor
    private static func testSystemClipboardHelperTimesOutBlockedFlavorAndUsesFallback() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = SlowPNGDataProvider(delay: 2)
        defer { pasteboard.releaseGlobally() }
        let tiffData = try makeBitmapImageData(width: 61, height: 47, fileType: .tiff)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        try expect(item.setData(tiffData, forType: .tiff), "Could not attach ready TIFF fallback")
        pasteboard.clearContents()
        try expect(pasteboard.writeObjects([item]), "Could not publish blocking PNG provider fixture")

        let reader = SystemClipboardPasteboard(pasteboard: pasteboard)
        let (snapshot, readDuration) = await Task.detached {
            let startedAt = Date()
            let snapshot = reader.readPayloadSnapshot(
                maximumImageBytes: ClipboardPNGEncoder.maximumOutputBytes,
                maximumTextCharacters: 1_024
            )
            return (snapshot, Date().timeIntervalSince(startedAt))
        }.value
        try expect(readDuration < 1.5, "Blocked image provider exceeded helper timeout")
        try expect(provider.invocationCount > 0, "Blocked image provider fixture was not requested")
        guard let snapshot,
              case .image(let normalizedData, let fileExtension) = snapshot.payload else {
            throw ViewModelTestFailure.assertion("Blocked PNG provider prevented a ready TIFF fallback")
        }
        let bitmap = NSBitmapImageRep(data: normalizedData)
        try expect(fileExtension == "png" && isPNG(normalizedData), "Blocked flavor fallback was not PNG")
        try expect(
            bitmap?.pixelsWide == 61 && bitmap?.pixelsHigh == 47,
            "Blocked flavor fallback changed physical pixel dimensions"
        )
    }

    @MainActor
    private static func testClipboardPNGEncoderBoundariesAndMetadata() throws {
        let alphaTIFF = try makeAlphaTIFFData()
        let alphaPNG = try ClipboardPNGEncoder.pngData(from: alphaTIFF)
        guard let alphaBitmap = NSBitmapImageRep(data: alphaPNG) else {
            throw ViewModelTestFailure.assertion("Could not decode normalized alpha PNG")
        }
        let expectedAlpha: [Double] = [0, 64, 128, 255]
        for (x, expected) in expectedAlpha.enumerated() {
            guard let actual = alphaBitmap.colorAt(x: x, y: 0)?.alphaComponent else {
                throw ViewModelTestFailure.assertion("Could not inspect normalized alpha pixel")
            }
            try expect(
                abs((actual * 255) - expected) <= 1.5,
                "TIFF-to-PNG normalization changed alpha at pixel \(x)"
            )
        }

        let orientedJPEG = try makeImageIOData(width: 40, height: 20, type: .jpeg, orientation: 6)
        let orientedPNG = try ClipboardPNGEncoder.pngData(from: orientedJPEG)
        let orientedBitmap = NSBitmapImageRep(data: orientedPNG)
        try expect(
            orientedBitmap?.pixelsWide == 20 && orientedBitmap?.pixelsHigh == 40,
            "EXIF orientation was not applied while normalizing to PNG"
        )

        let pngData = try makeBitmapImageData(fileType: .png)
        do {
            _ = try ClipboardPNGEncoder.pngData(
                from: pngData,
                maximumOutputBytes: pngData.count - 1
            )
            throw ViewModelTestFailure.assertion("PNG output limit accepted an oversized result")
        } catch ClipboardPNGEncodingError.outputTooLarge {
            // Expected.
        }

        do {
            try ClipboardPNGEncoder.validateDimensions(
                width: ClipboardPNGEncoder.maximumPixelDimension + 1,
                height: 1
            )
            throw ViewModelTestFailure.assertion("PNG encoder accepted an excessive pixel dimension")
        } catch ClipboardPNGEncodingError.dimensionsTooLarge {
            // Expected.
        }

        do {
            try ClipboardPNGEncoder.validateDimensions(width: 8_192, height: 8_193)
            throw ViewModelTestFailure.assertion("PNG encoder accepted an excessive decoded-memory estimate")
        } catch ClipboardPNGEncodingError.dimensionsTooLarge {
            // Expected.
        }

        do {
            _ = try ClipboardPNGEncoder.pngData(from: Data([1, 2, 3, 4]))
            throw ViewModelTestFailure.assertion("PNG encoder accepted invalid image bytes")
        } catch ClipboardPNGEncodingError.invalidImage {
            // Expected.
        }

        do {
            _ = try ClipboardPNGEncoder.pngData(from: Data(pngData.prefix(32)))
            throw ViewModelTestFailure.assertion("PNG encoder accepted incomplete image bytes")
        } catch ClipboardPNGEncodingError.sourceIncomplete {
            // Expected.
        }

        guard let webPData = Data(base64Encoded:
            "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEALmk0mk0iIiIiIgBoSygABc6zbAAA"
        ) else {
            throw ViewModelTestFailure.assertion("Could not decode incomplete WebP fixture source")
        }
        let incompleteRasterHeaders = [
            Data([0xFF, 0xD8]),
            Data([0x49, 0x49, 0x2A, 0x00]),
            Data(webPData.prefix(16))
        ]
        for header in incompleteRasterHeaders {
            do {
                _ = try ClipboardPNGEncoder.pngData(from: header)
                throw ViewModelTestFailure.assertion("PNG encoder accepted an incomplete raster header")
            } catch ClipboardPNGEncodingError.sourceIncomplete {
                // Expected.
            }
        }

        var corruptedPNG = pngData
        corruptedPNG[corruptedPNG.count / 2] ^= 0xFF
        do {
            _ = try ClipboardPNGEncoder.pngData(from: corruptedPNG)
            throw ViewModelTestFailure.assertion("PNG encoder accepted a corrupted pixel stream")
        } catch ClipboardPNGEncodingError.invalidImage {
            // Expected.
        }
    }

    @MainActor
    private static func testPromisedImageFallsBackToText() async throws {
        let suite = "QuickStashTests.clipboard.promised-image-fallback.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create promised-image fallback defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1_350
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 1_351,
            payload: .pendingImage(fallbackText: "https://fallback.example")
        ))
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.changeCount = 1_351
        monitor.checkClipboard()
        try await waitUntil(description: "promised image fallback read") {
            pasteboard.payloadReadCount == 1
        }
        pasteboard.text = "newer text"
        pasteboard.changeCount = 1_352
        monitor.checkClipboard()
        try await waitUntil(description: "promised image fallback publication") {
            received.count == 2
        }
        try expect(
            received.contains(where: {
                $0.type == .url && $0.content == "https://fallback.example"
            }),
            "Unavailable promised image dropped its URL fallback"
        )
        try expect(
            received.contains(where: { $0.type == .text && $0.content == "newer text" }),
            "Promised image fallback suppressed the newer text"
        )
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testPendingImageRetryReportsTerminalError() async throws {
        let suite = "QuickStashTests.clipboard.pending-image-error.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create pending-image error defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1_400
        let message = "clipboard image provider fixture timed out"
        for _ in 0..<12 {
            pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
                changeCount: 1_401,
                payload: .pendingImage(fallbackText: nil, failureMessage: message)
            ))
        }
        var received: [StashItem] = []
        var errors: [String] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.onError = { errors.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.changeCount = 1_401
        monitor.checkClipboard()
        try await waitUntil(timeout: 4, description: "pending image terminal error") {
            errors == [message]
        }
        try expect(received.isEmpty, "Permanently pending image published an invalid fallback")
        try expect(pasteboard.payloadReadCount == 13, "Pending image did not use the bounded retry count")
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testClipboardStorageAndLegacyRepublishUsePNG(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-png-storage", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: base)
        let tiffData = try makeBitmapImageData(width: 91, height: 57, fileType: .tiff)

        let stored = try await fileManager.saveClipboardImage(
            data: tiffData,
            fileExtension: "tiff"
        )
        let storedURL = URL(fileURLWithPath: stored.content)
        let storedData = try Data(contentsOf: storedURL)
        try expect(storedURL.pathExtension == "png", "New clipboard image retained its TIFF extension")
        try expect(isPNG(storedData), "New clipboard image used a PNG extension without PNG bytes")

        let legacyURL = fileManager.imagesDirectory
            .appendingPathComponent("legacy-clipboard-image")
            .appendingPathExtension("tiff")
        try tiffData.write(to: legacyURL, options: .atomic)
        let payload = try await fileManager.readManagedImage(at: legacyURL.path)
        try expect(payload.pasteboardType == .png, "Legacy TIFF was republished with a TIFF pasteboard type")
        try expect(isPNG(payload.data), "Legacy TIFF was not converted to PNG for clipboard publishing")
        let bitmap = NSBitmapImageRep(data: payload.data)
        try expect(
            bitmap?.pixelsWide == 91 && bitmap?.pixelsHigh == 57,
            "Legacy TIFF conversion changed physical pixel dimensions"
        )
        let unchangedLegacyData = try Data(contentsOf: legacyURL)
        try expect(
            unchangedLegacyData == tiffData,
            "Reading a legacy TIFF unexpectedly migrated or rewrote its history file"
        )
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
        try expect(pasteboard.payloadReadCount == 2, "Late text was read more than once after becoming available")

        pasteboard.text = nil
        pasteboard.emptyReadsRemaining = 1
        pasteboard.changeCount = 402
        monitor.checkClipboard()
        try await waitUntil(description: "forced empty image read") {
            pasteboard.payloadReadCount == 3 && pasteboard.emptyReadsRemaining == 0
        }

        pasteboard.pngData = Data([0x89, 0x50, 0x4E, 0x47])
        try await waitUntil(description: "same-count image retry") { received.count == 2 }
        try expect(received[1].type == .image, "Retry did not publish the same-count clipboard image")
        try expect(pasteboard.changeCount == 402, "Image test advanced changeCount while publishing payload")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 2, "Same-count clipboard image was published more than once")
        try expect(pasteboard.payloadReadCount == 4, "Empty image snapshot was not retried exactly once")
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
        for _ in 0..<4 {
            pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
                changeCount: 451,
                payload: .pendingImage(fallbackText: "图片发布前的中间文字表示")
            ))
        }
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
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 701,
            payload: .pendingImage(fallbackText: "图片尚未完成时的文字表示")
        ))
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
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 651,
            payload: .pendingImage(fallbackText: "确认窗口中的旧文字")
        ))
        monitor.checkClipboard(observedAt: oldObservedAt)
        try await waitUntil(description: "provisional text confirmation") {
            pasteboard.payloadReadCount == 1 && received.isEmpty
        }

        let newObservedAt = oldObservedAt.addingTimeInterval(1)
        pasteboard.text = "确认窗口之后的新文字"
        pasteboard.changeCount = 652
        monitor.checkClipboard(observedAt: newObservedAt)
        try await waitUntil(description: "superseded provisional text finalization") {
            received.contains(where: { $0.content == "确认窗口中的旧文字" })
        }

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
        let preparedDidCommit = await monitor.commitPreparedImageRecord(prepared)
        let preparedDidCommitAgain = await monitor.commitPreparedImageRecord(prepared)
        try expect(preparedDidCommit, "Prepared screenshot image did not commit")
        try expect(!preparedDidCommitAgain, "Prepared screenshot image committed twice")
        try expect(received.count == 1, "Prepared screenshot image was not recorded exactly once")
        try expect(received[0].managedOrigin == .clipboard, "Prepared screenshot image origin changed")
        try expect(received[0].createdAt == observedAt, "Prepared screenshot image lost its copy time")

        let abandoned = try await monitor.prepareImageRecord(data: Data([6, 5, 4]))
        await monitor.discardPreparedImageRecord(abandoned)
        try expect(discarder.count == 1, "Abandoned screenshot history file was not discarded")
        let abandonedDidCommit = await monitor.commitPreparedImageRecord(abandoned)
        try expect(!abandonedDidCommit, "Discarded screenshot history item committed late")

        let pendingAtShutdown = try await monitor.prepareImageRecord(data: Data([3, 2, 1]))
        await monitor.shutdownAndDrain()
        try expect(discarder.count == 2, "Shutdown did not discard an uncommitted screenshot history image")
        let shutdownImageDidCommit = await monitor.commitPreparedImageRecord(pendingAtShutdown)
        try expect(!shutdownImageDidCommit, "Shutdown image committed after cleanup")
    }

    @MainActor
    private static func testPreparedClipboardImageRejectsInvalidatedPromotion() async throws {
        let suite = "QuickStashTests.clipboard.prepared-invalidated.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create invalidated prepared-image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let discarder = ImageDiscardRecorder()
        let promoter = BlockingDuplicateImagePromoter()
        let validity = AsyncValidityGate()
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: FakeClipboardPasteboard(),
            imageSaver: { _, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/prepared-invalidated-\(UUID().uuidString).png",
                    preview: "invalidated prepared image",
                    createdAt: observedAt,
                    managedOrigin: .clipboard,
                    contentFingerprint: "prepared-invalidated-fingerprint"
                )
            },
            imageDiscarder: { await discarder.discard($0) }
        )
        monitor.onPromoteDuplicateImage = { fingerprint, observedAt, isStillValid in
            let promoted = await promoter.promote(
                fingerprint: fingerprint,
                observedAt: observedAt
            )
            return isStillValid() && promoted
        }
        monitor.onNewItem = { received.append($0) }

        let prepared = try await monitor.prepareImageRecord(data: Data([4, 5, 6]))
        let commit = Task {
            await monitor.commitPreparedImageRecord(
                prepared,
                isStillValid: { validity.check() }
            )
        }
        try await waitUntil(description: "prepared image promotion blocked") {
            promoter.firstCallIsBlocked
        }

        validity.isValid = false
        promoter.releaseFirstCall()
        let didCommit = await commit.value

        try expect(!didCommit, "Invalidated prepared image committed late")
        try expect(received.isEmpty, "Invalidated prepared image polluted clipboard history")
        try expect(discarder.count == 1, "Invalidated prepared image backing was not discarded")
        await monitor.shutdownAndDrain()
        try expect(discarder.count == 1, "Invalidated prepared image was discarded more than once")
    }

    @MainActor
    private static func testPreparedClipboardImageSaveCannotOutliveShutdown(
        in root: URL
    ) async throws {
        let suite = "QuickStashTests.clipboard.prepared-shutdown.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create prepared shutdown defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let destination = root.appendingPathComponent("prepared-shutdown-late.png")
        let saver = BlockingImageSaveScript(destination: destination)
        let discarder = ImageDiscardRecorder()
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: FakeClipboardPasteboard(),
            imageSaver: { _, _, observedAt in await saver.save(observedAt: observedAt) },
            imageDiscarder: { await discarder.discard($0) }
        )

        let preparation = Task {
            try await monitor.prepareImageRecord(data: Data([7, 7, 7]))
        }
        try await waitUntil(description: "prepared image save blocked") { saver.started }

        var shutdownFinished = false
        let shutdown = Task {
            await monitor.shutdownAndDrain()
            shutdownFinished = true
        }
        await Task.yield()
        try expect(!shutdownFinished, "Monitor shutdown did not drain a prepared image save")

        try saver.finish()
        await shutdown.value
        do {
            _ = try await preparation.value
            throw ViewModelTestFailure.assertion("Prepared image registered after monitor shutdown")
        } catch is CancellationError {
            // Expected: shutdown owns and discards the late save result.
        }

        try expect(discarder.count == 1, "Late prepared image was not discarded exactly once")
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Late prepared image became an orphan")
    }

    @MainActor
    private static func testPreparedClipboardImageRevalidatesCanonical(in root: URL) async throws {
        let base = root.appendingPathComponent("prepared-image-canonical", isDirectory: true)
        let suite = "QuickStashTests.clipboard.prepared-canonical.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create prepared canonical defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fileManager = QuickStashFileManager(baseDirectory: base.appendingPathComponent("files"))
        let storageManager = StorageManager(baseDirectory: base.appendingPathComponent("metadata"))
        let pixels = try makeBitmapImageData(width: 46, height: 35, fileType: .png)
        let canonical = try await fileManager.saveClipboardImage(data: pixels, fileExtension: "png")
        var pinnedCanonical = canonical
        pinnedCanonical.isPinned = true
        let viewModel = StashViewModel(
            storageManager: storageManager,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        viewModel.addItem(pinnedCanonical)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: URL(fileURLWithPath: canonical.content),
            options: .atomic
        )

        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: FakeClipboardPasteboard(),
            imageSaver: { data, fileExtension, observedAt in
                try await fileManager.saveClipboardImage(
                    data: data,
                    fileExtension: fileExtension,
                    createdAt: observedAt
                )
            },
            imageDiscarder: { item in
                await fileManager.discardUnregisteredClipboardImage(at: item.content)
            }
        )
        monitor.onPromoteDuplicateImage = { fingerprint, observedAt, isStillValid in
            await viewModel.promoteDuplicateClipboardImage(
                fingerprint: fingerprint,
                observedAt: observedAt,
                isStillValid: isStillValid
            )
        }
        monitor.onNewItem = { viewModel.addItem($0) }

        let prepared = try await monitor.prepareImageRecord(
            data: pixels,
            observedAt: Date(timeIntervalSince1970: 70_000)
        )
        let didCommit = await monitor.commitPreparedImageRecord(prepared)
        try expect(didCommit, "Prepared screenshot did not commit after canonical validation")
        try await waitUntil(description: "prepared screenshot stale canonical cleanup") {
            !FileManager.default.fileExists(atPath: canonical.content)
        }
        guard let repaired = viewModel.items.first(where: { $0.id == canonical.id }) else {
            throw ViewModelTestFailure.assertion("Prepared screenshot lost the canonical history ID")
        }
        try expect(viewModel.items.count == 1, "Prepared screenshot created duplicate history metadata")
        try expect(repaired.content == prepared.content, "Prepared screenshot kept a corrupt canonical backing")
        try expect(repaired.isPinned, "Prepared screenshot replacement lost the canonical pin")
        try expect(FileManager.default.fileExists(atPath: prepared.content), "Prepared screenshot backing was discarded")

        await monitor.shutdownAndDrain()
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testDuplicateImagePromotionChecksValidityAfterFileIO(
        in root: URL
    ) async throws {
        let base = root.appendingPathComponent("duplicate-image-validity", isDirectory: true)
        let blocker = BlockingQuarantineScript()
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            cleanupFaultInjector: { blocker.inject($0) }
        )
        let canonicalData = try makeBitmapImageData(width: 47, height: 37, fileType: .png)
        let blockerData = try makeBitmapImageData(width: 48, height: 37, fileType: .png)
        let canonical = try await fileManager.saveClipboardImage(
            data: canonicalData,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 80_000)
        )
        let blockingItem = try await fileManager.saveClipboardImage(
            data: blockerData,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 80_001)
        )
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        viewModel.addItem(canonical)

        var released = false
        defer {
            if !released { blocker.release.signal() }
        }
        let quarantine = Task {
            try? await fileManager.quarantineManagedFile(at: blockingItem.content)
        }
        try await waitUntil(description: "file queue blocked before duplicate validation") {
            blocker.started
        }

        let validity = AsyncValidityGate()
        let promotion = Task {
            await viewModel.promoteDuplicateClipboardImage(
                fingerprint: canonical.contentFingerprint ?? "",
                observedAt: Date(timeIntervalSince1970: 80_100),
                isStillValid: { validity.check() }
            )
        }
        try await waitUntil(description: "duplicate promotion entered file validation") {
            validity.checkCount == 1
        }
        validity.isValid = false
        blocker.release.signal()
        released = true
        _ = await quarantine.value

        let promoted = await promotion.value
        try expect(!promoted, "Invalid duplicate-image operation promoted after file validation")
        try expect(viewModel.items.count == 1, "Invalid duplicate-image operation changed item count")
        try expect(
            viewModel.items[0].createdAt == canonical.createdAt,
            "Invalid duplicate-image operation changed ordering metadata"
        )
        await viewModel.flushForTermination()
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
    private static func testClipboardAcceptsLateImageAfterSoftTimeout() async throws {
        let suite = "QuickStashTests.clipboard.late-image.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create late-image defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 900
        let blockedRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = blockedRead
        let pngData = try makeBitmapImageData(fileType: .png)
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 901,
            payload: .image(pngData, fileExtension: "png")
        ))
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            readTimeoutInterval: 0.05,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/late-image-\(data.count).png",
                    preview: "late image",
                    createdAt: observedAt,
                    managedOrigin: .clipboard
                )
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.changeCount = 901
        monitor.checkClipboard()
        try await waitUntil(description: "late image provider started") {
            pasteboard.payloadReadCount == 1
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        blockedRead.signal()
        try await waitUntil(description: "late image accepted after soft timeout") {
            received.count == 1
        }
        try expect(received[0].type == .image, "Late provider result changed item type")
        try expect(pasteboard.payloadReadCount == 1, "Soft timeout spawned duplicate reads for one count")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 1, "Late provider image was committed more than once")
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testTimedOutImageUpgradeSurvivesNewerCopy(in root: URL) async throws {
        let suite = "QuickStashTests.clipboard.timed-out-upgrade.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create timed-out upgrade defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1_100
        let viewModelRoot = root.appendingPathComponent("timed-out-image-upgrade", isDirectory: true)
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: viewModelRoot.appendingPathComponent("metadata")),
            fileManager: QuickStashFileManager(baseDirectory: viewModelRoot.appendingPathComponent("files")),
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        let pngData = try makeBitmapImageData(fileType: .png)
        let blockedImageRead = DispatchSemaphore(value: 0)
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            readTimeoutInterval: 0.05,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/timed-out-upgrade-\(data.count).png",
                    preview: "timed-out upgrade image",
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

        let imageObservedAt = Date(timeIntervalSince1970: 1_702_000_000)
        pasteboard.text = "超时图片的中间文字"
        pasteboard.changeCount = 1_101
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 1_101,
            payload: .pendingImage(fallbackText: "超时图片的中间文字")
        ))
        monitor.checkClipboard(observedAt: imageObservedAt)
        try await waitUntil(description: "timed-out upgrade provisional text") {
            pasteboard.payloadReadCount == 1 && received.isEmpty
        }
        pasteboard.readGate = blockedImageRead
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 1_101,
            payload: .image(pngData, fileExtension: "png")
        ))
        try await waitUntil(description: "timed-out image upgrade read") {
            pasteboard.payloadReadCount == 2
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let textObservedAt = imageObservedAt.addingTimeInterval(1)
        pasteboard.pngData = nil
        pasteboard.text = "图片之后的新文字"
        pasteboard.changeCount = 1_102
        monitor.checkClipboard(observedAt: textObservedAt)
        try expect(received.isEmpty, "New count finalized a timed-out image's provisional text")
        try await waitUntil(description: "new count beside timed-out image") {
            pasteboard.payloadReadCount >= 3
        }
        blockedImageRead.signal()

        try await waitUntil(description: "timed-out image and newer text") {
            received.count == 2
        }
        try expect(received.filter { $0.type == .image }.count == 1, "Timed-out image upgrade was lost")
        try expect(
            !received.contains(where: { $0.content == "超时图片的中间文字" }),
            "Timed-out image provisional text leaked into history"
        )
        try expect(
            viewModel.items.map(\.type) == [.text, .image],
            "Timed-out image and newer text were not ordered by observation time"
        )
        monitor.stopMonitoring()
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testLateReadCannotConsumeNewerCount() async throws {
        let suite = "QuickStashTests.clipboard.late-count-binding.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create late count-binding defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1_200
        let blockedOldRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = blockedOldRead
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 1_202,
            payload: .text("旧 lane 不得提交的新计数内容")
        ))
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            readTimeoutInterval: 0.05,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        let oldObservedAt = Date(timeIntervalSince1970: 1_703_000_000)
        pasteboard.text = "旧内容"
        pasteboard.changeCount = 1_201
        monitor.checkClipboard(observedAt: oldObservedAt)
        try await waitUntil(description: "old count provider") { pasteboard.payloadReadCount == 1 }

        let newObservedAt = oldObservedAt.addingTimeInterval(1)
        pasteboard.text = "新计数的真实内容"
        pasteboard.changeCount = 1_202
        monitor.checkClipboard(observedAt: newObservedAt)
        try await waitUntil(description: "new count provider") { pasteboard.payloadReadCount >= 2 }
        blockedOldRead.signal()
        try await waitUntil(description: "correctly bound new count") { received.count == 1 }
        try expect(received[0].content == "新计数的真实内容", "Late old lane consumed the newer snapshot")
        try expect(received[0].createdAt == newObservedAt, "New count inherited the old observation timestamp")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(received.count == 1, "Late old lane published after the newer count")
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testLateTextStillWaitsForSameCountImage() async throws {
        let suite = "QuickStashTests.clipboard.late-text-upgrade.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create late text-upgrade defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1_300
        let blockedRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = blockedRead
        pasteboard.enqueueForcedSnapshot(ClipboardPayloadSnapshot(
            changeCount: 1_301,
            payload: .pendingImage(fallbackText: "迟到的图片中间文字")
        ))
        let pngData = try makeBitmapImageData(fileType: .png)
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            readTimeoutInterval: 0.05,
            imageSaver: { data, _, observedAt in
                StashItem(
                    type: .image,
                    content: "/tmp/late-text-upgrade-\(data.count).png",
                    preview: "late text upgrade",
                    createdAt: observedAt,
                    managedOrigin: .clipboard
                )
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "迟到的图片中间文字"
        pasteboard.changeCount = 1_301
        monitor.checkClipboard()
        try await waitUntil(description: "late text provider") { pasteboard.payloadReadCount == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        blockedRead.signal()
        pasteboard.pngData = pngData

        try await waitUntil(description: "same-count image after late text") { received.count == 1 }
        try expect(received[0].type == .image, "Late text was committed before its same-count image")
        try expect(
            !received.contains(where: { $0.content == "迟到的图片中间文字" }),
            "Late provisional text leaked into history"
        )
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testClipboardPayloadReadLaneCapAndBoundedDrain() async throws {
        let suite = "QuickStashTests.clipboard.reader-cap.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create reader-cap defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 1_400
        let firstBlockedRead = DispatchSemaphore(value: 0)
        let secondBlockedRead = DispatchSemaphore(value: 0)
        pasteboard.readGate = firstBlockedRead
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            readTimeoutInterval: 0.05,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "blocked-1"
        pasteboard.changeCount = 1_401
        monitor.checkClipboard()
        try await waitUntil(description: "first blocked provider") { pasteboard.payloadReadCount == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)

        pasteboard.readGate = secondBlockedRead
        pasteboard.text = "blocked-2"
        pasteboard.changeCount = 1_402
        monitor.checkClipboard()
        try await waitUntil(description: "second blocked provider") { pasteboard.payloadReadCount == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)

        monitor.stopMonitoring()
        monitor.startMonitoring()
        for count in 1_403...1_412 {
            pasteboard.text = "latest-\(count)"
            pasteboard.changeCount = count
            monitor.checkClipboard()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try expect(pasteboard.payloadReadCount == 2, "Blocked providers exceeded the two-lane cap")
        try expect(pasteboard.maximumConcurrentReaders == 2, "Reader lane cap allowed excess concurrency")

        firstBlockedRead.signal()
        try await waitUntil(description: "latest pending read after lane release") {
            received.count == 1
        }
        try expect(received[0].content == "latest-1412", "Lane release did not retain only the latest pending count")
        try expect(pasteboard.maximumConcurrentReaders == 2, "Replacement read exceeded the lane cap")
        secondBlockedRead.signal()
        monitor.stopMonitoring()

        let drainPasteboard = FakeClipboardPasteboard()
        drainPasteboard.changeCount = 1_500
        let neverReturningRead = DispatchSemaphore(value: 0)
        drainPasteboard.readGate = neverReturningRead
        let drainMonitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: drainPasteboard,
            readTimeoutInterval: 0.05,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        drainMonitor.setConsent(.enabled)
        drainPasteboard.text = "blocked drain"
        drainPasteboard.changeCount = 1_501
        drainMonitor.checkClipboard()
        try await waitUntil(description: "bounded drain provider") { drainPasteboard.payloadReadCount == 1 }
        let drainStart = ProcessInfo.processInfo.systemUptime
        await drainMonitor.shutdownAndDrain(
            waitForPayloadReads: true,
            payloadReadDrainTimeout: 0.05
        )
        let drainElapsed = ProcessInfo.processInfo.systemUptime - drainStart
        try expect(drainElapsed < 0.5, "Payload drain waited indefinitely for a blocked provider")
        neverReturningRead.signal()
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
    private static func testClipboardImageSaveRetriesTransientFailure() async throws {
        let suite = "QuickStashTests.clipboard.image-save-retry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create image-save retry defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 950
        pasteboard.pngData = try makeBitmapImageData(fileType: .png)
        let saver = FailOnceClipboardImageSaver()
        var received: [StashItem] = []
        var errors: [String] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { data, _, observedAt in
                try await saver.save(data: data, observedAt: observedAt)
            }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.onError = { errors.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.changeCount = 951
        monitor.checkClipboard()
        try await waitUntil(description: "clipboard image save retry") {
            received.count == 1
        }
        try expect(saver.callCount == 2, "Transient image save was not retried exactly once")
        try expect(errors.isEmpty, "Successful image save retry reported a terminal error")
        try expect(received[0].type == .image, "Retried image save changed item type")
        monitor.stopMonitoring()
    }

    @MainActor
    private static func testClipboardImageSaveCancellationStopsRetry() async throws {
        let suite = "QuickStashTests.clipboard.image-save-cancel.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create image-save cancellation defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 975
        pasteboard.pngData = try makeBitmapImageData(fileType: .png)
        let saver = AlwaysFailClipboardImageSaver()
        var errors: [String] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in try await saver.save() }
        )
        monitor.onError = { errors.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.changeCount = 976
        monitor.checkClipboard()
        try await waitUntil(description: "first failing image-save attempt") { saver.callCount == 1 }
        monitor.stopMonitoring()
        try await Task.sleep(nanoseconds: 350_000_000)
        try expect(saver.callCount == 1, "Cancelled image save started another retry")
        try expect(errors.isEmpty, "Cancelled image save reported a stale terminal error")
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
        try expect(pasteboard.payloadReadCount == 2, "Stable latest text was read more than once")
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
        try await waitUntil(description: "graceful stable \(expectedType.rawValue)") {
            pasteboard.payloadReadCount == 1 && viewModel.items.count == 1
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
    private static func testClipboardGracefulTerminationDrainsLastSlowRead() async throws {
        let suite = "QuickStashTests.clipboard.graceful-slow-read.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create graceful slow-read defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 6_000
        let readGate = DispatchSemaphore(value: 0)
        pasteboard.readGate = readGate
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)

        pasteboard.text = "退出动作发现的最后一条慢文字"
        pasteboard.changeCount = 6_001
        var shutdownFinished = false
        let shutdown = Task {
            await monitor.shutdownForTermination(
                settleNanoseconds: 0,
                payloadReadDrainTimeout: 1
            )
            shutdownFinished = true
        }
        try await waitUntil(description: "termination-triggered slow clipboard read") {
            pasteboard.payloadReadCount == 1
        }
        try expect(!shutdownFinished, "Graceful termination abandoned a live clipboard read")

        readGate.signal()
        await shutdown.value
        try expect(shutdownFinished, "Graceful termination did not finish after the provider returned")
        try expect(received.count == 1, "Graceful termination lost or duplicated its final slow read")
        try expect(
            received[0].content == "退出动作发现的最后一条慢文字",
            "Graceful termination changed its final slow clipboard content"
        )
    }

    @MainActor
    private static func testClipboardGracefulTerminationTimesOutBlockedRead() async throws {
        let suite = "QuickStashTests.clipboard.graceful-read-timeout.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ViewModelTestFailure.assertion("Could not create graceful read-timeout defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 6_100
        let readGate = DispatchSemaphore(value: 0)
        pasteboard.readGate = readGate
        var received: [StashItem] = []
        let monitor = ClipboardMonitor(
            preferences: ClipboardPreferences(defaults: defaults),
            pasteboard: pasteboard,
            imageSaver: { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        monitor.onNewItem = { received.append($0) }
        monitor.setConsent(.enabled)
        pasteboard.text = "不应在退出超时后晚到的文字"
        pasteboard.changeCount = 6_101

        let startedAt = ProcessInfo.processInfo.systemUptime
        await monitor.shutdownForTermination(
            settleNanoseconds: 0,
            payloadReadDrainTimeout: 0.05
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        try expect(elapsed < 0.5, "Graceful termination waited indefinitely for a blocked provider")
        try expect(pasteboard.payloadReadCount == 1, "Termination did not attempt its final clipboard read")
        try expect(received.isEmpty, "Blocked provider published before it returned")

        readGate.signal()
        try await waitUntil(description: "timed-out provider completion") {
            pasteboard.payloadReadCompletionCount == 1
        }
        await Task.yield()
        try expect(received.isEmpty, "Timed-out provider published after graceful shutdown")
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
            data: try makeBitmapImageData(fileType: .png),
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
    private static func testTerminationWaitsForManualClipboardClear(in root: URL) async throws {
        let base = root.appendingPathComponent("termination-manual-clear", isDirectory: true)
        let blocker = BlockingQuarantineScript()
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            cleanupFaultInjector: { blocker.inject($0) }
        )
        let storageManager = StorageManager(
            baseDirectory: base.appendingPathComponent("metadata", isDirectory: true)
        )
        let image = try await fileManager.saveClipboardImage(
            data: try makeBitmapImageData(width: 58, height: 43, fileType: .png),
            fileExtension: "png"
        )
        let viewModel = StashViewModel(
            storageManager: storageManager,
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        viewModel.addItem(image)

        var released = false
        defer {
            if !released { blocker.release.signal() }
        }
        let clear = Task { await viewModel.clearUnpinnedClipboardItems() }
        try await waitUntil(description: "manual clear quarantine blocked") { blocker.started }

        var flushFinished = false
        let flush = Task {
            await viewModel.flushForTermination()
            flushFinished = true
        }
        try await waitUntil(description: "termination flush entered") {
            viewModel.isTerminationFlushActive
        }
        try expect(!flushFinished, "Termination flush did not wait for manual clipboard clear")

        blocker.release.signal()
        released = true
        let clearResult = await clear.value
        await flush.value
        try expect(clearResult.removedCount == 1, "Tracked manual clear did not remove its image")
        try expect(!FileManager.default.fileExists(atPath: image.content), "Tracked manual clear left its backing")

        let loadResult = await withCheckedContinuation { continuation in
            storageManager.loadSnapshot { continuation.resume(returning: $0) }
        }
        guard case .loaded(let snapshot) = loadResult else {
            throw ViewModelTestFailure.assertion("Termination did not persist manual clear metadata")
        }
        try expect(
            !snapshot.items.contains(where: { $0.id == image.id }),
            "Termination snapshot retained a manually cleared image"
        )
    }

    @MainActor
    private static func testManualDeletePreservesConcurrentDuplicateImage(in root: URL) async throws {
        let base = root.appendingPathComponent("manual-delete-image-race", isDirectory: true)
        let blocker = BlockingQuarantineScript()
        let fileManager = QuickStashFileManager(
            baseDirectory: base.appendingPathComponent("files", isDirectory: true),
            cleanupFaultInjector: { blocker.inject($0) }
        )
        let pixels = try makeBitmapImageData(width: 52, height: 39, fileType: .png)
        let original = try await fileManager.saveClipboardImage(
            data: pixels,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 10_000)
        )
        let replacement = try await fileManager.saveClipboardImage(
            data: pixels,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 10_001)
        )
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: base.appendingPathComponent("metadata")),
            fileManager: fileManager,
            loadOnInit: false,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        viewModel.addItem(original)

        var released = false
        defer {
            if !released { blocker.release.signal() }
        }
        viewModel.deleteItem(original)
        try await waitUntil(description: "manual image deletion quarantine") { blocker.started }

        viewModel.addItem(replacement)
        let replacementWasInsertedWhileBlocked = viewModel.items.contains(where: {
            $0.id == replacement.id && $0.content == replacement.content
        })
        viewModel.togglePin(original)
        let originalStayedUnpinned = viewModel.items.first(where: { $0.id == original.id })?.isPinned == false

        blocker.release.signal()
        released = true
        await viewModel.flushForTermination()

        try expect(replacementWasInsertedWhileBlocked, "Duplicate image was merged into a record being deleted")
        try expect(originalStayedUnpinned, "Record changed pin state while manual deletion was in flight")
        try expect(!viewModel.items.contains(where: { $0.id == original.id }), "Deleted image metadata remained")
        try expect(
            viewModel.items.contains(where: {
                $0.id == replacement.id && $0.content == replacement.content
            }),
            "Late manual deletion removed the newly captured duplicate image"
        )
        try expect(viewModel.items.count == 1, "Manual deletion race left unexpected image records")
        try expect(!FileManager.default.fileExists(atPath: original.content), "Deleted image backing was not quarantined")
        try expect(FileManager.default.fileExists(atPath: replacement.content), "Replacement image backing was discarded")
    }

    @MainActor
    private static func testClipboardImageOrphanRecoveryRetentionClearAndRestart(in root: URL) async throws {
        let base = root.appendingPathComponent("clipboard-orphan-recovery", isDirectory: true)
        let filesBase = base.appendingPathComponent("files", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: filesBase)
        let oldPixels = try makeBitmapImageData(width: 64, height: 48, fileType: .png)
        let freshPixels = try makeBitmapImageData(width: 65, height: 48, fileType: .png)
        let oldOrphan = try await fileManager.saveClipboardImage(data: oldPixels, fileExtension: "png")
        let freshOrphan = try await fileManager.saveClipboardImage(data: freshPixels, fileExtension: "png")
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
        try await waitUntil(description: "expired orphan retention cleanup") {
            !FileManager.default.fileExists(atPath: oldOrphan.content)
                && !viewModel.items.contains(where: {
                    URL(fileURLWithPath: $0.content).lastPathComponent == oldFileName
                })
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
        let pngFixture = try makeBitmapImageData(fileType: .png)
        let secondPNGFixture = try makeBitmapImageData(width: 65, height: 48, fileType: .png)
        let firstImage = try await fileManager.saveClipboardImage(data: pngFixture, fileExtension: "png")
        let secondImage = try await fileManager.saveClipboardImage(data: secondPNGFixture, fileExtension: "png")
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
    private static func testBootstrapDuplicateAliasReplaysDelete(in root: URL) async throws {
        let base = root.appendingPathComponent("bootstrap-duplicate-alias-delete", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let canonical = StashItem(
            type: .text,
            content: "bootstrap duplicate delete",
            preview: "canonical",
            createdAt: Date(timeIntervalSince1970: 70_000),
            managedOrigin: .clipboard
        )
        let marker = StashItem(
            type: .text,
            content: "bootstrap delete marker",
            preview: "marker"
        )
        try StorageManager(baseDirectory: metadataBase).flushSynchronously(StorageSnapshot(
            revision: 21,
            items: [canonical, marker],
            importJobs: []
        ))

        let blockingStore = BlockingReadStorageFileStore()
        let loadingStorage = StorageManager(baseDirectory: metadataBase, fileStore: blockingStore)
        let viewModel = StashViewModel(
            storageManager: loadingStorage,
            fileManager: QuickStashFileManager(baseDirectory: base.appendingPathComponent("files")),
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "duplicate delete bootstrap read") {
            blockingStore.hasStartedReading
        }

        let incoming = StashItem(
            type: .text,
            content: canonical.content,
            preview: "incoming",
            createdAt: canonical.createdAt.addingTimeInterval(1),
            managedOrigin: .clipboard
        )
        viewModel.addItem(incoming)
        viewModel.deleteItem(incoming)
        blockingStore.allowRead.signal()

        try await waitUntil(description: "duplicate alias delete replay") {
            viewModel.items.contains(where: { $0.id == marker.id })
                && !viewModel.items.contains(where: { $0.id == canonical.id })
                && !viewModel.items.contains(where: { $0.id == incoming.id })
        }
        await viewModel.flushForTermination()

        guard case .loaded(let persisted) = StorageManager(baseDirectory: metadataBase)
            .loadSnapshotSynchronously() else {
            throw ViewModelTestFailure.assertion("Duplicate alias delete snapshot did not persist")
        }
        try expect(
            persisted.items.map(\.id) == [marker.id],
            "Delete replay did not target the persisted canonical ID"
        )
    }

    @MainActor
    private static func testBootstrapDuplicateAliasResolvesTogglePin(in root: URL) async throws {
        let base = root.appendingPathComponent("bootstrap-duplicate-alias-pin", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let canonical = StashItem(
            type: .url,
            content: "https://bootstrap-alias.example/pin",
            preview: "canonical",
            createdAt: Date(timeIntervalSince1970: 71_000),
            managedOrigin: .clipboard
        )
        try StorageManager(baseDirectory: metadataBase).flushSynchronously(StorageSnapshot(
            revision: 22,
            items: [canonical],
            importJobs: []
        ))

        let blockingStore = BlockingReadStorageFileStore()
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadataBase, fileStore: blockingStore),
            fileManager: QuickStashFileManager(baseDirectory: base.appendingPathComponent("files")),
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "duplicate pin bootstrap read") {
            blockingStore.hasStartedReading
        }

        let incoming = StashItem(
            type: .url,
            content: canonical.content,
            preview: "incoming",
            createdAt: canonical.createdAt.addingTimeInterval(1),
            managedOrigin: .clipboard
        )
        viewModel.addItem(incoming)
        viewModel.togglePin(incoming)
        blockingStore.allowRead.signal()

        try await waitUntil(description: "duplicate alias pin replay") {
            viewModel.items.count == 1
                && viewModel.items[0].id == canonical.id
                && viewModel.items[0].isPinned
        }
        viewModel.togglePin(incoming)
        try expect(
            viewModel.items.count == 1
                && viewModel.items[0].id == canonical.id
                && !viewModel.items[0].isPinned,
            "A stale incoming ID did not resolve to the canonical record for togglePin"
        )
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testBootstrapDuplicateAliasCompletesAsyncImageCopy(
        in root: URL
    ) async throws {
        let base = root.appendingPathComponent("bootstrap-duplicate-alias-image-copy", isDirectory: true)
        let filesBase = base.appendingPathComponent("files", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let fileManager = QuickStashFileManager(baseDirectory: filesBase)
        let pixels = try makeBitmapImageData(width: 58, height: 42, fileType: .png)
        let canonical = try await fileManager.saveClipboardImage(
            data: pixels,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 72_000)
        )
        let incoming = try await fileManager.saveClipboardImage(
            data: pixels,
            fileExtension: "png",
            createdAt: canonical.createdAt.addingTimeInterval(1)
        )
        try expect(
            incoming.content != canonical.content
                && incoming.contentFingerprint == canonical.contentFingerprint,
            "Async image alias fixture did not use distinct equivalent backings"
        )
        try StorageManager(baseDirectory: metadataBase).flushSynchronously(StorageSnapshot(
            revision: 23,
            items: [canonical],
            importJobs: []
        ))
        let imageReader = BlockingClipboardImageReader(
            payload: try await fileManager.readManagedImage(at: incoming.content)
        )
        let blockingStore = BlockingReadStorageFileStore()
        var imageWriteCount = 0
        let viewModel = StashViewModel(
            storageManager: StorageManager(baseDirectory: metadataBase, fileStore: blockingStore),
            fileManager: fileManager,
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {},
            clipboardImageReader: { path in try await imageReader.read(path) },
            clipboardImageWriter: { _ in
                imageWriteCount += 1
                return true
            }
        )
        try await waitUntil(description: "duplicate image-copy bootstrap read") {
            blockingStore.hasStartedReading
        }

        viewModel.addItem(incoming)
        viewModel.copyToClipboard(incoming)
        await imageReader.waitUntilStarted()
        blockingStore.allowRead.signal()
        try await waitUntil(description: "duplicate image canonical alias") {
            viewModel.items.count == 1 && viewModel.items[0].id == canonical.id
        }

        await imageReader.finish()
        try await waitUntil(description: "aliased async image clipboard write") {
            imageWriteCount == 1
        }
        try expect(
            viewModel.items.count == 1 && viewModel.items[0].id == canonical.id,
            "Late async image copy recreated the incoming bootstrap ID"
        )
        try expect(
            viewModel.items[0].createdAt > incoming.createdAt,
            "Late async image copy did not promote the canonical record"
        )
        await viewModel.flushForTermination()
    }

    @MainActor
    private static func testBootstrapReplacesCorruptClipboardCanonicalAfterMetadataFlush(
        in root: URL
    ) async throws {
        let base = root.appendingPathComponent("bootstrap-corrupt-image-replacement", isDirectory: true)
        let filesBase = base.appendingPathComponent("files", isDirectory: true)
        let metadataBase = base.appendingPathComponent("metadata", isDirectory: true)
        let quarantine = BlockingQuarantineScript()
        let fileManager = QuickStashFileManager(
            baseDirectory: filesBase,
            cleanupFaultInjector: { quarantine.inject($0) }
        )
        let pixels = try makeBitmapImageData(width: 57, height: 43, fileType: .png)
        var canonical = try await fileManager.saveClipboardImage(
            data: pixels,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 60_000)
        )
        canonical.isPinned = true
        let seedStorage = StorageManager(baseDirectory: metadataBase)
        try seedStorage.flushSynchronously(StorageSnapshot(
            revision: 12,
            items: [canonical],
            importJobs: []
        ))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: URL(fileURLWithPath: canonical.content),
            options: .atomic
        )

        let blockingStore = BlockingReadStorageFileStore()
        let loadingStorage = StorageManager(baseDirectory: metadataBase, fileStore: blockingStore)
        let viewModel = StashViewModel(
            storageManager: loadingStorage,
            fileManager: fileManager,
            loadOnInit: true,
            purgeOnInit: false,
            retentionPolicy: ClipboardRetentionPolicy(maximumItemCount: nil, maximumAgeDays: nil),
            clipboardCaptureInvalidator: {}
        )
        try await waitUntil(description: "corrupt canonical bootstrap read") {
            blockingStore.hasStartedReading
        }

        let replacement = try await fileManager.saveClipboardImage(
            data: pixels,
            fileExtension: "png",
            createdAt: Date(timeIntervalSince1970: 60_001)
        )
        try expect(
            replacement.contentFingerprint == canonical.contentFingerprint,
            "Bootstrap replacement fixture did not preserve the pixel fingerprint"
        )
        viewModel.addItem(replacement)

        var quarantineReleased = false
        defer {
            if !quarantineReleased { quarantine.release.signal() }
        }
        blockingStore.allowRead.signal()
        try await waitUntil(description: "corrupt canonical replacement quarantine") {
            quarantine.started
        }

        guard let retained = viewModel.items.first, viewModel.items.count == 1 else {
            throw ViewModelTestFailure.assertion("Bootstrap replacement left duplicate image metadata")
        }
        try expect(retained.id == canonical.id, "Bootstrap replacement lost the canonical history ID")
        try expect(retained.content == replacement.content, "Bootstrap replacement kept the corrupt backing")
        try expect(retained.isPinned, "Bootstrap replacement lost the canonical pin")
        try expect(retained.availability == .available, "Bootstrap replacement remained unavailable")
        try expect(
            FileManager.default.fileExists(atPath: canonical.content),
            "Corrupt backing moved before replacement metadata was inspected"
        )

        let verificationStorage = StorageManager(baseDirectory: metadataBase)
        guard case .loaded(let persistedBeforeQuarantine) = verificationStorage.loadSnapshotSynchronously() else {
            throw ViewModelTestFailure.assertion("Replacement metadata was not flushed before quarantine")
        }
        try expect(
            persistedBeforeQuarantine.items.count == 1
                && persistedBeforeQuarantine.items[0].id == canonical.id
                && persistedBeforeQuarantine.items[0].content == replacement.content,
            "Quarantine started before replacement metadata reached disk"
        )
        try expect(
            !persistedBeforeQuarantine.items.contains(where: { $0.content == canonical.content }),
            "Persisted metadata still referenced the backing awaiting quarantine"
        )

        quarantine.release.signal()
        quarantineReleased = true
        await viewModel.flushForTermination()

        try expect(!FileManager.default.fileExists(atPath: canonical.content), "Corrupt canonical backing was not quarantined")
        try expect(FileManager.default.fileExists(atPath: replacement.content), "Replacement backing was removed during cleanup")
        let trashDirectory = filesBase.appendingPathComponent("QuickStash/Trash", isDirectory: true)
        let trashContents = try FileManager.default.contentsOfDirectory(
            at: trashDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            trashContents.contains(where: { $0.lastPathComponent.hasSuffix("-\(URL(fileURLWithPath: canonical.content).lastPathComponent)") }),
            "Corrupt canonical backing did not enter the quarantine directory"
        )
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
