import Foundation
import AppKit

typealias StashImportHandler = @Sendable (
    [URL],
    ImportCancellationToken,
    @escaping @Sendable (FileImportProgress) -> Void
) async -> FileImportBatch

@MainActor
protocol ClipboardRetentionScheduling: AnyObject {
    func schedule(at date: Date, action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

@MainActor
final class ClipboardRetentionTimerScheduler: ClipboardRetentionScheduling {
    private var timer: Timer?

    func schedule(at date: Date, action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let timer = Timer(timeInterval: max(0.01, date.timeIntervalSinceNow), repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

private enum BootstrapMutation {
    case add(StashItem)
    case delete(UUID)
    case togglePin(UUID)
    case addImported([StashItem])
}

@MainActor
final class StashViewModel: ObservableObject {
    static let shared = StashViewModel(
        retentionPolicy: ClipboardPreferences.shared.retentionPolicy,
        observeSystemTimeChanges: true
    )

    @Published var items: [StashItem] = [] {
        didSet {
            guard !isBootstrapping else { return }
            revision &+= 1
            saveSnapshot(revision: revision)
        }
    }

    @Published private(set) var importJobs: [ImportJob] = [] {
        didSet {
            guard !isBootstrapping else { return }
            revision &+= 1
            saveSnapshot(revision: revision)
        }
    }
    @Published var lastError: String? {
        didSet { lastErrorRevision &+= 1 }
    }
    private var isBootstrapping = false
    private var bootstrapGeneration = UUID()
    private var bootstrapMutations: [BootstrapMutation] = []
    private var revision: Int64 = 0
    private var persistedRevision: Int64 = 0
    private var pendingManifestAcknowledgements: [UUID: Int64] = [:]
    private var lastErrorRevision = 0
    private var importErrorContext: (jobID: UUID, revision: Int)?
    private var storageErrorContext: (revision: Int64, errorRevision: Int)?
    private var importCancellationTokens: [UUID: ImportCancellationToken] = [:]
    private var importProgressRelays: [UUID: ImportProgressRelay] = [:]
    private let storageManager: StorageManager
    private let fileManager: QuickStashFileManager
    private let importHandler: StashImportHandler
    private var clipboardRetentionPolicy: ClipboardRetentionPolicy
    private let clipboardRetentionScheduler: ClipboardRetentionScheduling
    private let retentionNowProvider: @MainActor () -> Date
    private let clipboardCaptureInvalidator: @MainActor () -> Void
    private let clipboardCleanupRetryDelay: TimeInterval
    private var pendingClipboardCleanupIDs = Set<UUID>()
    private var clipboardCleanupRetryAfter: [UUID: Date] = [:]
    private var retentionObservers: [NSObjectProtocol] = []

    var importingFileCount: Int {
        importJobs
            .filter { $0.state.isActive }
            .reduce(0) { $0 + max(0, $1.totalItems - $1.completedItems) }
    }

    var visibleImportJobs: [ImportJob] {
        ImportJobPresentation.visibleJobs(from: importJobs)
    }

    init(
        storageManager: StorageManager = .shared,
        fileManager: QuickStashFileManager = .shared,
        loadOnInit: Bool = true,
        purgeOnInit: Bool = true,
        retentionPolicy: ClipboardRetentionPolicy = .default,
        retentionScheduler: ClipboardRetentionScheduling? = nil,
        retentionNowProvider: (@MainActor () -> Date)? = nil,
        clipboardCaptureInvalidator: (@MainActor () -> Void)? = nil,
        clipboardCleanupRetryDelay: TimeInterval = 60,
        observeSystemTimeChanges: Bool = false,
        importHandler: StashImportHandler? = nil
    ) {
        self.storageManager = storageManager
        self.fileManager = fileManager
        clipboardRetentionPolicy = retentionPolicy
        clipboardRetentionScheduler = retentionScheduler ?? ClipboardRetentionTimerScheduler()
        self.retentionNowProvider = retentionNowProvider ?? { Date() }
        self.clipboardCaptureInvalidator = clipboardCaptureInvalidator ?? {
            ClipboardMonitor.shared.invalidatePendingCaptures()
        }
        self.clipboardCleanupRetryDelay = max(1, clipboardCleanupRetryDelay)
        self.importHandler = importHandler ?? { urls, token, progress in
            await fileManager.importFiles(urls, cancellationToken: token, progress: progress)
        }
        if loadOnInit {
            isBootstrapping = true
            let generation = bootstrapGeneration
            Task { [weak self] in
                await self?.bootstrap(generation: generation, purgeAfterRecovery: purgeOnInit)
            }
        } else if purgeOnInit {
            fileManager.purgeTrash()
        }
        if observeSystemTimeChanges {
            installRetentionObservers()
        }
    }

    private func installRetentionObservers() {
        retentionObservers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyClipboardRetentionPolicy() }
        })
        retentionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyClipboardRetentionPolicy() }
        })
    }

    func loadItems() {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        bootstrapGeneration = UUID()
        let generation = bootstrapGeneration
        Task { [weak self] in
            await self?.bootstrap(generation: generation, purgeAfterRecovery: false)
        }
    }

    private func saveSnapshot(revision revisionToSave: Int64) {
        let snapshot = StorageSnapshot(revision: revisionToSave, items: items, importJobs: importJobs)
        storageManager.saveSnapshot(snapshot) { [weak self] error in
            if let error {
                guard let self else { return }
                self.lastError = "保存失败：\(error.localizedDescription)"
                self.storageErrorContext = (revisionToSave, self.lastErrorRevision)
            } else {
                guard let self else { return }
                self.persistedRevision = max(self.persistedRevision, revisionToSave)
                self.acknowledgeManifests(persistedThrough: revisionToSave)
                if let context = self.storageErrorContext,
                   context.revision <= revisionToSave,
                   context.errorRevision == self.lastErrorRevision {
                    self.lastError = nil
                    self.storageErrorContext = nil
                }
            }
        }
    }

    func flushForTermination() async {
        if isBootstrapping {
            guard !bootstrapMutations.isEmpty
                    || !importJobs.isEmpty
                    || !pendingManifestAcknowledgements.isEmpty else {
                do {
                    try await storageManager.flush()
                } catch {
                    lastError = "保存失败：\(error.localizedDescription)"
                }
                return
            }
            await finishBootstrapForTermination()
        }

        while revision > persistedRevision {
            let targetRevision = revision
            let snapshot = StorageSnapshot(
                revision: targetRevision,
                items: items,
                importJobs: importJobs
            )
            do {
                try await storageManager.flush(snapshot)
                persistedRevision = max(persistedRevision, targetRevision)
                acknowledgeManifests(persistedThrough: targetRevision)
            } catch {
                lastError = "保存失败：\(error.localizedDescription)"
                return
            }
        }
    }

    private func bootstrap(generation: UUID, purgeAfterRecovery: Bool) async {
        let loadResult = await withCheckedContinuation { continuation in
            storageManager.loadSnapshot { result in
                continuation.resume(returning: result)
            }
        }
        guard generation == bootstrapGeneration else { return }

        let loadedSnapshot: StorageSnapshot
        switch loadResult {
        case .missing:
            loadedSnapshot = .empty
        case .loaded(let snapshot):
            loadedSnapshot = snapshot
        case .corrupt(let backupURL):
            if let backupURL {
                loadedSnapshot = .empty
                lastError = "历史数据损坏，原文件已备份为 \(backupURL.lastPathComponent)"
            } else {
                isBootstrapping = false
                lastError = "历史数据损坏，且备份失败"
                return
            }
        case .unsupported(let schemaVersion):
            isBootstrapping = false
            lastError = "数据格式版本 \(schemaVersion) 高于当前版本，已进入只读保护"
            return
        }

        let recovery = await fileManager.recoverManagedFiles(
            referencedBy: loadedSnapshot.items,
            importJobs: loadedSnapshot.importJobs
        )
        guard generation == bootstrapGeneration else { return }

        var mergedItems = recovery.items
        var mergedJobs = normalizeLoadedJobs(loadedSnapshot.importJobs)
            .filter { !recovery.resolvedJobIDs.contains($0.id) }
        replayBootstrapMutations(
            on: &mergedItems,
            importJobs: &mergedJobs,
            excludingJobIDs: recovery.resolvedJobIDs
        )
        if !recovery.manifestIDsNeedingRecovery.isEmpty {
            for manifestID in recovery.manifestIDsNeedingRecovery
            where !mergedJobs.contains(where: { $0.id == manifestID }) {
                var job = ImportJob(id: manifestID, sourceURLs: [])
                job.state = .failed
                job.cleanupFailures = recovery.cleanupFailures
                job.recoveryManifestID = manifestID
                mergedJobs.insert(job, at: 0)
            }
        }

        items = mergedItems.sorted { $0.createdAt > $1.createdAt }
        importJobs = mergedJobs
        bootstrapMutations.removeAll()
        revision = max(revision, loadedSnapshot.revision) &+ 1
        persistedRevision = loadedSnapshot.revision
        for id in recovery.manifestIDsToAcknowledge {
            pendingManifestAcknowledgements[id] = revision
        }
        isBootstrapping = false
        saveSnapshot(revision: revision)
        applyClipboardRetentionPolicy()

        if let cleanupFailure = recovery.cleanupFailures.first {
            lastError = "恢复清理未完成：\(URL(fileURLWithPath: cleanupFailure.path).lastPathComponent)"
        }
        if purgeAfterRecovery {
            fileManager.purgeTrash()
        }
    }

    private func finishBootstrapForTermination() async {
        bootstrapGeneration = UUID()
        let loaded = await withCheckedContinuation { continuation in
            storageManager.loadSnapshot { result in
                continuation.resume(returning: result)
            }
        }
        let loadedSnapshot: StorageSnapshot
        switch loaded {
        case .loaded(let snapshot):
            loadedSnapshot = snapshot
        case .missing, .corrupt:
            loadedSnapshot = .empty
        case .unsupported(let schemaVersion):
            isBootstrapping = false
            lastError = "数据格式版本 \(schemaVersion) 高于当前版本，已进入只读保护"
            return
        }

        var mergedItems = loadedSnapshot.items
        var mergedJobs = normalizeLoadedJobs(loadedSnapshot.importJobs)
        replayBootstrapMutations(on: &mergedItems, importJobs: &mergedJobs)
        items = mergedItems.sorted { $0.createdAt > $1.createdAt }
        importJobs = mergedJobs
        bootstrapMutations.removeAll()
        revision = max(revision, loadedSnapshot.revision) &+ 1
        persistedRevision = loadedSnapshot.revision
        isBootstrapping = false
    }

    private func normalizeLoadedJobs(_ jobs: [ImportJob]) -> [ImportJob] {
        jobs.map { loaded in
            guard loaded.state.isActive else { return loaded }
            var interrupted = loaded
            interrupted.state = .failed
            interrupted.currentItemName = nil
            if interrupted.retryURLs.isEmpty {
                interrupted.retryURLs = interrupted.sourceURLs
            }
            if interrupted.failures.isEmpty, let source = interrupted.sourceURLs.first {
                interrupted.failures = [FileImportFailure(
                    sourceURL: source,
                    kind: .copyFailed,
                    message: "上次导入被应用退出中断，可重试"
                )]
            }
            return interrupted
        }
    }

    private func replayBootstrapMutations(
        on targetItems: inout [StashItem],
        importJobs targetJobs: inout [ImportJob],
        excludingJobIDs: Set<UUID> = []
    ) {
        for mutation in bootstrapMutations {
            switch mutation {
            case .add(let item):
                add(item, to: &targetItems)
            case .delete(let id):
                targetItems.removeAll { $0.id == id }
            case .togglePin(let id):
                if let index = targetItems.firstIndex(where: { $0.id == id }) {
                    targetItems[index].isPinned.toggle()
                }
            case .addImported(let imported):
                for item in imported.reversed() {
                    add(item, to: &targetItems)
                }
            }
        }
        // Jobs are already mutated live while loading, so preserve the newest in-memory form by ID.
        for job in importJobs where !excludingJobIDs.contains(job.id) {
            if let index = targetJobs.firstIndex(where: { $0.id == job.id }) {
                targetJobs[index] = job
            } else {
                targetJobs.insert(job, at: 0)
            }
        }
    }

    private func acknowledgeManifests(persistedThrough revision: Int64) {
        let ids = pendingManifestAcknowledgements.compactMap { id, requiredRevision in
            requiredRevision <= revision ? id : nil
        }
        guard !ids.isEmpty else { return }
        for id in ids {
            pendingManifestAcknowledgements[id] = nil
        }
        fileManager.acknowledgeRecoveryManifests(ids)
    }

    func filteredGroups(searchText: String, groupMode: GroupMode, typeFilter: ItemType? = nil) -> [DailyGroup] {
        var filtered = searchText.isEmpty ? items : items.filter {
            $0.content.localizedCaseInsensitiveContains(searchText) ||
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }

        // 应用类型过滤
        if let type = typeFilter {
            if type == .others {
                // 过滤出除了 text、url、image 之外的所有类型
                filtered = filtered.filter { $0.type != ItemType.text && $0.type != ItemType.url && $0.type != ItemType.image }
            } else {
                filtered = filtered.filter { $0.type == type }
            }
        }

        if groupMode == .type {
            return groupsByType(filtered)
        } else {
            return groupsByTime(filtered)
        }
    }

    private func groupsByTime(_ items: [StashItem]) -> [DailyGroup] {
        let calendar = Calendar.current
        var groups: [DailyGroup] = []

        let pinned = items.filter { $0.isPinned }
        if !pinned.isEmpty {
            groups.append(DailyGroup(id: "time:pinned", title: "📌 已固定", date: Date(), items: pinned, isLocked: false))
        }

        let today = items.filter { !$0.isPinned && calendar.isDateInToday($0.createdAt) }
        if !today.isEmpty {
            groups.append(DailyGroup(id: "time:today", title: "今天", date: Date(), items: today, isLocked: false))
        }

        let yesterday = items.filter { !$0.isPinned && calendar.isDateInYesterday($0.createdAt) }
        if !yesterday.isEmpty {
            groups.append(DailyGroup(id: "time:yesterday", title: "昨天", date: Date(), items: yesterday, isLocked: false))
        }

        let earlier = items.filter {
            !$0.isPinned
                && !calendar.isDateInToday($0.createdAt)
                && !calendar.isDateInYesterday($0.createdAt)
        }
        if !earlier.isEmpty {
            groups.append(DailyGroup(id: "time:earlier", title: "更早", date: .distantPast, items: earlier, isLocked: false))
        }

        return groups
    }

    private func groupsByType(_ items: [StashItem]) -> [DailyGroup] {
        var groups: [DailyGroup] = []

        let pinned = items.filter { $0.isPinned }
        if !pinned.isEmpty {
            groups.append(DailyGroup(id: "type:pinned", title: "📌 已固定", date: Date(), items: pinned, isLocked: false))
        }

        let typeOrder: [ItemType] = [.text, .url, .image, .droppedFile, .video, .audio, .pdf, .document, .code, .design, .archive, .file]
        for type in typeOrder {
            let typeItems = items.filter { !$0.isPinned && $0.type == type }
            if !typeItems.isEmpty {
                let title: String
                switch type {
                case .text: title = "📝 文字"
                case .url: title = "🔗 链接"
                case .image: title = "🖼️ 图片"
                case .pdf: title = "📄 PDF"
                case .document: title = "📊 文档"
                case .archive: title = "📦 压缩包"
                case .file: title = "📁 其他文件"
                case .video: title = "🎬 视频"
                case .audio: title = "🎵 音频"
                case .code: title = "💻 代码"
                case .design: title = "🎨 设计"
                case .droppedFile: title = "📁 拖入文件"
                case .others: title = "📦 其他"
                }
                groups.append(DailyGroup(id: "type:\(type.rawValue)", title: title, date: Date(), items: typeItems, isLocked: false))
            }
        }

        return groups
    }

    func copyToClipboard(_ item: StashItem) {
        if item.type == .image {
            Task {
                do {
                    let payload = try await fileManager.readManagedImage(at: item.content)
                    ClipboardMonitor.shared.performInternalWrite {
                        let changeCount = NSPasteboard.general.clearContents()
                        let result = NSPasteboard.general.setData(
                            payload.data,
                            forType: payload.pasteboardType
                        )
                        return (result, changeCount)
                    }
                } catch {
                    lastError = "复制图片失败：\(error.localizedDescription)"
                }
            }
            return
        }

        ClipboardMonitor.shared.performInternalWrite {
            let changeCount = NSPasteboard.general.clearContents()
            let result = NSPasteboard.general.setString(item.content, forType: .string)
            return (result, changeCount)
        }
    }

    func addItem(_ item: StashItem) {
        if isBootstrapping {
            bootstrapMutations.append(.add(item))
        }
        add(item, to: &items)
        if item.managedOrigin == .clipboard {
            applyClipboardRetentionPolicy()
        }
    }

    private func add(_ item: StashItem, to target: inout [StashItem]) {
        if let index = target.firstIndex(where: {
            $0.type == item.type
                && $0.managedOrigin == item.managedOrigin
                && $0.content == item.content
        }) {
            let existing = target.remove(at: index)
            var refreshed = item
            refreshed.isPinned = existing.isPinned
            insert(refreshed, into: &target)
        } else {
            insert(item, into: &target)
        }
    }

    private func insert(_ item: StashItem, into target: inout [StashItem]) {
        guard item.managedOrigin == .clipboard else {
            target.insert(item, at: 0)
            return
        }
        let index = target.firstIndex { existing in
            existing.createdAt <= item.createdAt
        } ?? target.endIndex
        target.insert(item, at: index)
    }

    func deleteItem(_ item: StashItem) {
        guard item.type.isFileBacked else {
            removeItemMetadata(item)
            return
        }

        Task {
            guard await fileManager.isManagedFileAsync(at: item.content) else {
                removeItemMetadata(item)
                return
            }
            do {
                let manifestID = try await fileManager.quarantineManagedFile(at: item.content)
                if let manifestID {
                    pendingManifestAcknowledgements[manifestID] = revision &+ 1
                }
                removeItemMetadata(item)
            } catch {
                lastError = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    private func removeItemMetadata(_ item: StashItem) {
        if isBootstrapping {
            bootstrapMutations.append(.delete(item.id))
        }
        items.removeAll { $0.id == item.id }
    }

    func togglePin(_ item: StashItem) {
        guard !pendingClipboardCleanupIDs.contains(item.id) else {
            lastError = "该记录正在清理，暂时无法更改固定状态"
            return
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if isBootstrapping {
                bootstrapMutations.append(.togglePin(item.id))
            }
            items[index].isPinned.toggle()
            if items[index].managedOrigin == .clipboard {
                applyClipboardRetentionPolicy()
            }
        }
    }

    func updateClipboardRetentionPolicy(_ policy: ClipboardRetentionPolicy) {
        clipboardRetentionPolicy = policy
        applyClipboardRetentionPolicy()
    }

    func applyClipboardRetentionPolicy(now explicitNow: Date? = nil) {
        let now = explicitNow ?? retentionNowProvider()
        let plannedIDs = ClipboardRetentionPlanner.itemIDsToRemove(
            from: items,
            policy: clipboardRetentionPolicy,
            now: now
        )
        let ids = claimClipboardCleanupIDs(plannedIDs, now: now)
        rescheduleClipboardRetention(now: now)
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            _ = await self?.removeClipboardItems(ids: ids, reportFailure: true)
        }
    }

    @discardableResult
    func clearUnpinnedClipboardItems() async -> ClipboardClearResult {
        clipboardCaptureInvalidator()
        let candidates = Set(items.lazy.filter {
            $0.managedOrigin == .clipboard && !$0.isPinned
        }.map(\.id))
        let ids = claimClipboardCleanupIDs(candidates, now: retentionNowProvider())
        return await removeClipboardItems(ids: ids, reportFailure: true)
    }

    private func claimClipboardCleanupIDs(_ ids: Set<UUID>, now: Date) -> Set<UUID> {
        let claimed = Set(ids.filter { id in
            guard !pendingClipboardCleanupIDs.contains(id),
                  clipboardCleanupRetryAfter[id].map({ $0 <= now }) ?? true,
                  let item = items.first(where: { $0.id == id }) else { return false }
            return item.managedOrigin == .clipboard && !item.isPinned
        })
        pendingClipboardCleanupIDs.formUnion(claimed)
        return claimed
    }

    private func removeClipboardItems(
        ids: Set<UUID>,
        reportFailure: Bool
    ) async -> ClipboardClearResult {
        guard !ids.isEmpty else { return ClipboardClearResult(removedCount: 0, failedCount: 0) }

        var removableIDs = Set<UUID>()
        var manifestIDs: [UUID] = []
        var failedCount = 0
        var processedIDs = Set<UUID>()
        for id in ids {
            guard pendingClipboardCleanupIDs.contains(id),
                  let item = items.first(where: { $0.id == id }),
                  item.managedOrigin == .clipboard,
                  !item.isPinned else {
                processedIDs.insert(id)
                continue
            }
            if item.type.isFileBacked,
               await fileManager.isManagedFileAsync(at: item.content) {
                do {
                    if let manifestID = try await fileManager.quarantineManagedFile(at: item.content) {
                        manifestIDs.append(manifestID)
                    }
                    if pendingClipboardCleanupIDs.contains(id),
                       let current = items.first(where: { $0.id == id }),
                       current.managedOrigin == .clipboard,
                       !current.isPinned {
                        removableIDs.insert(id)
                    }
                    clipboardCleanupRetryAfter[id] = nil
                } catch {
                    failedCount += 1
                    clipboardCleanupRetryAfter[id] = retentionNowProvider()
                        .addingTimeInterval(clipboardCleanupRetryDelay)
                }
            } else {
                if pendingClipboardCleanupIDs.contains(id),
                   let current = items.first(where: { $0.id == id }),
                   current.managedOrigin == .clipboard,
                   !current.isPinned {
                    removableIDs.insert(id)
                }
                clipboardCleanupRetryAfter[id] = nil
            }
            processedIDs.insert(id)
        }

        if !removableIDs.isEmpty {
            let requiredRevision = revision &+ 1
            for manifestID in manifestIDs {
                pendingManifestAcknowledgements[manifestID] = requiredRevision
            }
            if isBootstrapping {
                for id in removableIDs { bootstrapMutations.append(.delete(id)) }
            }
            items.removeAll {
                removableIDs.contains($0.id)
                    && pendingClipboardCleanupIDs.contains($0.id)
                    && $0.managedOrigin == .clipboard
                    && !$0.isPinned
            }
        }
        pendingClipboardCleanupIDs.subtract(processedIDs)
        if reportFailure, failedCount > 0 {
            lastError = "清理了 \(removableIDs.count) 条剪贴板记录，另有 \(failedCount) 条图片隔离失败并已保留"
        }
        rescheduleClipboardRetention(now: retentionNowProvider())
        return ClipboardClearResult(removedCount: removableIDs.count, failedCount: failedCount)
    }

    private func rescheduleClipboardRetention(now: Date) {
        clipboardRetentionScheduler.cancel()
        guard let days = clipboardRetentionPolicy.maximumAgeDays else { return }
        let calendar = Calendar(identifier: .gregorian)
        let nextDate = items.lazy
            .filter {
                $0.managedOrigin == .clipboard
                    && !$0.isPinned
                    && !self.pendingClipboardCleanupIDs.contains($0.id)
            }
            .compactMap { item -> Date? in
                guard let expiration = calendar.date(byAdding: .day, value: days, to: item.createdAt) else {
                    return nil
                }
                if expiration > now { return expiration }
                if let retry = self.clipboardCleanupRetryAfter[item.id], retry > now { return retry }
                return now.addingTimeInterval(0.05)
            }
            .min()
        guard let nextDate else { return }
        clipboardRetentionScheduler.schedule(at: nextDate) { [weak self] in
            self?.applyClipboardRetentionPolicy()
        }
    }

    func importFiles(_ urls: [URL], retryOfJobID: UUID? = nil) async {
        guard !urls.isEmpty else { return }
        let job = ImportJob(sourceURLs: urls, retryOfJobID: retryOfJobID)
        let jobID = job.id
        let cancellationToken = ImportCancellationToken()
        importJobs.insert(job, at: 0)
        importCancellationTokens[jobID] = cancellationToken
        let progressRelay = ImportProgressRelay { [weak self] progress in
            self?.applyImportProgress(progress, to: jobID)
        }
        importProgressRelays[jobID] = progressRelay
        trimImportJobHistory()

        let batch = await importHandler(urls, cancellationToken) { progress in
            progressRelay.submit(progress)
        }
        progressRelay.flush()
        importProgressRelays[jobID] = nil
        importCancellationTokens[jobID] = nil

        guard let jobIndex = importJobs.firstIndex(where: { $0.id == jobID }) else { return }
        let uniqueItems = batch.items.filter { newItem in
            !items.contains(where: { $0.content == newItem.content })
        }
        if let manifestID = batch.manifestID, !batch.needsRecovery {
            pendingManifestAcknowledgements[manifestID] = revision &+ 1
        }
        if !batch.wasCancelled, !uniqueItems.isEmpty {
            if isBootstrapping {
                bootstrapMutations.append(.addImported(uniqueItems))
            }
            items.insert(contentsOf: uniqueItems, at: 0)
        }

        var updatedJobs = importJobs
        var updatedJob = updatedJobs[jobIndex]
        updatedJob.currentItemName = nil
        updatedJob.importedItemCount = uniqueItems.count
        updatedJob.failures = batch.failures
        updatedJob.retryURLs = batch.retryURLs
        updatedJob.cleanupFailures = batch.cleanupFailures
        updatedJob.recoveryManifestID = batch.needsRecovery ? batch.manifestID : nil

        if batch.wasCancelled {
            updatedJob.state = .cancelled
        } else if !batch.failures.isEmpty {
            updatedJob.state = .failed
            updatedJob.completedItems = updatedJob.totalItems
        } else {
            updatedJob.state = .completed
            updatedJob.completedItems = updatedJob.totalItems
            updatedJob.completedBytes = max(updatedJob.completedBytes, updatedJob.totalBytes)
        }
        updatedJobs[jobIndex] = updatedJob
        importJobs = updatedJobs

        if let cleanupFailure = batch.cleanupFailures.first {
            recordImportError(
                "清理未完成，需要恢复：\(URL(fileURLWithPath: cleanupFailure.path).lastPathComponent)",
                jobID: jobID
            )
        } else if !batch.failures.isEmpty {
            let first = batch.failures[0]
            let suffix = batch.failures.count > 1 ? "，另有 \(batch.failures.count - 1) 个失败" : ""
            recordImportError("\(first.sourceName)：\(first.message)\(suffix)", jobID: jobID)
        } else if !batch.wasCancelled, let retryOfJobID {
            clearImportErrorAfterSuccessfulRetry(of: retryOfJobID)
        }
    }

    func cancelImport(_ jobID: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == jobID }),
              importJobs[index].canCancel,
              let token = importCancellationTokens[jobID] else { return }
        var updatedJobs = importJobs
        updatedJobs[index].state = .cancelling
        importJobs = updatedJobs
        token.cancel()
    }

    func retryImport(_ jobID: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updatedJobs = importJobs
        guard let retryURLs = updatedJobs[index].consumeRetryURLs() else { return }
        importJobs = updatedJobs
        Task { [weak self] in
            await self?.importFiles(retryURLs, retryOfJobID: jobID)
        }
    }

    func dismissImportJob(_ jobID: UUID) {
        guard let job = importJobs.first(where: { $0.id == jobID }),
              !job.state.isActive,
              !job.needsRecovery else { return }
        importJobs.removeAll { $0.id == jobID }
    }

    private func applyImportProgress(_ progress: FileImportProgress, to jobID: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == jobID }),
              importJobs[index].state.isActive else { return }
        var updatedJobs = importJobs
        var updatedJob = updatedJobs[index]
        updatedJob.apply(progress)
        updatedJobs[index] = updatedJob
        importJobs = updatedJobs
    }

    private func recordImportError(_ message: String, jobID: UUID) {
        lastError = message
        importErrorContext = (jobID, lastErrorRevision)
    }

    private func clearImportErrorAfterSuccessfulRetry(of jobID: UUID) {
        guard let context = importErrorContext,
              context.jobID == jobID,
              context.revision == lastErrorRevision else { return }
        lastError = nil
        importErrorContext = nil
    }

    private func trimImportJobHistory() {
        guard importJobs.count > 8 else { return }
        var retained: [ImportJob] = []
        for job in importJobs where retained.count < 8 || job.state.isActive || job.needsRecovery {
            retained.append(job)
        }
        importJobs = retained
    }
}

private final class ImportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @MainActor @Sendable (FileImportProgress) -> Void
    private var latestProgress: FileImportProgress?
    private var deliveryScheduled = false

    init(handler: @escaping @MainActor @Sendable (FileImportProgress) -> Void) {
        self.handler = handler
    }

    func submit(_ progress: FileImportProgress) {
        let shouldSchedule = lock.withLock {
            latestProgress = progress
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        scheduleDelivery()
    }

    @MainActor
    func flush() {
        let progress = lock.withLock {
            let value = latestProgress
            latestProgress = nil
            deliveryScheduled = false
            return value
        }
        if let progress {
            handler(progress)
        }
    }

    @MainActor
    private func deliver() {
        let progress = lock.withLock {
            let value = latestProgress
            latestProgress = nil
            return value
        }
        if let progress {
            handler(progress)
        }

        let shouldScheduleAgain = lock.withLock {
            if latestProgress == nil {
                deliveryScheduled = false
                return false
            }
            return true
        }
        if shouldScheduleAgain {
            scheduleDelivery()
        }
    }

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000)
            self?.deliver()
        }
    }
}
