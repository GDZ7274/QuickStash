import Foundation
import Darwin

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileImportProgress] = []
    private var times: [TimeInterval] = []

    func append(_ progress: FileImportProgress) {
        lock.withLock {
            values.append(progress)
            times.append(ProcessInfo.processInfo.systemUptime)
        }
    }

    var snapshot: [FileImportProgress] {
        lock.withLock { values }
    }

    var timeSnapshot: [TimeInterval] {
        lock.withLock { times }
    }
}

private final class CapacityScript: @unchecked Sendable {
    private let lock = NSLock()
    private let token: ImportCancellationToken?
    private let cancelOnCall: Int?
    private let lowCapacityOnCall: Int?
    private let actionOnCall: Int?
    private let action: (@Sendable () -> Void)?
    private(set) var callCount = 0

    init(
        token: ImportCancellationToken? = nil,
        cancelOnCall: Int? = nil,
        lowCapacityOnCall: Int? = nil,
        actionOnCall: Int? = nil,
        action: (@Sendable () -> Void)? = nil
    ) {
        self.token = token
        self.cancelOnCall = cancelOnCall
        self.lowCapacityOnCall = lowCapacityOnCall
        self.actionOnCall = actionOnCall
        self.action = action
    }

    func capacity() -> Int64 {
        let call = lock.withLock {
            callCount += 1
            return callCount
        }
        if call == cancelOnCall {
            token?.cancel()
        }
        if call == actionOnCall {
            action?()
        }
        return call >= (lowCapacityOnCall ?? .max) ? 0 : Int64.max
    }
}

private struct InjectedCleanupError: Error, LocalizedError {
    let errorDescription: String? = "injected cleanup failure"
}

private final class RecordingStorageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [Int64] = []

    func write(_ data: Data, to url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let revision = (object?["revision"] as? NSNumber)?.int64Value ?? -1
        lock.withLock { revisions.append(revision) }
        try data.write(to: url, options: [.atomic])
    }

    var snapshot: [Int64] { lock.withLock { revisions } }
}

private final class BlockingFirstStorageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var writeCount = 0
    private var revisions: [Int64] = []
    let firstWriteStarted = DispatchSemaphore(value: 0)
    let allowFirstWrite = DispatchSemaphore(value: 0)

    func write(_ data: Data, to url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let revision = (object?["revision"] as? NSNumber)?.int64Value ?? -1
        let isFirst = lock.withLock {
            writeCount += 1
            revisions.append(revision)
            return writeCount == 1
        }
        if isFirst {
            firstWriteStarted.signal()
            allowFirstWrite.wait()
        }
        try data.write(to: url, options: [.atomic])
    }

    var snapshot: [Int64] { lock.withLock { revisions } }
}

private final class FailOnceStorageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    let firstAttemptFinished = DispatchSemaphore(value: 0)

    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        if fail {
            firstAttemptFinished.signal()
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: [.atomic])
    }
}

private final class BackupFailingStorageFileStore: StorageFileStore, @unchecked Sendable {
    private let wrapped = LocalStorageFileStore()

    func createDirectory(at url: URL) throws { try wrapped.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { wrapped.fileExists(at: url) }
    func readData(at url: URL) throws -> Data { try wrapped.readData(at: url) }
    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try wrapped.writeDataAtomically(data, to: url)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@MainActor
private final class StorageCallbackRecorder {
    private(set) var failures: [Bool] = []
    func append(_ error: Error?) { failures.append(error != nil) }
}

private struct DeletionManifestFixture: Codable {
    let id: UUID
    let originalPath: String
    let trashPath: String
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@main
struct QuickStashCoreTests {
    static func main() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try testTypeClassification()
        try testVersionedAndLegacyStorage(in: testRoot)
        try testCoalescedStorageAndFutureSchemaProtection(in: testRoot)
        try testCorruptBackupFailureBlocksWrites(in: testRoot)
        try testCorruptStorageBackup(in: testRoot)
        try await testAutomaticRetryNotifiesSuccess(in: testRoot)
        try await testManagedImportAndDeletion(in: testRoot)
        try await testImportLimitsAndCapacity(in: testRoot)
        try await testNestedUnsafeEntriesAreRejected(in: testRoot)
        try await testImportProgressAndCancellationRollback(in: testRoot)
        try await testPostPreflightGrowthIsStopped(in: testRoot)
        try await testPostPreflightSymlinkIsStopped(in: testRoot)
        try await testResourceForkLimits(in: testRoot)
        try await testExtendedAttributeLimits(in: testRoot)
        try await testExtendedAttributeNameListLimits(in: testRoot)
        try await testCleanupFailuresNeedRecovery(in: testRoot)
        try await testInterruptedImportRecovery(in: testRoot)
        try await testDeletionTombstoneRecovery(in: testRoot)
        try await testManifestCommitFailureRecovery(in: testRoot)
        try await testCapacityDropDuringCopy(in: testRoot)
        try testProgressRateLimit()
        try testImportJobStateReduction()

        print("QuickStash core tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure.assertion(message) }
    }

    private static func testTypeClassification() throws {
        try expect(ItemType.fromFileExtension("PDF") == .pdf, "PDF classification failed")
        try expect(ItemType.fromFileExtension("zip") == .archive, "Archive classification failed")
        try expect(ItemType.fromFileExtension("swift") == .code, "Code classification failed")
        try expect(ItemType.fromFileExtension("unknown") == .file, "Fallback classification failed")
    }

    private static func testVersionedAndLegacyStorage(in root: URL) throws {
        let base = root.appendingPathComponent("storage", isDirectory: true)
        let storage = StorageManager(baseDirectory: base)
        let item = StashItem(
            type: .text,
            content: "hello",
            preview: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )

        try storage.flushSynchronously(StorageSnapshot(revision: 1, items: [item], importJobs: []))
        guard case .loaded(let loaded) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Versioned storage did not load")
        }
        try expect(loaded.items == [item], "Versioned storage changed item data")
        try expect(loaded.revision == 1, "Versioned storage lost its revision")

        let legacyURL = base
            .appendingPathComponent("QuickStash", isDirectory: true)
            .appendingPathComponent("items.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedLegacy = try encoder.encode([item])
        var legacyObject = try JSONSerialization.jsonObject(with: encodedLegacy) as! [[String: Any]]
        legacyObject[0]["availability"] = nil
        legacyObject[0]["managedOrigin"] = nil
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL, options: .atomic)

        guard case .loaded(let legacySnapshot) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Legacy storage did not load")
        }
        let legacyItems = legacySnapshot.items
        try expect(legacyItems.count == 1, "Legacy storage changed item count")
        try expect(legacyItems[0].id == item.id, "Legacy storage changed item ID")
        try expect(legacyItems[0].content == item.content, "Legacy storage changed item content")
        try expect(legacyItems[0].managedOrigin == .legacyUnknown, "Legacy storage was not retention-safe")
        try expect(
            abs(legacyItems[0].createdAt.timeIntervalSince(item.createdAt)) < 1,
            "Legacy storage changed item date beyond ISO8601 precision"
        )

        try storage.flushSynchronously(StorageSnapshot(revision: 2, items: [], importJobs: []))
        guard case .loaded(let emptySnapshot) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Empty storage did not load")
        }
        let emptyItems = emptySnapshot.items
        try expect(emptyItems.isEmpty, "Empty storage unexpectedly gained sample data")
    }

    private static func testCoalescedStorageAndFutureSchemaProtection(in root: URL) throws {
        let base = root.appendingPathComponent("coalesced-storage", isDirectory: true)
        let recorder = RecordingStorageWriter()
        let storage = StorageManager(
            baseDirectory: base,
            debounceInterval: 60,
            writer: { data, url in try recorder.write(data, to: url) }
        )
        for revision in 1...100 {
            storage.saveSnapshot(StorageSnapshot(
                revision: Int64(revision),
                items: [StashItem(type: .text, content: "\(revision)", preview: "\(revision)")],
                importJobs: []
            ))
        }
        try storage.flushSynchronously()
        try expect(recorder.snapshot == [100], "Debounce did not collapse snapshots to the latest revision")
        guard case .loaded(let latest) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Coalesced snapshot did not load")
        }
        try expect(latest.revision == 100, "Flush did not persist the latest revision")
        try expect(latest.items.first?.content == "100", "Flush persisted stale item data")

