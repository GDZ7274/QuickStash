import Foundation

struct StorageSnapshot: Sendable, Equatable {
    var revision: Int64
    var items: [StashItem]
    var importJobs: [ImportJob]

    static let empty = StorageSnapshot(revision: 0, items: [], importJobs: [])
}

enum StorageLoadResult: Sendable {
    case missing
    case loaded(StorageSnapshot)
    case corrupt(backupURL: URL?)
    case unsupported(schemaVersion: Int)
}

enum StorageError: LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case corruptDataBackupFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "数据来自更高版本的 QuickStash（格式版本 \(version)），当前版本不会覆盖它"
        case .corruptDataBackupFailed:
            return "历史数据损坏且无法创建安全备份，当前版本不会覆盖原文件"
        }
    }
}

protocol StorageFileStore: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
}

final class LocalStorageFileStore: StorageFileStore, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
}

private struct StorageEnvelope: Codable {
    let schemaVersion: Int
    let revision: Int64
    let items: [StashItem]
    let importJobs: [ImportJob]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, items, importJobs
    }

    init(schemaVersion: Int, revision: Int64, items: [StashItem], importJobs: [ImportJob]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.items = items
        self.importJobs = importJobs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        items = try container.decode([StashItem].self, forKey: .items)
        importJobs = try container.decodeIfPresent([ImportJob].self, forKey: .importJobs) ?? []
    }
}

final class StorageManager: @unchecked Sendable {
    static let shared = StorageManager()
    static let currentSchemaVersion = 2

    typealias DataWriter = @Sendable (Data, URL) throws -> Void
    typealias Clock = @Sendable () -> Date

    private struct SaveWaiter {
        let revision: Int64
        let completion: @MainActor @Sendable (Error?) -> Void
        var hasReportedFailure = false
    }

    private let storageURL: URL
    private let fileStore: any StorageFileStore
    private let writer: DataWriter
    private let clock: Clock
    private let debounceInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let ioQueue = DispatchQueue(label: "com.quickstash.metadata-io", qos: .utility)

    // All mutable writer state is confined to ioQueue.
    private var pendingSnapshot: StorageSnapshot?
    private var scheduledWrite: DispatchWorkItem?
    private var waiters: [SaveWaiter] = []
    private var persistedRevision: Int64 = -1
    private var compatibilityChecked = false
    private var writeBlockError: StorageError?

    init(
        baseDirectory: URL? = nil,
        debounceInterval: TimeInterval = 0.15,
        retryInterval: TimeInterval = 0.5,
        fileStore: (any StorageFileStore)? = nil,
        writer: DataWriter? = nil,
        clock: @escaping Clock = { Date() }
    ) {
        let defaultStore = fileStore ?? LocalStorageFileStore()
        let fileManager = FileManager.default
        let defaultAppSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appSupport = baseDirectory ?? defaultAppSupport
        let appFolder = appSupport.appendingPathComponent("QuickStash", isDirectory: true)

        storageURL = appFolder.appendingPathComponent("items.json")
        self.fileStore = defaultStore
        self.writer = writer ?? { data, url in
            try defaultStore.writeDataAtomically(data, to: url)
        }
        self.clock = clock
        self.debounceInterval = max(0, debounceInterval)
        self.retryInterval = max(0, retryInterval)
    }

    func saveSnapshot(
        _ snapshot: StorageSnapshot,
        completion: (@MainActor @Sendable (Error?) -> Void)? = nil
    ) {
        ioQueue.async { [self] in
            if let writeBlockError {
                deliver(completion, error: writeBlockError)
                return
            }

            if pendingSnapshot == nil || snapshot.revision >= pendingSnapshot!.revision {
                pendingSnapshot = snapshot
            }
            if let completion {
                waiters.append(SaveWaiter(revision: snapshot.revision, completion: completion))
            }
            scheduleWrite(after: debounceInterval)
        }
    }

    func flushSynchronously(_ snapshot: StorageSnapshot? = nil) throws {
        try ioQueue.sync { [self] in
            try flushOnQueue(snapshot)
        }
    }

