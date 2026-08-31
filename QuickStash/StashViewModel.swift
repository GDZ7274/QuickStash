import Foundation
import AppKit

typealias StashImportHandler = @Sendable (
    [URL],
    ImportCancellationToken,
    @escaping @Sendable (FileImportProgress) -> Void
) async -> FileImportBatch
typealias ClipboardTextWriter = @MainActor (String) -> Bool
typealias ClipboardImageReader = @Sendable (String) async throws -> ClipboardImagePayload
typealias ClipboardImageWriter = @MainActor (ClipboardImagePayload) -> Bool

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

private struct PendingClipboardImageReplacement {
    let existing: StashItem
    let incoming: StashItem
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
    private var bootstrapItemIDAliases: [UUID: UUID] = [:]
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
    private var pendingItemDeletionIDs = Set<UUID>()
    private var itemDeletionTasks: [UUID: Task<Void, Never>] = [:]
    private var clipboardCopyGeneration: UInt64 = 0
    private var pendingClipboardCopyCounts: [UUID: Int] = [:]
    private var clipboardImageCopyTasks: [UUID: Task<Void, Never>] = [:]
    private var clipboardImageDiscardTasks: [UUID: Task<Void, Never>] = [:]
    private var manifestAcknowledgementTasks: [UUID: Task<Void, Never>] = [:]
    private var clipboardCleanupTasks: [UUID: Task<ClipboardClearResult, Never>] = [:]
    private var pendingImageReplacementIDs = Set<UUID>()
    private var pendingClipboardImageReplacements: [String: PendingClipboardImageReplacement] = [:]
    private var isFlushingForTermination = false
    private var retentionObservers: [NSObjectProtocol] = []
    private let clipboardTextWriter: ClipboardTextWriter
    private let clipboardImageReader: ClipboardImageReader
    private let clipboardImageWriter: ClipboardImageWriter

    var importingFileCount: Int {
        importJobs
            .filter { $0.state.isActive }
            .reduce(0) { $0 + max(0, $1.totalItems - $1.completedItems) }
    }

    var visibleImportJobs: [ImportJob] {
        ImportJobPresentation.visibleJobs(from: importJobs)
    }