        var completedJob = ImportJob(sourceURLs: [URL(fileURLWithPath: "/tmp/completed")])
        completedJob.state = .completed
        var retryableJob = ImportJob(sourceURLs: [URL(fileURLWithPath: "/tmp/retryable")])
        retryableJob.state = .failed
        retryableJob.retryURLs = retryableJob.sourceURLs
        try storage.flushSynchronously(StorageSnapshot(
            revision: 101,
            items: latest.items,
            importJobs: [completedJob, retryableJob]
        ))
        guard case .loaded(let durableJobsSnapshot) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Durable import jobs did not load")
        }
        try expect(
            durableJobsSnapshot.importJobs.map(\.id) == [retryableJob.id],
            "Completed import history was persisted or retryable work was dropped"
        )

        let inFlightBase = root.appendingPathComponent("in-flight-storage", isDirectory: true)
        let blockingWriter = BlockingFirstStorageWriter()
        let inFlightStorage = StorageManager(
            baseDirectory: inFlightBase,
            debounceInterval: 0,
            writer: { data, url in try blockingWriter.write(data, to: url) }
        )
        inFlightStorage.saveSnapshot(StorageSnapshot(revision: 1, items: [], importJobs: []))
        blockingWriter.firstWriteStarted.wait()
        inFlightStorage.saveSnapshot(StorageSnapshot(revision: 2, items: [], importJobs: []))
        inFlightStorage.saveSnapshot(StorageSnapshot(
            revision: 3,
            items: [StashItem(type: .text, content: "latest", preview: "latest")],
            importJobs: []
        ))
        blockingWriter.allowFirstWrite.signal()
        try inFlightStorage.flushSynchronously()
        try expect(blockingWriter.snapshot == [1, 3], "In-flight writer did not retain only the latest follow-up")
        guard case .loaded(let inFlightLatest) = inFlightStorage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("In-flight latest snapshot did not load")
        }
        try expect(inFlightLatest.revision == 3, "Older in-flight write overwrote the latest revision")

        let retryBase = root.appendingPathComponent("retry-storage", isDirectory: true)
        let failOnceWriter = FailOnceStorageWriter()
        let retryStorage = StorageManager(
            baseDirectory: retryBase,
            debounceInterval: 0,
            retryInterval: 60,
            writer: { data, url in try failOnceWriter.write(data, to: url) }
        )
        retryStorage.saveSnapshot(StorageSnapshot(revision: 4, items: latest.items, importJobs: []))
        failOnceWriter.firstAttemptFinished.wait()
        try retryStorage.flushSynchronously()
        guard case .loaded(let retried) = retryStorage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Flush did not retry the failed pending snapshot")
        }
        try expect(retried.revision == 4, "Flush lost the pending snapshot after a write failure")

        let futureBase = root.appendingPathComponent("future-storage", isDirectory: true)
        let futureURL = futureBase.appendingPathComponent("QuickStash/items.json")
        try FileManager.default.createDirectory(at: futureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureData = Data(#"{"schemaVersion":999,"revision":77,"items":[]}"#.utf8)
        try futureData.write(to: futureURL)
        let futureStorage = StorageManager(baseDirectory: futureBase)
        guard case .unsupported(let version) = futureStorage.loadSnapshotSynchronously(), version == 999 else {
            throw TestFailure.assertion("Future schema was not rejected")
        }
        do {
            try futureStorage.flushSynchronously(StorageSnapshot(revision: 78, items: [], importJobs: []))
            throw TestFailure.assertion("Future schema was overwritten")
        } catch let error as TestFailure {
            throw error
        } catch {
            // Expected read-only protection.
        }
        let preservedFutureData = try Data(contentsOf: futureURL)
        try expect(preservedFutureData == futureData, "Future schema bytes changed")
    }

    private static func testCorruptBackupFailureBlocksWrites(in root: URL) throws {
        let base = root.appendingPathComponent("corrupt-backup-failure", isDirectory: true)
        let storageURL = base.appendingPathComponent("QuickStash/items.json")
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("corrupt-metadata-must-survive".utf8)
        try original.write(to: storageURL)
        let writeCounter = WriteCounter()
        let storage = StorageManager(
            baseDirectory: base,
            fileStore: BackupFailingStorageFileStore(),
            writer: { _, _ in writeCounter.increment() }
        )
        guard case .corrupt(let backupURL) = storage.loadSnapshotSynchronously(), backupURL == nil else {
            throw TestFailure.assertion("Backup failure was not reported as protected corruption")
        }
        storage.saveSnapshot(StorageSnapshot(revision: 1, items: [], importJobs: []))
        do {
            try storage.flushSynchronously(StorageSnapshot(revision: 2, items: [], importJobs: []))
            throw TestFailure.assertion("Corrupt metadata with no backup was writable")
        } catch let error as TestFailure {
            throw error
        } catch {
            // Expected write protection.
        }
        try expect(writeCounter.value == 0, "Protected corruption reached the writer")
        let preserved = try Data(contentsOf: storageURL)
        try expect(preserved == original, "Protected corrupt bytes changed")
    }

    private static func testAutomaticRetryNotifiesSuccess(in root: URL) async throws {
        let base = root.appendingPathComponent("automatic-retry-callback", isDirectory: true)
        let writer = FailOnceStorageWriter()
        let recorder = await MainActor.run { StorageCallbackRecorder() }
        let storage = StorageManager(
            baseDirectory: base,
            debounceInterval: 0,
            retryInterval: 0.01,
            writer: { data, url in try writer.write(data, to: url) }
        )
        storage.saveSnapshot(StorageSnapshot(revision: 1, items: [], importJobs: [])) { error in
            recorder.append(error)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let values = await MainActor.run { recorder.failures }
            if values.count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let values = await MainActor.run { recorder.failures }
        try expect(values == [true, false], "Automatic retry did not notify failure then durable success: \(values)")
        guard case .loaded(let snapshot) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Automatically retried snapshot did not load")
        }
        try expect(snapshot.revision == 1, "Automatic retry persisted the wrong revision")
    }

    private static func testCorruptStorageBackup(in root: URL) throws {
        let base = root.appendingPathComponent("corrupt", isDirectory: true)
        let storage = StorageManager(baseDirectory: base, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let storageURL = base
            .appendingPathComponent("QuickStash", isDirectory: true)
            .appendingPathComponent("items.json")
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: storageURL, options: .atomic)

        guard case .corrupt(let backupURL) = storage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Corrupt storage was not detected")
        }
        try expect(backupURL != nil, "Corrupt storage was not backed up")
        try expect(FileManager.default.fileExists(atPath: backupURL!.path), "Corrupt backup is missing")
        let secondStorage = StorageManager(baseDirectory: base, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        guard case .corrupt(let secondBackupURL) = secondStorage.loadSnapshotSynchronously() else {
            throw TestFailure.assertion("Second corrupt load did not create a backup")
        }
        try expect(secondBackupURL != backupURL, "Same-second corrupt backups collided")
        try expect(FileManager.default.fileExists(atPath: secondBackupURL!.path), "Second corrupt backup is missing")
    }

    private static func testManagedImportAndDeletion(in root: URL) async throws {
        let base = root.appendingPathComponent("files", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("report.pdf")
        try Data("test-pdf".utf8).write(to: source)

        let manager = QuickStashFileManager(baseDirectory: base)
        let batch = await manager.importFiles([source, source])
        try expect(batch.failures.isEmpty, "Managed import unexpectedly failed")
        try expect(batch.items.count == 2, "Expected two imported items")
        try expect(batch.items.allSatisfy { $0.type == .pdf }, "Imported files were not classified")
        try expect(batch.items[0].content != batch.items[1].content, "Duplicate names collided")
        try expect(FileManager.default.fileExists(atPath: source.path), "Import removed the source file")

        for item in batch.items {
            try expect(manager.isManagedFile(at: item.content), "Imported path is outside managed roots")
            _ = try await manager.quarantineManagedFile(at: item.content)
            try expect(!FileManager.default.fileExists(atPath: item.content), "Managed file was not quarantined")
        }

        let external = sourceDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: external)
        do {
            _ = try await manager.quarantineManagedFile(at: external.path)
            throw TestFailure.assertion("External file deletion was allowed")
        } catch let error as TestFailure {
            throw error
        } catch {
            // Expected: paths outside QuickStash/Files and QuickStash/Images are rejected.
        }
        try expect(FileManager.default.fileExists(atPath: external.path), "External file was deleted")

        let symlink = sourceDirectory.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let symlinkBatch = await manager.importFiles([symlink])
        try expect(symlinkBatch.items.isEmpty, "Symbolic link import was allowed")
        try expect(symlinkBatch.failures.count == 1, "Symbolic link rejection was not reported")

        let folder = sourceDirectory.appendingPathComponent("folder", isDirectory: true)
        let nestedFolder = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: nestedFolder.appendingPathComponent("two.txt"))
        let folderBatch = await manager.importFiles([folder])
        try expect(folderBatch.failures.isEmpty, "Safe directory import unexpectedly failed")
        try expect(folderBatch.items.count == 1, "Safe directory import did not create one item")
        let importedFolder = URL(fileURLWithPath: folderBatch.items[0].content)
        try expect(
            FileManager.default.fileExists(atPath: importedFolder.appendingPathComponent("nested/two.txt").path),
            "Safe directory import lost nested contents"
        )
        _ = try await manager.quarantineManagedFile(at: folderBatch.items[0].content)
    }

    private static func testImportLimitsAndCapacity(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("limit-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let first = sourceDirectory.appendingPathComponent("first.bin")
        let second = sourceDirectory.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 8).write(to: first)
        try Data(repeating: 2, count: 8).write(to: second)

        let singleLimitManager = QuickStashFileManager(
            baseDirectory: root.appendingPathComponent("single-limit", isDirectory: true),
            importPolicy: policy(maximumSingleItemBytes: 4),
            availableCapacityProvider: { _ in Int64.max }
        )
        let singleLimitBatch = await singleLimitManager.importFiles([first])
        try expect(singleLimitBatch.items.isEmpty, "Oversized single item was imported")
        try expect(singleLimitBatch.failures.first?.kind == .limitExceeded, "Single-item limit was not reported")
        try expect(singleLimitBatch.retryURLs == [first], "Single-item retry URL was not retained")

        let batchLimitManager = QuickStashFileManager(
            baseDirectory: root.appendingPathComponent("batch-limit", isDirectory: true),
            importPolicy: policy(maximumSingleItemBytes: 16, maximumBatchBytes: 12),
            availableCapacityProvider: { _ in Int64.max }
        )
        let batchLimitBatch = await batchLimitManager.importFiles([first, second])
        try expect(batchLimitBatch.items.isEmpty, "Oversized batch was imported")
        try expect(batchLimitBatch.failures.count == 2, "Batch limit did not retain every source error")
        try expect(batchLimitBatch.failures.allSatisfy { $0.kind == .limitExceeded }, "Batch limit failure kind changed")

        let diskManager = QuickStashFileManager(
            baseDirectory: root.appendingPathComponent("disk-limit", isDirectory: true),
            importPolicy: policy(),
            availableCapacityProvider: { _ in 7 }
        )
        let diskBatch = await diskManager.importFiles([first])
        try expect(diskBatch.items.isEmpty, "Import ignored insufficient disk space")
        try expect(diskBatch.failures.first?.kind == .insufficientDiskSpace, "Disk-space failure kind changed")

        let quotaBase = root.appendingPathComponent("quota-limit", isDirectory: true)
        let existingImages = quotaBase
            .appendingPathComponent("QuickStash", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: existingImages, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 10).write(to: existingImages.appendingPathComponent("existing.png"))
        let quotaManager = QuickStashFileManager(
            baseDirectory: quotaBase,
            importPolicy: policy(storageQuotaBytes: 12),
            availableCapacityProvider: { _ in Int64.max }
        )
        let quotaBatch = await quotaManager.importFiles([first])
        try expect(quotaBatch.items.isEmpty, "Import ignored application storage quota")
        try expect(quotaBatch.failures.first?.kind == .quotaExceeded, "Quota failure kind changed")

        let tree = sourceDirectory.appendingPathComponent("large-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data([1]).write(to: tree.appendingPathComponent("one"))
        try Data([2]).write(to: tree.appendingPathComponent("two"))
        let entryManager = QuickStashFileManager(
            baseDirectory: root.appendingPathComponent("entry-limit", isDirectory: true),
            importPolicy: policy(maximumEntries: 2),
            availableCapacityProvider: { _ in Int64.max }
        )
        let entryBatch = await entryManager.importFiles([tree])
        try expect(entryBatch.items.isEmpty, "Recursive entry limit was ignored")
        try expect(entryBatch.failures.first?.kind == .limitExceeded, "Entry-limit failure kind changed")
    }

    private static func testNestedUnsafeEntriesAreRejected(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("unsafe-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("unsafe-target.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: sourceDirectory.appendingPathComponent("nested-link"),
            withDestinationURL: target
        )

        let manager = QuickStashFileManager(
            baseDirectory: root.appendingPathComponent("unsafe-import", isDirectory: true),
            importPolicy: policy(),
            availableCapacityProvider: { _ in Int64.max }
        )
        let symlinkBatch = await manager.importFiles([sourceDirectory])
        try expect(symlinkBatch.items.isEmpty, "Nested symbolic link import was allowed")
        try expect(symlinkBatch.failures.first?.kind == .invalidSource, "Nested symbolic link failure was not classified")

        let fifoDirectory = root.appendingPathComponent("fifo-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
        let fifo = fifoDirectory.appendingPathComponent("named-pipe")
        let fifoResult = fifo.path.withCString { mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) }
        try expect(fifoResult == 0, "Could not create FIFO fixture")
        let fifoBatch = await manager.importFiles([fifoDirectory])
        try expect(fifoBatch.items.isEmpty, "FIFO import was allowed")
        try expect(fifoBatch.failures.first?.kind == .invalidSource, "FIFO failure was not classified")
    }

    private static func testImportProgressAndCancellationRollback(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("cancel-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let small = sourceDirectory.appendingPathComponent("first.txt")
        let large = sourceDirectory.appendingPathComponent("large.bin")
        try Data("first".utf8).write(to: small)
        try Data(repeating: 7, count: 32 * 1_024 * 1_024).write(to: large)

        let base = root.appendingPathComponent("cancel-import", isDirectory: true)
        let token = ImportCancellationToken()
        let capacityScript = CapacityScript(token: token, cancelOnCall: 4)
        let manager = QuickStashFileManager(
            baseDirectory: base,
            importPolicy: policy(maximumSingleItemBytes: 64 * 1_024 * 1_024, maximumBatchBytes: 64 * 1_024 * 1_024),
            availableCapacityProvider: { _ in capacityScript.capacity() }
        )
        let recorder = ProgressRecorder()
        let batch = await manager.importFiles([small, large], cancellationToken: token) { progress in
            recorder.append(progress)
        }

        try expect(batch.wasCancelled, "Cancellation was not reported")
        try expect(batch.items.isEmpty, "Cancelled batch returned metadata items")
        try expect(batch.retryURLs == [small, large], "Cancelled batch did not retain original URLs")
        let appRoot = base.appendingPathComponent("QuickStash", isDirectory: true)
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: appRoot.appendingPathComponent("Files", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let stagingFiles = try FileManager.default.contentsOfDirectory(
            at: appRoot.appendingPathComponent("Importing", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(storedFiles.isEmpty, "Cancellation did not roll back completed files")
        try expect(stagingFiles.isEmpty, "Cancellation left a .partial file or tree")
        try expect(FileManager.default.fileExists(atPath: small.path), "Cancellation removed a source file")
        try expect(FileManager.default.fileExists(atPath: large.path), "Cancellation removed a source file")

        let progressValues = recorder.snapshot
        try expect(progressValues.contains { $0.phase == .preflighting }, "Preflight progress was not emitted")
        try expect(progressValues.contains { $0.phase == .importing && $0.totalItems == 2 }, "Item progress was not emitted")
        try expect(progressValues.contains { $0.completedBytes > 0 && $0.totalBytes > 0 }, "Byte progress was not emitted")
    }

    private static func testPostPreflightGrowthIsStopped(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("growth-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("growing.bin")
        try Data(repeating: 1, count: 512 * 1_024).write(to: source)

        let base = root.appendingPathComponent("growth-import", isDirectory: true)
        let capacity = CapacityScript(actionOnCall: 2) {
            if let handle = try? FileHandle(forWritingTo: source) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(repeating: 2, count: 2 * 1_024 * 1_024))
                try? handle.close()
            }
        }
        let manager = QuickStashFileManager(
            baseDirectory: base,
            importPolicy: policy(
                maximumSingleItemBytes: 1 * 1_024 * 1_024,
                maximumBatchBytes: 4 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in capacity.capacity() }
        )
        let batch = await manager.importFiles([source])

        try expect(batch.items.isEmpty, "A source that grew past the hard limit was imported")
        try expect(batch.failures.first?.kind == .limitExceeded, "Post-preflight growth was not classified as a limit failure")
        let staging = base
            .appendingPathComponent("QuickStash", isDirectory: true)
            .appendingPathComponent("Importing", isDirectory: true)
        let stagingFiles = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        try expect(stagingFiles.isEmpty, "Hard-limit abort left a .partial file")
    }

    private static func testPostPreflightSymlinkIsStopped(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("late-link-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: sourceDirectory.appendingPathComponent("safe.txt"))
        let externalTarget = root.appendingPathComponent("late-link-target.txt")
        try Data("private".utf8).write(to: externalTarget)

        let base = root.appendingPathComponent("late-link-import", isDirectory: true)
        let lateLink = sourceDirectory.appendingPathComponent("late-link")
        let capacity = CapacityScript(actionOnCall: 2) {
            try? FileManager.default.createSymbolicLink(at: lateLink, withDestinationURL: externalTarget)
        }
        let manager = QuickStashFileManager(
            baseDirectory: base,
            importPolicy: policy(),
            availableCapacityProvider: { _ in capacity.capacity() }
        )
        let batch = await manager.importFiles([sourceDirectory])

        try expect(batch.items.isEmpty, "A symbolic link added after preflight was imported")
        try expect(batch.failures.first?.kind == .invalidSource, "Late symbolic link failure was not classified")
        let appRoot = base.appendingPathComponent("QuickStash", isDirectory: true)
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: appRoot.appendingPathComponent("Files", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let stagingFiles = try FileManager.default.contentsOfDirectory(
            at: appRoot.appendingPathComponent("Importing", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(storedFiles.isEmpty, "Late symbolic link abort left a managed item")
        try expect(stagingFiles.isEmpty, "Late symbolic link abort left a .partial tree")
    }

    private static func testResourceForkLimits(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("resource-fork-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("fork-only.bin")
        try Data().write(to: source)
        try writeResourceFork(at: source, byteCount: 8 * 1_024 * 1_024)

        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        try expect(sourceValues.fileSize == 0, "Resource-fork fixture unexpectedly has a data fork")
        try expect(
            (sourceValues.totalFileAllocatedSize ?? 0) >= 8 * 1_024 * 1_024,
            "Resource-fork fixture was not allocated"
        )

        let limitedBase = root.appendingPathComponent("resource-fork-limited", isDirectory: true)
        let limitedManager = QuickStashFileManager(
            baseDirectory: limitedBase,
            importPolicy: policy(
                maximumSingleItemBytes: 1 * 1_024 * 1_024,
                maximumBatchBytes: 1 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let limitedBatch = await limitedManager.importFiles([source])
        try expect(limitedBatch.items.isEmpty, "Resource fork bypassed the 1 MiB item limit")
        try expect(limitedBatch.failures.first?.kind == .limitExceeded, "Resource-fork limit failure changed kind")
        let limitedFiles = try FileManager.default.contentsOfDirectory(
            at: limitedBase.appendingPathComponent("QuickStash/Files", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(limitedFiles.isEmpty, "Rejected resource fork left a managed file")

        let preservingManager = QuickStashFileManager(
            baseDirectory: root.appendingPathComponent("resource-fork-preserved", isDirectory: true),
            importPolicy: policy(
                maximumSingleItemBytes: 16 * 1_024 * 1_024,
                maximumBatchBytes: 16 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let preservingBatch = await preservingManager.importFiles([source])
        try expect(preservingBatch.failures.isEmpty, "Allowed resource-fork import failed")
        try expect(preservingBatch.items.count == 1, "Allowed resource-fork import lost its item")
        let destination = URL(fileURLWithPath: preservingBatch.items[0].content)
        let destinationValues = try destination.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        try expect(destinationValues.fileSize == 0, "Resource-fork import changed the data fork")
        try expect(
            (destinationValues.totalFileAllocatedSize ?? 0) >= 8 * 1_024 * 1_024,
            "COPYFILE_ALL did not preserve the resource fork"
        )

        let lateSource = sourceDirectory.appendingPathComponent("late-fork.bin")
        try Data().write(to: lateSource)
        let lateCapacity = CapacityScript(actionOnCall: 2) {
            do {
                try writeResourceFork(at: lateSource, byteCount: 8 * 1_024 * 1_024)
            } catch {
                assertionFailure("Could not inject postflight resource fork: \(error)")
            }
        }
        let lateBase = root.appendingPathComponent("resource-fork-postflight", isDirectory: true)
        let lateManager = QuickStashFileManager(
            baseDirectory: lateBase,
            importPolicy: policy(
                maximumSingleItemBytes: 1 * 1_024 * 1_024,
                maximumBatchBytes: 1 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in lateCapacity.capacity() }
        )
        let lateBatch = await lateManager.importFiles([lateSource])
        (lateSource as NSURL).removeAllCachedResourceValues()
        let lateValues = try lateSource.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        try expect(
            (lateValues.totalFileAllocatedSize ?? 0) >= 8 * 1_024 * 1_024,
            "Postflight resource-fork fixture was not injected after \(lateCapacity.callCount) capacity checks"
        )
        try expect(lateBatch.items.isEmpty, "Resource fork added after preflight bypassed postflight limits")
        try expect(lateBatch.failures.first?.kind == .limitExceeded, "Postflight resource-fork failure changed kind")
        let lateStaging = try FileManager.default.contentsOfDirectory(
            at: lateBase.appendingPathComponent("QuickStash/Importing", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(lateStaging.isEmpty, "Postflight resource-fork rejection left a partial")
    }

    private static func testExtendedAttributeLimits(in root: URL) async throws {
        let byteCount = 8 * 1_024 * 1_024
        let sourceDirectory = root.appendingPathComponent("xattr-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let source = sourceDirectory.appendingPathComponent("xattr-only.bin")
        try Data().write(to: source)
        try writeExtendedAttribute(at: source, byteCount: byteCount, byte: 0x37)
        let sourceAttributeSize = try extendedAttributeSize(at: source)
        try expect(
            sourceAttributeSize == byteCount,
            "Ordinary extended-attribute fixture was not written"
        )

        let limitedBase = root.appendingPathComponent("xattr-file-limited", isDirectory: true)
        let limitedManager = QuickStashFileManager(
            baseDirectory: limitedBase,
            importPolicy: policy(
                maximumSingleItemBytes: 1 * 1_024 * 1_024,
                maximumBatchBytes: 1 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let limitedBatch = await limitedManager.importFiles([source])
        try expect(limitedBatch.items.isEmpty, "Ordinary xattr bypassed the 1 MiB file limit")
        try expect(limitedBatch.failures.first?.kind == .limitExceeded, "Ordinary xattr limit failure changed kind")

        let attributedDirectory = sourceDirectory.appendingPathComponent("directory-xattr", isDirectory: true)
        try FileManager.default.createDirectory(at: attributedDirectory, withIntermediateDirectories: true)
        try writeExtendedAttribute(at: attributedDirectory, byteCount: byteCount, byte: 0x48)
        let directoryBase = root.appendingPathComponent("xattr-directory-limited", isDirectory: true)
        let directoryManager = QuickStashFileManager(
            baseDirectory: directoryBase,
            importPolicy: policy(
                maximumSingleItemBytes: 1 * 1_024 * 1_024,
                maximumBatchBytes: 1 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let directoryBatch = await directoryManager.importFiles([attributedDirectory])
        try expect(directoryBatch.items.isEmpty, "A directory's own xattr bypassed the 1 MiB limit")
        try expect(directoryBatch.failures.first?.kind == .limitExceeded, "Directory xattr limit failure changed kind")

        let preservingBase = root.appendingPathComponent("xattr-preserved", isDirectory: true)
        let preservingManager = QuickStashFileManager(
            baseDirectory: preservingBase,
            importPolicy: policy(
                maximumSingleItemBytes: 16 * 1_024 * 1_024,
                maximumBatchBytes: 16 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let preservingBatch = await preservingManager.importFiles([source])
        try expect(preservingBatch.failures.isEmpty, "Allowed ordinary-xattr import failed")
        try expect(preservingBatch.items.count == 1, "Allowed ordinary-xattr import lost its item")
        let destination = URL(fileURLWithPath: preservingBatch.items[0].content)
        let copiedAttribute = try readExtendedAttribute(at: destination)
        try expect(copiedAttribute.count == byteCount, "COPYFILE_ALL truncated the ordinary xattr")
        try expect(
            copiedAttribute == Data(repeating: 0x37, count: byteCount),
            "COPYFILE_ALL changed the ordinary xattr payload"
        )

        let quotaCandidate = sourceDirectory.appendingPathComponent("quota-candidate.txt")
        try Data("candidate".utf8).write(to: quotaCandidate)
        let quotaManager = QuickStashFileManager(
            baseDirectory: preservingBase,
            importPolicy: policy(
                maximumSingleItemBytes: 16 * 1_024 * 1_024,
                maximumBatchBytes: 16 * 1_024 * 1_024,
                storageQuotaBytes: 1 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let quotaBatch = await quotaManager.importFiles([quotaCandidate])
        try expect(quotaBatch.items.isEmpty, "Existing ordinary xattr bypassed the storage quota")
        try expect(quotaBatch.failures.first?.kind == .quotaExceeded, "Existing-xattr quota failure changed kind")

        let lateSource = sourceDirectory.appendingPathComponent("late-xattr.bin")
        try Data().write(to: lateSource)
        let lateCapacity = CapacityScript(actionOnCall: 2) {
            do {
                try writeExtendedAttribute(at: lateSource, byteCount: byteCount, byte: 0x59)
            } catch {
                assertionFailure("Could not inject postflight ordinary xattr: \(error)")
            }
        }
        let lateBase = root.appendingPathComponent("xattr-postflight", isDirectory: true)
        let lateManager = QuickStashFileManager(
            baseDirectory: lateBase,
            importPolicy: policy(
                maximumSingleItemBytes: 1 * 1_024 * 1_024,
                maximumBatchBytes: 1 * 1_024 * 1_024
            ),
            availableCapacityProvider: { _ in lateCapacity.capacity() }
        )
        let lateBatch = await lateManager.importFiles([lateSource])
        let lateAttributeSize = try extendedAttributeSize(at: lateSource)
        try expect(
            lateAttributeSize == byteCount,
            "Postflight ordinary-xattr fixture was not injected after \(lateCapacity.callCount) capacity checks"
        )
        try expect(lateBatch.items.isEmpty, "An ordinary xattr added after preflight bypassed postflight limits")
        try expect(lateBatch.failures.first?.kind == .limitExceeded, "Postflight ordinary-xattr failure changed kind")
        let lateStaging = try FileManager.default.contentsOfDirectory(
            at: lateBase.appendingPathComponent("QuickStash/Importing", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(lateStaging.isEmpty, "Postflight ordinary-xattr rejection left a partial")
    }

    private static func testExtendedAttributeNameListLimits(in root: URL) async throws {
        let limit = 1 * 1_024 * 1_024
        let sourceDirectory = root.appendingPathComponent("xattr-name-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let file = sourceDirectory.appendingPathComponent("many-xattr-names.bin")
        try Data().write(to: file)
        let fileNameBytes = try writeZeroLengthExtendedAttributes(
            at: file,
            exceedingNameListBytes: limit
        )
        try expect(fileNameBytes > limit, "File xattr name-list fixture did not exceed 1 MiB")
        let fileBase = root.appendingPathComponent("xattr-name-file-limited", isDirectory: true)
        let fileManager = QuickStashFileManager(
            baseDirectory: fileBase,
            importPolicy: policy(
                maximumSingleItemBytes: Int64(limit),
                maximumBatchBytes: Int64(limit)
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let fileBatch = await fileManager.importFiles([file])
        try expect(fileBatch.items.isEmpty, "File xattr names bypassed the 1 MiB item limit")
        try expect(fileBatch.failures.first?.kind == .limitExceeded, "File xattr-name failure changed kind")
        try expectImportDirectoriesEmpty(in: fileBase, context: "File xattr-name rejection")

        let directory = sourceDirectory.appendingPathComponent("many-directory-xattr-names", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryNameBytes = try writeZeroLengthExtendedAttributes(
            at: directory,
            exceedingNameListBytes: limit
        )
        try expect(directoryNameBytes > limit, "Directory xattr name-list fixture did not exceed 1 MiB")
        let directoryBase = root.appendingPathComponent("xattr-name-directory-limited", isDirectory: true)
        let directoryManager = QuickStashFileManager(
            baseDirectory: directoryBase,
            importPolicy: policy(
                maximumSingleItemBytes: Int64(limit),
                maximumBatchBytes: Int64(limit)
            ),
            availableCapacityProvider: { _ in Int64.max }
        )
        let directoryBatch = await directoryManager.importFiles([directory])
        try expect(directoryBatch.items.isEmpty, "Directory xattr names bypassed the 1 MiB item limit")
        try expect(directoryBatch.failures.first?.kind == .limitExceeded, "Directory xattr-name failure changed kind")
        try expectImportDirectoriesEmpty(in: directoryBase, context: "Directory xattr-name rejection")
    }

    private static func testCleanupFailuresNeedRecovery(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("cleanup-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let large = sourceDirectory.appendingPathComponent("large.bin")
        try Data(repeating: 4, count: 24 * 1_024 * 1_024).write(to: large)

        let partialToken = ImportCancellationToken()
        let partialCapacity = CapacityScript(token: partialToken, cancelOnCall: 2)
        let partialBase = root.appendingPathComponent("partial-cleanup-failure", isDirectory: true)
        let partialManager = QuickStashFileManager(
            baseDirectory: partialBase,
            importPolicy: policy(),
            availableCapacityProvider: { _ in partialCapacity.capacity() },
            cleanupFaultInjector: { operation in
                if operation.kind == .stagingRemoval { throw InjectedCleanupError() }
            }
        )
        let partialBatch = await partialManager.importFiles([large], cancellationToken: partialToken)
        try expect(partialBatch.wasCancelled, "Injected partial cleanup case was not cancelled")
        try expect(partialBatch.needsRecovery, "Partial cleanup failure was hidden")
        try expect(!partialBatch.cleanupFailures.isEmpty, "Partial cleanup failure path was not retained")
        let remainingPartials = try FileManager.default.contentsOfDirectory(
            at: partialBase.appendingPathComponent("QuickStash/Importing", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(!remainingPartials.isEmpty, "Partial cleanup fault did not exercise recovery state")

        let small = sourceDirectory.appendingPathComponent("small.txt")
        try Data("committed".utf8).write(to: small)
        let rollbackToken = ImportCancellationToken()
        let rollbackCapacity = CapacityScript(token: rollbackToken, cancelOnCall: 4)
        let rollbackBase = root.appendingPathComponent("rollback-cleanup-failure", isDirectory: true)
        let rollbackManager = QuickStashFileManager(
            baseDirectory: rollbackBase,
            importPolicy: policy(),
            availableCapacityProvider: { _ in rollbackCapacity.capacity() },
            cleanupFaultInjector: { operation in
                if operation.kind == .committedRemoval || operation.kind == .committedQuarantine {
                    throw InjectedCleanupError()
                }
            }
        )
        let rollbackBatch = await rollbackManager.importFiles([small, large], cancellationToken: rollbackToken)
        try expect(rollbackBatch.wasCancelled, "Injected final rollback case was not cancelled")
        try expect(rollbackBatch.needsRecovery, "Final rollback failure was hidden")
        let remainingCommitted = try FileManager.default.contentsOfDirectory(
            at: rollbackBase.appendingPathComponent("QuickStash/Files", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(remainingCommitted.count == 1, "Final rollback fault did not leave the expected recovery item")
        guard let rollbackManifestID = rollbackBatch.manifestID else {
            throw TestFailure.assertion("Cancelled cleanup failure did not retain its manifest")
        }
        var cleanupJob = ImportJob(sourceURLs: [small, large])
        cleanupJob.state = .cancelled
        cleanupJob.cleanupFailures = rollbackBatch.cleanupFailures
        cleanupJob.recoveryManifestID = rollbackManifestID
        let stillFailingRecovery = await rollbackManager.recoverManagedFiles(
            referencedBy: [],
            importJobs: [cleanupJob]
        )
        try expect(stillFailingRecovery.items.isEmpty, "Cancelled cleanup was recovered as a normal item")
        try expect(
            stillFailingRecovery.manifestIDsNeedingRecovery.contains(rollbackManifestID),
            "Still-failing cancelled cleanup lost needsRecovery"
        )
        try expect(
            !stillFailingRecovery.resolvedJobIDs.contains(cleanupJob.id),
            "Still-failing cleanup job was marked resolved"
        )

        let recoveryManager = QuickStashFileManager(
            baseDirectory: rollbackBase,
            importPolicy: policy(),
            availableCapacityProvider: { _ in Int64.max }
        )
        let resolvedRecovery = await recoveryManager.recoverManagedFiles(
            referencedBy: [],
            importJobs: [cleanupJob]
        )
        try expect(resolvedRecovery.items.isEmpty, "Resolved cancelled cleanup became a recovered item")
        try expect(resolvedRecovery.resolvedJobIDs.contains(cleanupJob.id), "Resolved cleanup job ID was not returned")
        try expect(
            resolvedRecovery.manifestIDsToAcknowledge.contains(rollbackManifestID),
            "Resolved cleanup manifest was acknowledged before metadata durability"
        )
    }

    private static func testInterruptedImportRecovery(in root: URL) async throws {
        let base = root.appendingPathComponent("interrupted-recovery", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("recovery-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("committed.pdf")
        try Data("committed-before-metadata".utf8).write(to: source)
        let manager = QuickStashFileManager(
            baseDirectory: base,
            importPolicy: policy(),
            availableCapacityProvider: { _ in Int64.max }
        )
        let batch = await manager.importFiles([source])
        try expect(batch.items.count == 1, "Recovery fixture did not import")
        try expect(batch.manifestID != nil, "Committed import did not retain a manifest")

        let orphanDirectory = manager.storageDirectory.appendingPathComponent("legacy-folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphanDirectory.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("nested".utf8).write(to: orphanDirectory.appendingPathComponent("nested/file.txt"))
        let imageOrphan = try await manager.saveClipboardImage(data: Data([9, 8, 7]), fileExtension: "png")
        let imageOrphanName = URL(fileURLWithPath: imageOrphan.content).lastPathComponent
        let missingPath = manager.storageDirectory.appendingPathComponent("missing-pinned.txt").path
        let missing = StashItem(
            type: .file,
            content: missingPath,
            preview: "missing",
            isPinned: true,
            managedOrigin: .legacyUnknown
        )

        let committedPath = batch.items[0].content
        let retainedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let duplicateUnpinned = StashItem(
            id: retainedID,
            type: .pdf,
            content: committedPath,
            preview: "deterministic-retained"
        )
        let duplicatePinned = StashItem(
            id: duplicateID,
            type: .pdf,
            content: committedPath,
            preview: "duplicate",
            isPinned: true
        )
        let recovered = await manager.recoverManagedFiles(referencedBy: [
            missing,
            duplicatePinned,
            duplicateUnpinned
        ])
        try expect(
            recovered.items.contains { $0.content == committedPath && $0.managedOrigin == .imported },
            "Final move before metadata was not recovered from its manifest"
        )
        let deduplicated = recovered.items.filter { $0.content == committedPath }
        try expect(deduplicated.count == 1, "Stored managed-path duplicates were not collapsed")
        try expect(deduplicated[0].id == retainedID, "Managed-path dedupe was not deterministic")
        try expect(deduplicated[0].isPinned, "Managed-path dedupe did not merge pinned state")
        try expect(
            recovered.items.filter {
                URL(fileURLWithPath: $0.content).standardizedFileURL.path
                    == orphanDirectory.standardizedFileURL.path
                    && $0.managedOrigin == .legacyUnknown
            }.count == 1,
            "Legacy directory recovery did not create exactly one top-level record"
        )
        try expect(
            recovered.items.filter {
                URL(fileURLWithPath: $0.content).lastPathComponent == imageOrphanName
                    && $0.type == .image
                    && $0.managedOrigin == .clipboard
            }.count == 1,
            "Images orphan was not recovered exactly once as clipboard content"
        )
        try expect(
            recovered.items.contains {
                $0.content == missingPath && $0.availability == .unavailable && $0.isPinned
            },
            "Missing metadata record did not remain pinned and unavailable"
        )

        let secondPass = await manager.recoverManagedFiles(referencedBy: recovered.items)
        try expect(
            Set(secondPass.items.map(\.content)).count == secondPass.items.count,
            "Recovery was not idempotent"
        )
        try expect(secondPass.items.count == recovered.items.count, "Second recovery pass changed item count")

        guard let imported = recovered.items.first(where: { $0.content == committedPath }) else {
            throw TestFailure.assertion("Recovered committed item disappeared")
        }
        _ = try await manager.quarantineManagedFile(at: imported.content)
        let afterDeletion = await manager.recoverManagedFiles(referencedBy: recovered.items)
        try expect(
            !afterDeletion.items.contains(where: { $0.content == imported.content }),
            "Deletion tombstone was converted into an unavailable record"
        )
    }

    private static func testDeletionTombstoneRecovery(in root: URL) async throws {
        let base = root.appendingPathComponent("deletion-tombstone-crash", isDirectory: true)
        let appRoot = base.appendingPathComponent("QuickStash", isDirectory: true)
        let files = appRoot.appendingPathComponent("Files", isDirectory: true)
        let trash = appRoot.appendingPathComponent("Trash", isDirectory: true)
        let manifests = appRoot.appendingPathComponent("DeletionManifests", isDirectory: true)
        for directory in [files, trash, manifests] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = files.appendingPathComponent("delete-after-manifest.txt")
        try Data("delete-intent".utf8).write(to: source)
        let manifestID = UUID()
        let destination = trash.appendingPathComponent("quarantined-delete-after-manifest.txt")
        let manifestURL = manifests.appendingPathComponent("\(manifestID.uuidString).json")
        try JSONEncoder().encode(DeletionManifestFixture(
            id: manifestID,
            originalPath: source.path,
            trashPath: destination.path
        )).write(to: manifestURL, options: [.atomic])
        let stored = StashItem(type: .file, content: source.path, preview: "delete", isPinned: true)
        let manager = QuickStashFileManager(baseDirectory: base)
        let recovered = await manager.recoverManagedFiles(referencedBy: [stored])
        try expect(!FileManager.default.fileExists(atPath: source.path), "Recovery did not complete tombstoned deletion")
        try expect(FileManager.default.fileExists(atPath: destination.path), "Recovered deletion was not quarantined")
        try expect(recovered.items.allSatisfy { $0.content != source.path }, "Tombstoned source re-entered metadata")
        try expect(recovered.manifestIDsToAcknowledge.contains(manifestID), "Deletion tombstone was not held for durable ack")
        try expect(FileManager.default.fileExists(atPath: manifestURL.path), "Deletion tombstone was removed before metadata durability")

        manager.acknowledgeRecoveryManifests([manifestID])
        _ = await manager.recoverManagedFiles(referencedBy: recovered.items)
        try expect(!FileManager.default.fileExists(atPath: manifestURL.path), "Durable deletion tombstone ack did not remove manifest")

        let failingBase = root.appendingPathComponent("deletion-tombstone-still-failing", isDirectory: true)
        let failingAppRoot = failingBase.appendingPathComponent("QuickStash", isDirectory: true)
        let failingFiles = failingAppRoot.appendingPathComponent("Files", isDirectory: true)
        let failingTrash = failingAppRoot.appendingPathComponent("Trash", isDirectory: true)
        let failingManifests = failingAppRoot.appendingPathComponent("DeletionManifests", isDirectory: true)
        for directory in [failingFiles, failingTrash, failingManifests] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let failingSource = failingFiles.appendingPathComponent("keep-tombstoned.txt")
        try Data("still-delete".utf8).write(to: failingSource)
        let failingID = UUID()
        try JSONEncoder().encode(DeletionManifestFixture(
            id: failingID,
            originalPath: failingSource.path,
            trashPath: failingTrash.appendingPathComponent("target.txt").path
        )).write(
            to: failingManifests.appendingPathComponent("\(failingID.uuidString).json"),
            options: [.atomic]
        )
        let failingManager = QuickStashFileManager(
            baseDirectory: failingBase,
            cleanupFaultInjector: { operation in
                if operation.kind == .committedQuarantine { throw InjectedCleanupError() }
            }
        )
        let failedRecovery = await failingManager.recoverManagedFiles(referencedBy: [
            StashItem(type: .file, content: failingSource.path, preview: "delete")
        ])
        try expect(failedRecovery.items.allSatisfy { $0.content != failingSource.path }, "Failed tombstone move leaked through orphan scan")
        try expect(failedRecovery.manifestIDsNeedingRecovery.contains(failingID), "Failed tombstone move lost recovery state")
        try expect(!failedRecovery.manifestIDsToAcknowledge.contains(failingID), "Failed tombstone was acknowledged")

        let tamperedBase = root.appendingPathComponent("tampered-deletion-manifest", isDirectory: true)
        let tamperedManifests = tamperedBase.appendingPathComponent(
            "QuickStash/DeletionManifests",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tamperedManifests, withIntermediateDirectories: true)
        let externalURL = URL(fileURLWithPath: "/tmp/quickstash-external-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: externalURL) }
        let externalBytes = Data("must-not-move".utf8)
        try externalBytes.write(to: externalURL)
        let tamperedID = UUID()
        let tamperedManifestURL = tamperedManifests.appendingPathComponent("\(tamperedID.uuidString).json")
        try JSONEncoder().encode(DeletionManifestFixture(
            id: tamperedID,
            originalPath: externalURL.path,
            trashPath: "/tmp/quickstash-invalid-trash-\(UUID().uuidString)"
        )).write(to: tamperedManifestURL, options: [.atomic])
        let corruptManifestURL = tamperedManifests.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corruptManifestURL)

        let tamperedManager = QuickStashFileManager(baseDirectory: tamperedBase)
        let tamperedRecovery = await tamperedManager.recoverManagedFiles(referencedBy: [])
        try expect(FileManager.default.fileExists(atPath: externalURL.path), "Tampered manifest moved an external file")
        let preservedExternalBytes = try Data(contentsOf: externalURL)
        try expect(preservedExternalBytes == externalBytes, "Tampered manifest changed external bytes")
        try expect(FileManager.default.fileExists(atPath: tamperedManifestURL.path), "Tampered manifest was removed")
        try expect(FileManager.default.fileExists(atPath: corruptManifestURL.path), "Corrupt manifest was removed")
        try expect(
            tamperedRecovery.manifestIDsNeedingRecovery.contains(tamperedID),
            "Tampered manifest did not retain recovery warning state"
        )
        try expect(
            tamperedRecovery.cleanupFailures.contains(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
                    == corruptManifestURL.standardizedFileURL.path
            }),
            "Corrupt deletion manifest did not produce a recovery warning"
        )
        try expect(
            !tamperedRecovery.manifestIDsToAcknowledge.contains(tamperedID),
            "Tampered deletion manifest was acknowledged"
        )
    }

    private static func testManifestCommitFailureRecovery(in root: URL) async throws {
        let sourceDirectory = root.appendingPathComponent("manifest-fault-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("manifest-fault.txt")
        try Data("manifest-fault".utf8).write(to: source)

        let rollbackBase = root.appendingPathComponent("manifest-fault-rollback", isDirectory: true)
        let rollbackManager = QuickStashFileManager(
            baseDirectory: rollbackBase,
            importPolicy: policy(),
            availableCapacityProvider: { _ in Int64.max },
            manifestFaultInjector: { operation in
                if operation.kind == .commit { throw InjectedCleanupError() }
            }
        )
        let rolledBack = await rollbackManager.importFiles([source])
        try expect(rolledBack.items.isEmpty, "Manifest commit failure returned a normal item")
        try expect(!rolledBack.failures.isEmpty, "Manifest commit failure was not reported")
        let rollbackFiles = try FileManager.default.contentsOfDirectory(
            at: rollbackBase.appendingPathComponent("QuickStash/Files", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(rollbackFiles.isEmpty, "Manifest commit failure did not roll back final file")
        let rollbackManifests = try FileManager.default.contentsOfDirectory(
            at: rollbackBase.appendingPathComponent("QuickStash/ImportManifests", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(rollbackManifests.isEmpty, "Successful rollback left a recovery manifest")

        let retainedBase = root.appendingPathComponent("manifest-fault-retained", isDirectory: true)
        let retainedManager = QuickStashFileManager(
            baseDirectory: retainedBase,
            importPolicy: policy(),
            availableCapacityProvider: { _ in Int64.max },
            cleanupFaultInjector: { operation in
                if operation.kind == .committedRemoval || operation.kind == .committedQuarantine {
                    throw InjectedCleanupError()
                }
            },
            manifestFaultInjector: { operation in
                if operation.kind == .commit { throw InjectedCleanupError() }
            }
        )
        let retained = await retainedManager.importFiles([source])
        guard let retainedManifestID = retained.manifestID else {
            throw TestFailure.assertion("Failed rollback dropped the prepared manifest")
        }
        try expect(retained.needsRecovery, "Failed rollback did not report needsRecovery")
        var recoveryJob = ImportJob(sourceURLs: [source])
        recoveryJob.state = .failed
        recoveryJob.cleanupFailures = retained.cleanupFailures
        recoveryJob.recoveryManifestID = retainedManifestID
        let stillFailing = await retainedManager.recoverManagedFiles(
            referencedBy: [],
            importJobs: [recoveryJob]
        )
        try expect(stillFailing.items.isEmpty, "Failed manifest rollback recovered final as a normal item")
        try expect(stillFailing.manifestIDsNeedingRecovery.contains(retainedManifestID), "Failed manifest rollback lost manifest")

        let resolvingManager = QuickStashFileManager(baseDirectory: retainedBase)
        let resolved = await resolvingManager.recoverManagedFiles(
            referencedBy: [],
            importJobs: [recoveryJob]
        )
        try expect(resolved.items.isEmpty, "Resolved manifest rollback produced an item")
        try expect(resolved.resolvedJobIDs.contains(recoveryJob.id), "Resolved manifest rollback omitted job ID")
    }

    private static func testCapacityDropDuringCopy(in root: URL) async throws {
        let source = root.appendingPathComponent("capacity-drop.bin")
        try Data(repeating: 5, count: 32 * 1_024 * 1_024).write(to: source)
        let capacity = CapacityScript(lowCapacityOnCall: 3)
        let base = root.appendingPathComponent("capacity-drop-import", isDirectory: true)
        let manager = QuickStashFileManager(
            baseDirectory: base,
            importPolicy: policy(minimumFreeSpaceBytes: 1),
            availableCapacityProvider: { _ in capacity.capacity() }
        )
        let batch = await manager.importFiles([source])
        try expect(batch.items.isEmpty, "Import ignored a runtime capacity drop")
        try expect(batch.failures.first?.kind == .insufficientDiskSpace, "Runtime capacity drop changed failure kind")
        try expect(capacity.callCount >= 3, "Capacity provider was not rechecked during copying")
        let stagingFiles = try FileManager.default.contentsOfDirectory(
            at: base.appendingPathComponent("QuickStash/Importing", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        try expect(stagingFiles.isEmpty, "Runtime capacity abort left a partial")
    }

    private static func testProgressRateLimit() throws {
        let recorder = ProgressRecorder()
        let emitter = FileImportProgressEmitter { recorder.append($0) }
        let progress = FileImportProgress(
            phase: .importing,
            completedBytes: 1,
            totalBytes: 100,
            completedItems: 0,
            totalItems: 1,
            currentItemName: "fixture"
        )
        for _ in 0..<100 {
            emitter.emit(progress)
        }
        emitter.finish()
        let times = recorder.timeSnapshot
        try expect(times.count == 2, "Progress limiter did not coalesce a burst")
        try expect(times[1] - times[0] >= 0.099, "Progress limiter exceeded 10 Hz")
    }

    private static func testImportJobStateReduction() throws {
        let url = URL(fileURLWithPath: "/tmp/retry-fixture")
        var retryJob = ImportJob(sourceURLs: [url])
        retryJob.state = .failed
        retryJob.retryURLs = [url]
        var consumedCount = 0
        for _ in 0..<10 where retryJob.consumeRetryURLs() != nil {
            consumedCount += 1
        }
        try expect(consumedCount == 1, "Retry URLs could be consumed more than once")
        try expect(retryJob.state == .retrying, "Retry did not lock the original job")
        try expect(!retryJob.canRetry, "Original job remained retryable")

        var progressJob = ImportJob(sourceURLs: [url])
        progressJob.apply(FileImportProgress(
            phase: .importing,
            completedBytes: 50,
            totalBytes: 100,
            completedItems: 0,
            totalItems: 1,
            currentItemName: "retry-fixture"
        ))
        try expect(progressJob.state == .importing, "Progress reducer did not update state")
        try expect(progressJob.completedBytes == 50 && progressJob.totalBytes == 100, "Progress reducer lost byte counts")

        var running = ImportJob(sourceURLs: [url], createdAt: Date(timeIntervalSince1970: 1))
        running.state = .importing
        var newestTerminal = ImportJob(sourceURLs: [url], createdAt: Date(timeIntervalSince1970: 5))
        newestTerminal.state = .completed
        let queued = ImportJob(sourceURLs: [url], createdAt: Date(timeIntervalSince1970: 2))
        var failed = ImportJob(sourceURLs: [url], createdAt: Date(timeIntervalSince1970: 4))
        failed.state = .failed
        let visible = ImportJobPresentation.visibleJobs(
            from: [newestTerminal, failed, queued, running],
            minimumCount: 3
        )
        try expect(visible.first?.id == running.id, "Running job was hidden by newer terminal jobs")
        try expect(visible.contains { $0.id == queued.id }, "Queued job was not prioritized after running work")

        let groupA = DailyGroup(id: "time:today", title: "今天", date: Date(), items: [], isLocked: false)
        let groupB = DailyGroup(id: "time:today", title: "今天", date: Date(), items: [], isLocked: false)
        try expect(groupA.id == groupB.id, "DailyGroup identity is not stable")
    }

    private static func writeResourceFork(at fileURL: URL, byteCount: Int) throws {
        let forkPath = fileURL.path + "/..namedfork/rsrc"
        let descriptor = forkPath.withCString {
            open($0, O_WRONLY | O_CREAT | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw TestFailure.assertion("Could not open resource fork fixture: \(errno)")
        }
        defer { close(descriptor) }

        let chunk = Data(repeating: 9, count: 1 * 1_024 * 1_024)
        var remaining = byteCount
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            let written = chunk.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, count)
            }
            guard written == count else {
                throw TestFailure.assertion("Could not write resource fork fixture: \(errno)")
            }
            remaining -= written
        }
    }

    private static let testExtendedAttributeName = "com.quickstash.tests.large-payload"

    private static func writeExtendedAttribute(at url: URL, byteCount: Int, byte: UInt8) throws {
        let payload = Data(repeating: byte, count: byteCount)
        let result = url.path.withCString { path in
            testExtendedAttributeName.withCString { name in
                payload.withUnsafeBytes { bytes in
                    setxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard result == 0 else {
            throw TestFailure.assertion("Could not write ordinary xattr fixture: \(errno)")
        }
    }

    private static func extendedAttributeSize(at url: URL) throws -> Int {
        let size = url.path.withCString { path in
            testExtendedAttributeName.withCString { name in
                getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        guard size >= 0 else {
            throw TestFailure.assertion("Could not read ordinary xattr size: \(errno)")
        }
        return size
    }

    private static func readExtendedAttribute(at url: URL) throws -> Data {
        let size = try extendedAttributeSize(at: url)
        var payload = Data(count: size)
        let readSize = url.path.withCString { path in
            testExtendedAttributeName.withCString { name in
                payload.withUnsafeMutableBytes { bytes in
                    getxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard readSize == size else {
            throw TestFailure.assertion("Could not read complete ordinary xattr payload: \(errno)")
        }
        return payload
    }

    private static func writeZeroLengthExtendedAttributes(
        at url: URL,
        exceedingNameListBytes minimumBytes: Int
    ) throws -> Int {
        var expectedNameListBytes = 0
        var index = 0
        while expectedNameListBytes <= minimumBytes {
            let prefix = "com.quickstash.tests.names.\(String(format: "%08d", index))."
            let name = prefix + String(repeating: "n", count: max(0, 120 - prefix.utf8.count))
            guard name.utf8.count <= Int(XATTR_MAXNAMELEN) else {
                throw TestFailure.assertion("Generated xattr fixture name is too long")
            }
            let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return name.withCString {
                    setxattr(path, $0, nil, 0, 0, XATTR_NOFOLLOW)
                }
            }
            guard result == 0 else {
                throw TestFailure.assertion(
                    "Could not write zero-length xattr fixture \(index): \(errno)"
                )
            }
            expectedNameListBytes += name.utf8.count + 1
            index += 1
        }

        let actualSize: Int = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return listxattr(path, nil, 0, XATTR_NOFOLLOW)
        }
        guard actualSize >= 0 else {
            throw TestFailure.assertion("Could not read xattr name-list fixture size: \(errno)")
        }
        return actualSize
    }

    private static func expectImportDirectoriesEmpty(in base: URL, context: String) throws {
        for directoryName in ["Files", "Importing"] {
            let contents = try FileManager.default.contentsOfDirectory(
                at: base.appendingPathComponent("QuickStash/\(directoryName)", isDirectory: true),
                includingPropertiesForKeys: nil
            )
            try expect(contents.isEmpty, "\(context) left content in \(directoryName)")
        }
    }

    private static func policy(
        maximumSourceItems: Int = 100,
        maximumEntries: Int = 1_000,
        maximumSingleItemBytes: Int64 = 128 * 1_024 * 1_024,
        maximumBatchBytes: Int64 = 256 * 1_024 * 1_024,
        storageQuotaBytes: Int64 = 512 * 1_024 * 1_024,
        minimumFreeSpaceBytes: Int64 = 0,
        diskHeadroomFraction: Double = 0
    ) -> ImportPolicy {
        ImportPolicy(
            maximumSourceItems: maximumSourceItems,
            maximumEntries: maximumEntries,
            maximumSingleItemBytes: maximumSingleItemBytes,
            maximumBatchBytes: maximumBatchBytes,
            storageQuotaBytes: storageQuotaBytes,
            minimumFreeSpaceBytes: minimumFreeSpaceBytes,
            diskHeadroomFraction: diskHeadroomFraction
        )
    }
}