    func flush(_ snapshot: StorageSnapshot? = nil) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    try flushOnQueue(snapshot)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadSnapshot(
        completion: @escaping @MainActor @Sendable (StorageLoadResult) -> Void
    ) {
        ioQueue.async { [self] in
            let result = loadOnQueue()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func loadSnapshotSynchronously() -> StorageLoadResult {
        ioQueue.sync { [self] in loadOnQueue() }
    }

    private func scheduleWrite(after delay: TimeInterval) {
        scheduledWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performPendingWrite()
        }
        scheduledWrite = work
        ioQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performPendingWrite() {
        scheduledWrite = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        do {
            try ensureWriteCompatibility()
            try write(snapshot)
            persistedRevision = max(persistedRevision, snapshot.revision)
            completeWaiters(through: snapshot.revision, error: nil)
            if pendingSnapshot != nil {
                scheduleWrite(after: 0)
            }
        } catch {
            if pendingSnapshot == nil || snapshot.revision >= pendingSnapshot!.revision {
                pendingSnapshot = snapshot
            }
            notifyWaiters(through: snapshot.revision, error: error)
            if writeBlockError == nil {
                scheduleWrite(after: retryInterval)
            }
        }
    }

    private func notifyWaiters(through revision: Int64, error: Error) {
        let indices = waiters.indices.filter {
            waiters[$0].revision <= revision && !waiters[$0].hasReportedFailure
        }
        for index in indices {
            waiters[index].hasReportedFailure = true
            let waiter = waiters[index]
            DispatchQueue.main.async {
                waiter.completion(error)
            }
        }
    }

    private func completeWaiters(through revision: Int64, error: Error?) {
        let completed = waiters.filter { $0.revision <= revision }
        waiters.removeAll { $0.revision <= revision }
        for waiter in completed {
            DispatchQueue.main.async {
                waiter.completion(error)
            }
        }
    }

    private func deliver(
        _ completion: (@MainActor @Sendable (Error?) -> Void)?,
        error: Error
    ) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(error)
        }
    }

    private func loadOnQueue() -> StorageLoadResult {
        guard fileStore.fileExists(at: storageURL) else {
            compatibilityChecked = true
            persistedRevision = max(persistedRevision, 0)
            return .missing
        }

        do {
            let data = try fileStore.readData(at: storageURL)
            if let schemaVersion = try parsedSchemaVersion(from: data),
               schemaVersion > Self.currentSchemaVersion {
                compatibilityChecked = true
                writeBlockError = .unsupportedSchema(schemaVersion)
                return .unsupported(schemaVersion: schemaVersion)
            }

            let envelopeDecoder = JSONDecoder()
            envelopeDecoder.dateDecodingStrategy = .secondsSince1970
            if let envelope = try? envelopeDecoder.decode(StorageEnvelope.self, from: data) {
                compatibilityChecked = true
                persistedRevision = max(persistedRevision, envelope.revision)
                return .loaded(StorageSnapshot(
                    revision: envelope.revision,
                    items: envelope.items,
                    importJobs: envelope.importJobs
                ))
            }

            // The original app stored a bare item array using ISO-8601 dates.
            let legacyDecoder = JSONDecoder()
            legacyDecoder.dateDecodingStrategy = .iso8601
            let items = try legacyDecoder.decode([StashItem].self, from: data)
            compatibilityChecked = true
            persistedRevision = max(persistedRevision, 0)
            return .loaded(StorageSnapshot(revision: 0, items: items, importJobs: []))
        } catch {
            compatibilityChecked = true
            let backupURL = backupCorruptFile()
            if backupURL == nil {
                writeBlockError = .corruptDataBackupFailed
            }
            return .corrupt(backupURL: backupURL)
        }
    }

    private func ensureWriteCompatibility() throws {
        if let writeBlockError {
            throw writeBlockError
        }
        guard !compatibilityChecked, fileStore.fileExists(at: storageURL) else {
            compatibilityChecked = true
            return
        }
        let data = try fileStore.readData(at: storageURL)
        if let schemaVersion = try parsedSchemaVersion(from: data),
           schemaVersion > Self.currentSchemaVersion {
            writeBlockError = .unsupportedSchema(schemaVersion)
            compatibilityChecked = true
            throw StorageError.unsupportedSchema(schemaVersion)
        }
        compatibilityChecked = true
    }

    private func parsedSchemaVersion(from data: Data) throws -> Int? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schemaVersion"] as? Int
    }

    private func write(_ snapshot: StorageSnapshot) throws {
        try fileStore.createDirectory(at: storageURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let durableJobs = snapshot.importJobs.filter {
            $0.state.isActive || $0.canRetry || $0.needsRecovery
        }
        let data = try encoder.encode(StorageEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            revision: snapshot.revision,
            items: snapshot.items,
            importJobs: durableJobs
        ))
        try writer(data, storageURL)
    }

    private func flushOnQueue(_ snapshot: StorageSnapshot?) throws {
        scheduledWrite?.cancel()
        scheduledWrite = nil
        if let snapshot,
           pendingSnapshot == nil || snapshot.revision >= pendingSnapshot!.revision {
            pendingSnapshot = snapshot
        }
        guard let latest = pendingSnapshot else {
            if let writeBlockError {
                throw writeBlockError
            }
            return
        }
        pendingSnapshot = nil
        do {
            try ensureWriteCompatibility()
            try write(latest)
            persistedRevision = max(persistedRevision, latest.revision)
            completeWaiters(through: latest.revision, error: nil)
        } catch {
            pendingSnapshot = latest
            notifyWaiters(through: latest.revision, error: error)
            throw error
        }
    }

    private func backupCorruptFile() -> URL? {
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: clock()).replacingOccurrences(of: ":", with: "-")
        let backupURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("items-corrupt-\(safeDate)-\(UUID().uuidString).json")

        do {
            try fileStore.copyItem(at: storageURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }
}