    var isTerminationFlushActive: Bool { isFlushingForTermination }

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
        importHandler: StashImportHandler? = nil,
        clipboardTextWriter: ClipboardTextWriter? = nil,
        clipboardImageReader: ClipboardImageReader? = nil,
        clipboardImageWriter: ClipboardImageWriter? = nil
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
        self.clipboardTextWriter = clipboardTextWriter ?? { content in
            ClipboardMonitor.shared.performInternalWrite {
                let changeCount = NSPasteboard.general.clearContents()
                let result = NSPasteboard.general.setString(content, forType: .string)
                return (result, changeCount)
            }
        }
        self.clipboardImageReader = clipboardImageReader ?? { path in
            try await fileManager.readManagedImage(at: path)
        }
        self.clipboardImageWriter = clipboardImageWriter ?? { payload in
            ClipboardMonitor.shared.performInternalWrite {
                let changeCount = NSPasteboard.general.clearContents()
                let result = NSPasteboard.general.setData(payload.data, forType: payload.pasteboardType)
                return (result, changeCount)
            }
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
        guard !isBootstrapping, !isFlushingForTermination else { return }
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
        isFlushingForTermination = true
        clipboardRetentionScheduler.cancel()
        importCancellationTokens.values.forEach { $0.cancel() }
        await cancelAndDrainClipboardImageCopies()
        await drainItemDeletions()
        await drainClipboardCleanupTasks()
        await drainClipboardImageDiscards()
        await drainManifestAcknowledgements()
        if isBootstrapping {
            guard !bootstrapMutations.isEmpty
                    || !importJobs.isEmpty
                    || !pendingManifestAcknowledgements.isEmpty else {
                do {
                    try await storageManager.flush()
                } catch {
                    lastError = "保存失败：\(error.localizedDescription)"
                }
                schedulePendingRegisteredImageCleanups()
                await drainClipboardImageDiscards()
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
        schedulePendingRegisteredImageCleanups()
        await drainClipboardImageDiscards()
        await drainItemDeletions()
        await drainClipboardCleanupTasks()
        await drainManifestAcknowledgements()
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
        await drainManifestAcknowledgements()
    }

    private func cancelAndDrainClipboardImageCopies() async {
        clipboardCopyGeneration &+= 1
        while !clipboardImageCopyTasks.isEmpty {
            let tasks = Array(clipboardImageCopyTasks.values)
            tasks.forEach { $0.cancel() }
            for task in tasks {
                await task.value
            }
        }
    }

    private func drainClipboardImageDiscards() async {
        while !clipboardImageDiscardTasks.isEmpty {
            let tasks = Array(clipboardImageDiscardTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func drainItemDeletions() async {
        while !itemDeletionTasks.isEmpty {
            let tasks = Array(itemDeletionTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func drainManifestAcknowledgements() async {
        while !manifestAcknowledgementTasks.isEmpty {
            let tasks = Array(manifestAcknowledgementTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func drainClipboardCleanupTasks() async {
        while !clipboardCleanupTasks.isEmpty {
            let tasks = Array(clipboardCleanupTasks.values)
            for task in tasks {
                _ = await task.value
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
        removeRecoveredCopiesOfBootstrapInputs(
            from: &mergedItems,
            persistedItems: loadedSnapshot.items
        )
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
        schedulePendingRegisteredImageCleanups()
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
                let canonicalID = add(item, to: &targetItems)
                registerBootstrapItemAlias(from: item.id, to: canonicalID)
            case .delete(let id):
                let resolvedID = resolvedBootstrapItemID(id)
                targetItems.removeAll { $0.id == resolvedID }
            case .togglePin(let id):
                let resolvedID = resolvedBootstrapItemID(id)
                if let index = targetItems.firstIndex(where: { $0.id == resolvedID }) {
                    targetItems[index].isPinned.toggle()
                }
            case .addImported(let imported):
                for item in imported.reversed() {
                    let canonicalID = add(item, to: &targetItems)
                    registerBootstrapItemAlias(from: item.id, to: canonicalID)
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

    private func registerBootstrapItemAlias(from incomingID: UUID, to canonicalID: UUID) {
        let resolvedCanonicalID = resolvedBootstrapItemID(canonicalID)
        guard incomingID != resolvedCanonicalID else { return }

        bootstrapItemIDAliases[incomingID] = resolvedCanonicalID
        let aliasesToFlatten = bootstrapItemIDAliases.compactMap { sourceID, destinationID in
            destinationID == incomingID ? sourceID : nil
        }
        for sourceID in aliasesToFlatten {
            bootstrapItemIDAliases[sourceID] = resolvedCanonicalID
        }

        if let incomingCount = pendingClipboardCopyCounts.removeValue(forKey: incomingID) {
            pendingClipboardCopyCounts[resolvedCanonicalID, default: 0] += incomingCount
        }
        if pendingClipboardCleanupIDs.remove(incomingID) != nil {
            pendingClipboardCleanupIDs.insert(resolvedCanonicalID)
        }
        if pendingItemDeletionIDs.remove(incomingID) != nil {
            pendingItemDeletionIDs.insert(resolvedCanonicalID)
        }
        if let incomingRetry = clipboardCleanupRetryAfter.removeValue(forKey: incomingID) {
            clipboardCleanupRetryAfter[resolvedCanonicalID] = max(
                clipboardCleanupRetryAfter[resolvedCanonicalID] ?? .distantPast,
                incomingRetry
            )
        }
    }

    private func resolvedBootstrapItemID(_ id: UUID) -> UUID {
        var resolvedID = id
        var visited = Set<UUID>()
        while visited.insert(resolvedID).inserted,
              let nextID = bootstrapItemIDAliases[resolvedID],
              nextID != resolvedID {
            resolvedID = nextID
        }
        return resolvedID
    }

    private func currentItem(
        matching item: StashItem,
        allowEquivalentBootstrapImageBacking: Bool = false
    ) -> StashItem? {
        let resolvedID = resolvedBootstrapItemID(item.id)
        return items.first { current in
            guard current.id == resolvedID,
                  current.type == item.type,
                  current.managedOrigin == item.managedOrigin else { return false }
            if current.content == item.content { return true }
            guard allowEquivalentBootstrapImageBacking,
                  resolvedID != item.id,
                  item.type == .image,
                  item.managedOrigin == .clipboard,
                  let fingerprint = item.contentFingerprint else { return false }
            return current.contentFingerprint == fingerprint
        }
    }

    private func removeRecoveredCopiesOfBootstrapInputs(
        from targetItems: inout [StashItem],
        persistedItems: [StashItem]
    ) {
        let persistedIDs = Set(persistedItems.map(\.id))
        let pathIdentity: (String) -> String = { path in
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let persistedPaths = Set(persistedItems.compactMap { item in
            item.type.isFileBacked
                ? pathIdentity(item.content)
                : nil
        })
        let replayPaths = Set(bootstrapMutations.flatMap { mutation -> [String] in
            let addedItems: [StashItem]
            switch mutation {
            case .add(let item):
                addedItems = [item]
            case .addImported(let items):
                addedItems = items
            case .delete, .togglePin:
                addedItems = []
            }
            return addedItems.compactMap { item in
                item.type.isFileBacked
                    ? pathIdentity(item.content)
                    : nil
            }
        })
        let recoveredOnlyReplayPaths = replayPaths.subtracting(persistedPaths)
        guard !recoveredOnlyReplayPaths.isEmpty else { return }
        targetItems.removeAll { item in
            !persistedIDs.contains(item.id)
                && recoveredOnlyReplayPaths.contains(pathIdentity(item.content))
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
        let taskID = UUID()
        let manager = fileManager
        let task = Task { [weak self] in
            await manager.acknowledgeRecoveryManifests(ids)
            self?.manifestAcknowledgementTasks[taskID] = nil
        }
        manifestAcknowledgementTasks[taskID] = task
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
        guard !isFlushingForTermination else { return }
        guard let current = currentItem(
            matching: item,
            allowEquivalentBootstrapImageBacking: true
        ),
        !pendingClipboardCleanupIDs.contains(current.id),
        !pendingItemDeletionIDs.contains(current.id),
        !pendingImageReplacementIDs.contains(current.id) else {
            lastError = "该记录正在清理或已失效，暂时无法复制"
            return
        }
        clipboardCopyGeneration &+= 1
        let copyGeneration = clipboardCopyGeneration
        clipboardImageCopyTasks.values.forEach { $0.cancel() }
        if current.type == .image {
            guard claimClipboardCopy(current) else { return }
            let taskID = UUID()
            let imageReader = clipboardImageReader
            let task = Task { [weak self] in
                defer {
                    self?.finishClipboardCopy(current)
                    self?.clipboardImageCopyTasks[taskID] = nil
                }
                do {
                    let payload = try await imageReader(current.content)
                    guard let self,
                          !Task.isCancelled,
                          copyGeneration == self.clipboardCopyGeneration,
                          self.clipboardCopyIsCurrent(current) else { return }
                    guard self.clipboardImageWriter(payload) else {
                        self.lastError = "复制图片失败：无法写入系统剪贴板"
                        return
                    }
                    self.promoteClipboardItem(id: current.id, at: Date())
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          copyGeneration == self.clipboardCopyGeneration else { return }
                    self.lastError = "复制图片失败：\(error.localizedDescription)"
                }
            }
            clipboardImageCopyTasks[taskID] = task
            return
        }

        guard clipboardTextWriter(current.content) else {
            lastError = "复制失败：无法写入系统剪贴板"
            return
        }
        guard copyGeneration == clipboardCopyGeneration else { return }
        promoteClipboardItem(id: current.id, at: Date())
    }

    private func claimClipboardCopy(_ item: StashItem) -> Bool {
        let resolvedID = resolvedBootstrapItemID(item.id)
        guard currentItem(matching: item, allowEquivalentBootstrapImageBacking: true) != nil,
              !pendingClipboardCleanupIDs.contains(resolvedID),
              !pendingItemDeletionIDs.contains(resolvedID),
              !pendingImageReplacementIDs.contains(resolvedID) else {
            lastError = "该记录正在清理或已失效，暂时无法复制"
            return false
        }
        pendingClipboardCopyCounts[resolvedID, default: 0] += 1
        rescheduleClipboardRetention(now: retentionNowProvider())
        return true
    }

    private func clipboardCopyIsCurrent(_ item: StashItem) -> Bool {
        let resolvedID = resolvedBootstrapItemID(item.id)
        return (pendingClipboardCopyCounts[resolvedID] ?? 0) > 0
            && !pendingClipboardCleanupIDs.contains(resolvedID)
            && !pendingItemDeletionIDs.contains(resolvedID)
            && currentItem(matching: item, allowEquivalentBootstrapImageBacking: true) != nil
    }

    private func finishClipboardCopy(_ item: StashItem) {
        let resolvedID = resolvedBootstrapItemID(item.id)
        let remaining = max(0, (pendingClipboardCopyCounts[resolvedID] ?? 1) - 1)
        if remaining == 0 {
            pendingClipboardCopyCounts[resolvedID] = nil
        } else {
            pendingClipboardCopyCounts[resolvedID] = remaining
        }
        guard !isFlushingForTermination else { return }
        applyClipboardRetentionPolicy()
    }

    func addItem(_ item: StashItem) {
        guard !isFlushingForTermination else { return }
        if isBootstrapping {
            bootstrapMutations.append(.add(item))
        }
        add(item, to: &items)
        if !isBootstrapping {
            schedulePendingRegisteredImageCleanups()
        }
        if item.managedOrigin == .clipboard {
            applyClipboardRetentionPolicy()
        }
    }

    @discardableResult
    private func add(_ item: StashItem, to target: inout [StashItem]) -> UUID {
        if let index = clipboardDuplicateIndex(for: item, in: target) {
            let existing = target.remove(at: index)
            let refreshed = refreshedDuplicate(existing: existing, incoming: item)
            if item.type == .image,
               refreshed.content == item.content,
               refreshed.content != existing.content {
                queueClipboardImageReplacement(existing: existing, incoming: item)
                let awaitingReplacement = StashItem(
                    id: existing.id,
                    type: existing.type,
                    content: existing.content,
                    preview: existing.preview,
                    createdAt: max(existing.createdAt, item.createdAt),
                    isPinned: existing.isPinned,
                    availability: existing.availability,
                    managedOrigin: existing.managedOrigin,
                    contentFingerprint: existing.contentFingerprint ?? item.contentFingerprint
                )
                insert(awaitingReplacement, into: &target)
                return existing.id
            }
            insert(refreshed, into: &target)
            if item.type == .image, refreshed.content != item.content {
                scheduleDiscard(of: item)
            }
            return refreshed.id
        } else {
            insert(item, into: &target)
            return item.id
        }
    }

    private func queueClipboardImageReplacement(existing: StashItem, incoming: StashItem) {
        let resolvedID = resolvedBootstrapItemID(existing.id)
        guard !pendingImageReplacementIDs.contains(resolvedID) else {
            scheduleDiscard(of: incoming)
            return
        }
        let key = URL(fileURLWithPath: existing.content).standardizedFileURL.path
        let pending = PendingClipboardImageReplacement(existing: existing, incoming: incoming)
        if let superseded = pendingClipboardImageReplacements.updateValue(pending, forKey: key),
           superseded.incoming.content != incoming.content {
            scheduleDiscard(of: superseded.incoming)
        }
    }

    private func clipboardDuplicateIndex(
        for item: StashItem,
        in target: [StashItem]
    ) -> Int? {
        target.firstIndex { existing in
            guard existing.type == item.type,
                  existing.managedOrigin == item.managedOrigin else { return false }
            guard !pendingItemDeletionIDs.contains(existing.id) else { return false }
            guard item.managedOrigin == .clipboard else {
                return existing.content == item.content
            }
            guard !pendingClipboardCleanupIDs.contains(existing.id) else { return false }
            if item.type == .image,
               let existingFingerprint = existing.contentFingerprint,
               let incomingFingerprint = item.contentFingerprint {
                return existingFingerprint == incomingFingerprint
            }
            return existing.content == item.content
        }
    }

    private func refreshedDuplicate(existing: StashItem, incoming: StashItem) -> StashItem {
        guard incoming.managedOrigin == .clipboard else {
            var refreshed = incoming
            refreshed.isPinned = existing.isPinned
            return refreshed
        }

        if existing.id == incoming.id,
           existing.content == incoming.content {
            return StashItem(
                id: existing.id,
                type: incoming.type,
                content: incoming.content,
                preview: incoming.preview,
                createdAt: max(existing.createdAt, incoming.createdAt),
                isPinned: existing.isPinned,
                availability: incoming.availability,
                managedOrigin: incoming.managedOrigin,
                contentFingerprint: incoming.contentFingerprint ?? existing.contentFingerprint
            )
        }

        let shouldUseIncomingBacking = existing.type == .image
            && existing.availability != .available
            && incoming.availability == .available
        return StashItem(
            id: existing.id,
            type: existing.type,
            content: shouldUseIncomingBacking ? incoming.content : existing.content,
            preview: shouldUseIncomingBacking ? incoming.preview : existing.preview,
            createdAt: max(existing.createdAt, incoming.createdAt),
            isPinned: existing.isPinned,
            availability: shouldUseIncomingBacking ? incoming.availability : existing.availability,
            managedOrigin: existing.managedOrigin,
            contentFingerprint: existing.contentFingerprint ?? incoming.contentFingerprint
        )
    }

    private func scheduleDiscard(of item: StashItem) {
        guard item.type == .image,
              item.managedOrigin == .clipboard else { return }
        let taskID = UUID()
        let manager = fileManager
        let task = Task { [weak self] in
            await manager.discardUnregisteredClipboardImage(at: item.content)
            self?.clipboardImageDiscardTasks[taskID] = nil
        }
        clipboardImageDiscardTasks[taskID] = task
    }

    private func schedulePendingRegisteredImageCleanups() {
        let replacements = Array(pendingClipboardImageReplacements.values)
        pendingClipboardImageReplacements.removeAll(keepingCapacity: true)
        for replacement in replacements {
            scheduleRegisteredImageReplacement(replacement)
        }
    }

    private func scheduleRegisteredImageReplacement(_ replacement: PendingClipboardImageReplacement) {
        let existing = replacement.existing
        let incoming = replacement.incoming
        guard existing.type == .image,
              incoming.type == .image,
              existing.managedOrigin == .clipboard,
              incoming.managedOrigin == .clipboard else { return }
        let resolvedID = resolvedBootstrapItemID(existing.id)
        guard !pendingImageReplacementIDs.contains(resolvedID) else {
            scheduleDiscard(of: incoming)
            return
        }
        pendingImageReplacementIDs.insert(resolvedID)
        let taskID = UUID()
        let manager = fileManager
        let storage = storageManager
        let task = Task { [weak self] in
            var intentWasPrepared = false
            defer {
                if let self {
                    self.pendingImageReplacementIDs.remove(resolvedID)
                    self.clipboardImageDiscardTasks[taskID] = nil
                    if !self.isFlushingForTermination {
                        self.applyClipboardRetentionPolicy()
                    }
                }
            }
            do {
                let intent = try await manager.prepareClipboardImageReplacement(
                    existing: existing,
                    incoming: incoming
                )
                intentWasPrepared = true
                guard let self,
                      let current = self.items.first(where: {
                          $0.id == resolvedID && $0.content == existing.content
                      }) else { return }
                let committed = StashItem(
                    id: resolvedID,
                    type: .image,
                    content: intent.item.content,
                    preview: intent.item.preview,
                    createdAt: max(current.createdAt, intent.item.createdAt),
                    isPinned: current.isPinned,
                    availability: .available,
                    managedOrigin: .clipboard,
                    contentFingerprint: intent.item.contentFingerprint
                )
                self.items.removeAll { $0.id == resolvedID }
                self.insert(committed, into: &self.items)
                try await storage.flush()
                guard self.items.contains(where: {
                    $0.id == resolvedID && $0.content == committed.content
                }), !self.items.contains(where: { $0.content == existing.content }) else { return }
                var commitError: Error?
                for attempt in 0...2 {
                    do {
                        try await manager.commitPreparedDeletion(manifestID: intent.manifestID)
                        commitError = nil
                        break
                    } catch {
                        commitError = error
                        guard attempt < 2 else { break }
                        try? await Task.sleep(
                            nanoseconds: UInt64(100 * (attempt + 1)) * 1_000_000
                        )
                    }
                }
                if let commitError { throw commitError }
                await manager.acknowledgeRecoveryManifests([intent.manifestID])
            } catch {
                guard let self else { return }
                if !intentWasPrepared {
                    self.scheduleDiscard(of: incoming)
                }
                self.lastError = "替换图片存储失败，将在下次启动时继续恢复：\(error.localizedDescription)"
            }
        }
        clipboardImageDiscardTasks[taskID] = task
    }

    private func promoteClipboardItem(id: UUID, at observedAt: Date) {
        let resolvedID = resolvedBootstrapItemID(id)
        guard let existing = items.first(where: {
            $0.id == resolvedID
                && $0.managedOrigin == .clipboard
                && !pendingClipboardCleanupIDs.contains($0.id)
                && !pendingItemDeletionIDs.contains($0.id)
        }) else { return }
        addItem(StashItem(
            id: existing.id,
            type: existing.type,
            content: existing.content,
            preview: existing.preview,
            createdAt: max(existing.createdAt, observedAt),
            isPinned: existing.isPinned,
            availability: existing.availability,
            managedOrigin: existing.managedOrigin,
            contentFingerprint: existing.contentFingerprint
        ))
    }

    func promoteDuplicateClipboardImage(
        fingerprint: String,
        observedAt: Date,
        isStillValid: ClipboardAsyncValidityCheck = {
            withUnsafeCurrentTask { !($0?.isCancelled ?? false) }
        }
    ) async -> Bool {
        guard !Task.isCancelled,
              isStillValid(),
              let candidate = items.first(where: {
            $0.type == .image
                && $0.managedOrigin == .clipboard
                && $0.contentFingerprint == fingerprint
                && !pendingClipboardCleanupIDs.contains($0.id)
                && !pendingItemDeletionIDs.contains($0.id)
        }) else {
            return false
        }
        let isReusable = await fileManager.isReusableClipboardImage(
            at: candidate.content,
            matching: fingerprint
        )
        guard !Task.isCancelled,
              isStillValid(),
              let current = items.first(where: {
            $0.id == candidate.id
                && $0.content == candidate.content
                && $0.contentFingerprint == fingerprint
                && !pendingClipboardCleanupIDs.contains($0.id)
                && !pendingItemDeletionIDs.contains($0.id)
        }) else { return false }
        guard isReusable else {
            guard !Task.isCancelled, isStillValid() else { return false }
            let unavailable = StashItem(
                id: current.id,
                type: current.type,
                content: current.content,
                preview: current.preview,
                createdAt: current.createdAt,
                isPinned: current.isPinned,
                availability: .unavailable,
                managedOrigin: current.managedOrigin,
                contentFingerprint: current.contentFingerprint
            )
            if isBootstrapping {
                bootstrapMutations.append(.add(unavailable))
            }
            add(unavailable, to: &items)
            return false
        }
        guard !Task.isCancelled, isStillValid() else { return false }
        addItem(StashItem(
            id: current.id,
            type: current.type,
            content: current.content,
            preview: current.preview,
            createdAt: max(current.createdAt, observedAt),
            isPinned: current.isPinned,
            availability: current.availability,
            managedOrigin: current.managedOrigin,
            contentFingerprint: fingerprint
        ))
        return true
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
        guard !isFlushingForTermination else { return }
        guard item.type.isFileBacked else {
            removeItemMetadata(item)
            return
        }

        guard claimItemDeletion(item) else { return }
        let manager = fileManager
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishItemDeletion(item) }

            let isManaged = await manager.isManagedFileAsync(at: item.content)
            guard self.itemDeletionIsCurrent(item) else { return }
            guard isManaged else {
                self.removeItemMetadataIfCurrent(item)
                return
            }
            do {
                let manifestID = try await manager.quarantineManagedFile(at: item.content)
                guard self.itemDeletionIsCurrent(item) else {
                    if let manifestID {
                        self.pendingManifestAcknowledgements[manifestID] = self.revision
                        self.acknowledgeManifests(persistedThrough: self.persistedRevision)
                    }
                    return
                }
                if let manifestID {
                    self.pendingManifestAcknowledgements[manifestID] = self.revision &+ 1
                }
                self.removeItemMetadataIfCurrent(item)
            } catch {
                guard self.itemDeletionIsCurrent(item) else { return }
                self.lastError = "删除失败：\(error.localizedDescription)"
            }
        }
        itemDeletionTasks[item.id] = task
    }

    private func claimItemDeletion(_ item: StashItem) -> Bool {
        let resolvedID = resolvedBootstrapItemID(item.id)
        guard !pendingItemDeletionIDs.contains(resolvedID),
              !pendingClipboardCleanupIDs.contains(resolvedID),
              !pendingImageReplacementIDs.contains(resolvedID),
              (pendingClipboardCopyCounts[resolvedID] ?? 0) == 0,
              currentItem(matching: item) != nil else {
            if (pendingClipboardCopyCounts[resolvedID] ?? 0) > 0 {
                lastError = "该记录正在复制，暂时无法删除"
            }
            return false
        }
        pendingItemDeletionIDs.insert(resolvedID)
        rescheduleClipboardRetention(now: retentionNowProvider())
        return true
    }

    private func itemDeletionIsCurrent(_ item: StashItem) -> Bool {
        let resolvedID = resolvedBootstrapItemID(item.id)
        return pendingItemDeletionIDs.contains(resolvedID)
            && currentItem(matching: item) != nil
    }

    private func finishItemDeletion(_ item: StashItem) {
        pendingItemDeletionIDs.remove(resolvedBootstrapItemID(item.id))
        itemDeletionTasks[item.id] = nil
        rescheduleClipboardRetention(now: retentionNowProvider())
    }

    @discardableResult
    private func removeItemMetadataIfCurrent(_ item: StashItem) -> Bool {
        let resolvedID = resolvedBootstrapItemID(item.id)
        guard currentItem(matching: item) != nil else {
            return false
        }
        if isBootstrapping {
            bootstrapMutations.append(.delete(item.id))
        }
        items.removeAll { $0.id == resolvedID && $0.content == item.content }
        return true
    }

    private func removeItemMetadata(_ item: StashItem) {
        let resolvedID = resolvedBootstrapItemID(item.id)
        if isBootstrapping {
            bootstrapMutations.append(.delete(item.id))
        }
        items.removeAll { $0.id == resolvedID && $0.content == item.content }
    }

    func togglePin(_ item: StashItem) {
        guard !isFlushingForTermination else { return }
        guard let current = currentItem(
            matching: item,
            allowEquivalentBootstrapImageBacking: true
        ),
        !pendingClipboardCleanupIDs.contains(current.id),
        !pendingItemDeletionIDs.contains(current.id),
        !pendingImageReplacementIDs.contains(current.id) else {
            lastError = "该记录正在清理，暂时无法更改固定状态"
            return
        }
        if let index = items.firstIndex(where: {
            $0.id == current.id && $0.content == current.content
        }) {
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
        guard !isFlushingForTermination else { return }
        clipboardRetentionPolicy = policy
        applyClipboardRetentionPolicy()
    }

    func applyClipboardRetentionPolicy(now explicitNow: Date? = nil) {
        guard !isFlushingForTermination else {
            clipboardRetentionScheduler.cancel()
            return
        }
        let now = explicitNow ?? retentionNowProvider()
        let plannedIDs = ClipboardRetentionPlanner.itemIDsToRemove(
            from: items,
            policy: clipboardRetentionPolicy,
            now: now
        )
        let ids = claimClipboardCleanupIDs(plannedIDs, now: now)
        rescheduleClipboardRetention(now: now)
        guard !ids.isEmpty else { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return ClipboardClearResult(removedCount: 0, failedCount: 0)
            }
            defer { self.clipboardCleanupTasks[taskID] = nil }
            return await self.removeClipboardItems(ids: ids, reportFailure: true)
        }
        clipboardCleanupTasks[taskID] = task
    }

    @discardableResult
    func clearUnpinnedClipboardItems() async -> ClipboardClearResult {
        guard !isFlushingForTermination else {
            return ClipboardClearResult(removedCount: 0, failedCount: 0)
        }
        clipboardCaptureInvalidator()
        let candidates = Set(items.lazy.filter {
            $0.managedOrigin == .clipboard && !$0.isPinned
        }.map(\.id))
        let ids = claimClipboardCleanupIDs(candidates, now: retentionNowProvider())
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return ClipboardClearResult(removedCount: 0, failedCount: 0)
            }
            defer { self.clipboardCleanupTasks[taskID] = nil }
            return await self.removeClipboardItems(ids: ids, reportFailure: true)
        }
        clipboardCleanupTasks[taskID] = task
        return await task.value
    }

    private func claimClipboardCleanupIDs(_ ids: Set<UUID>, now: Date) -> Set<UUID> {
        let claimed = Set(ids.filter { id in
            guard !pendingClipboardCleanupIDs.contains(id),
                  !pendingItemDeletionIDs.contains(id),
                  !pendingImageReplacementIDs.contains(id),
                  (pendingClipboardCopyCounts[id] ?? 0) == 0,
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
                  !pendingItemDeletionIDs.contains(id),
                  !pendingImageReplacementIDs.contains(id),
                  (pendingClipboardCopyCounts[id] ?? 0) == 0,
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
                       !pendingItemDeletionIDs.contains(id),
                       !pendingImageReplacementIDs.contains(id),
                       (pendingClipboardCopyCounts[id] ?? 0) == 0,
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
                   !pendingItemDeletionIDs.contains(id),
                   !pendingImageReplacementIDs.contains(id),
                   (pendingClipboardCopyCounts[id] ?? 0) == 0,
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
                    && !pendingItemDeletionIDs.contains($0.id)
                    && !pendingImageReplacementIDs.contains($0.id)
                    && (pendingClipboardCopyCounts[$0.id] ?? 0) == 0
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
        guard !isFlushingForTermination else { return }
        guard let days = clipboardRetentionPolicy.maximumAgeDays else { return }
        let calendar = Calendar(identifier: .gregorian)
        let nextDate = items.lazy
            .filter {
                $0.managedOrigin == .clipboard
                    && !$0.isPinned
                    && !self.pendingClipboardCleanupIDs.contains($0.id)
                    && !self.pendingItemDeletionIDs.contains($0.id)
                    && !self.pendingImageReplacementIDs.contains($0.id)
                    && (self.pendingClipboardCopyCounts[$0.id] ?? 0) == 0
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
        guard !urls.isEmpty, !isFlushingForTermination else { return }
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
        guard !isFlushingForTermination else { return }

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
        guard !isFlushingForTermination else { return }
        guard let index = importJobs.firstIndex(where: { $0.id == jobID }),
              importJobs[index].canCancel,
              let token = importCancellationTokens[jobID] else { return }
        var updatedJobs = importJobs
        updatedJobs[index].state = .cancelling
        importJobs = updatedJobs
        token.cancel()
    }

    func retryImport(_ jobID: UUID) {
        guard !isFlushingForTermination else { return }
        guard let index = importJobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updatedJobs = importJobs
        guard let retryURLs = updatedJobs[index].consumeRetryURLs() else { return }
        importJobs = updatedJobs
        Task { [weak self] in
            await self?.importFiles(retryURLs, retryOfJobID: jobID)
        }
    }

    func dismissImportJob(_ jobID: UUID) {
        guard !isFlushingForTermination else { return }
        guard let job = importJobs.first(where: { $0.id == jobID }),
              !job.state.isActive,
              !job.needsRecovery else { return }
        importJobs.removeAll { $0.id == jobID }
    }

    private func applyImportProgress(_ progress: FileImportProgress, to jobID: UUID) {
        guard !isFlushingForTermination else { return }
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
