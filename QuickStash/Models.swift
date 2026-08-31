import Foundation
import SwiftUI

enum ImportJobState: String, Codable, Sendable {
    case queued
    case preflighting
    case importing
    case cancelling
    case retrying
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .preflighting, .importing, .cancelling:
            return true
        case .retrying, .completed, .failed, .cancelled:
            return false
        }
    }
}

enum FileImportFailureKind: String, Codable, Sendable, Equatable {
    case invalidSource
    case limitExceeded
    case quotaExceeded
    case insufficientDiskSpace
    case copyFailed
}

struct FileImportFailure: Codable, Sendable, Equatable {
    let sourceURL: URL
    let sourceName: String
    let kind: FileImportFailureKind
    let message: String

    init(sourceURL: URL, kind: FileImportFailureKind, message: String) {
        self.sourceURL = sourceURL
        sourceName = sourceURL.lastPathComponent.isEmpty ? sourceURL.path : sourceURL.lastPathComponent
        self.kind = kind
        self.message = message
    }
}

enum FileCleanupKind: String, Codable, Sendable, Equatable {
    case stagingRemoval
    case committedRemoval
    case committedQuarantine
}

struct FileCleanupOperation: Codable, Sendable, Equatable {
    let kind: FileCleanupKind
    let sourceURL: URL
    let destinationURL: URL?
}

struct FileCleanupFailure: Codable, Sendable, Equatable {
    let path: String
    let message: String
}

struct ImportJob: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sourceURLs: [URL]
    let createdAt: Date
    let retryOfJobID: UUID?
    var state: ImportJobState
    var completedBytes: Int64
    var totalBytes: Int64
    var completedItems: Int
    var totalItems: Int
    var currentItemName: String?
    var importedItemCount: Int
    var failures: [FileImportFailure]
    var retryURLs: [URL]
    var cleanupFailures: [FileCleanupFailure]
    var recoveryManifestID: UUID?

    init(
        id: UUID = UUID(),
        sourceURLs: [URL],
        createdAt: Date = Date(),
        retryOfJobID: UUID? = nil
    ) {
        self.id = id
        self.sourceURLs = sourceURLs
        self.createdAt = createdAt
        self.retryOfJobID = retryOfJobID
        state = .queued
        completedBytes = 0
        totalBytes = 0
        completedItems = 0
        totalItems = sourceURLs.count
        currentItemName = nil
        importedItemCount = 0
        failures = []
        retryURLs = []
        cleanupFailures = []
        recoveryManifestID = nil
    }

    var progress: Double {
        if state == .completed { return 1 }
        if totalBytes > 0 {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        guard totalItems > 0 else { return state == .completed ? 1 : 0 }
        return min(1, max(0, Double(completedItems) / Double(totalItems)))
    }

    var canCancel: Bool {
        state.isActive && state != .cancelling
    }

    var canRetry: Bool {
        (state == .failed || state == .cancelled) && !retryURLs.isEmpty && !needsRecovery
    }

    var needsRecovery: Bool {
        !cleanupFailures.isEmpty
    }

    mutating func consumeRetryURLs() -> [URL]? {
        guard canRetry else { return nil }
        let urls = retryURLs
        retryURLs = []
        state = .retrying
        return urls
    }

    mutating func apply(_ progress: FileImportProgress) {
        guard state.isActive else { return }
        if state != .cancelling {
            state = progress.phase == .preflighting ? .preflighting : .importing
        }
        completedBytes = max(completedBytes, progress.completedBytes)
        totalBytes = max(totalBytes, progress.totalBytes)
        completedItems = max(completedItems, progress.completedItems)
        totalItems = max(totalItems, progress.totalItems)
        currentItemName = progress.currentItemName
    }
}

enum ImportJobPresentation {
    static func visibleJobs(from jobs: [ImportJob], minimumCount: Int = 3) -> [ImportJob] {
        let executing = jobs
            .filter { [.preflighting, .importing, .cancelling].contains($0.state) }
            .sorted { $0.createdAt < $1.createdAt }
        let queued = jobs
            .filter { $0.state == .queued }
            .sorted { $0.createdAt < $1.createdAt }
        let terminal = jobs
            .filter { ![.preflighting, .importing, .cancelling, .queued].contains($0.state) }
            .sorted { $0.createdAt > $1.createdAt }
        let remainingCount = max(0, minimumCount - executing.count)
        return executing + Array((queued + terminal).prefix(remainingCount))
    }
}

enum GroupMode: String, CaseIterable {
    case time = "按时间"
    case type = "按类型"

    var icon: String {
        switch self {
        case .time: return "clock.fill"
        case .type: return "square.grid.2x2.fill"
        }
    }
}

enum ItemAvailability: String, Codable, Sendable {
    case available
    case unavailable
}

enum ManagedItemOrigin: String, Codable, Sendable {
    case imported
    case clipboard
    case legacyUnknown
}

struct ClipboardRetentionPolicy: Equatable, Sendable {
    static let `default` = ClipboardRetentionPolicy(maximumItemCount: 100, maximumAgeDays: 30)

    /// A nil value means that this dimension is unlimited.
    let maximumItemCount: Int?
    let maximumAgeDays: Int?

    init(maximumItemCount: Int?, maximumAgeDays: Int?) {
        self.maximumItemCount = maximumItemCount.flatMap { $0 > 0 ? $0 : nil }
        self.maximumAgeDays = maximumAgeDays.flatMap { $0 > 0 ? $0 : nil }
    }
}

enum ClipboardRetentionPlanner {
    static func itemIDsToRemove(
        from items: [StashItem],
        policy: ClipboardRetentionPolicy,
        now: Date = Date()
    ) -> Set<UUID> {
        let candidates = items.filter {
            $0.managedOrigin == .clipboard && !$0.isPinned
        }
        var removals = Set<UUID>()

        if let days = policy.maximumAgeDays,
           let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) {
            removals.formUnion(candidates.lazy.filter { $0.createdAt <= cutoff }.map(\.id))
        }

        if let limit = policy.maximumItemCount {
            let newestFirst = candidates.sorted(by: stableNewestFirst)
            if newestFirst.count > limit {
                removals.formUnion(newestFirst.dropFirst(limit).map(\.id))
            }
        }
        return removals
    }

    private static func stableNewestFirst(_ lhs: StashItem, _ rhs: StashItem) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ClipboardClearResult: Equatable, Sendable {
    let removedCount: Int
    let failedCount: Int
}

struct StashItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let type: ItemType
    let content: String
    let preview: String
    let createdAt: Date
    let contentFingerprint: String?
    var isPinned: Bool
    var availability: ItemAvailability
    var managedOrigin: ManagedItemOrigin

    init(
        id: UUID = UUID(),
        type: ItemType,
        content: String,
        preview: String,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        availability: ItemAvailability = .available,
        managedOrigin: ManagedItemOrigin = .imported,
        contentFingerprint: String? = nil
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.preview = preview
        self.createdAt = createdAt
        self.contentFingerprint = contentFingerprint
        self.isPinned = isPinned
        self.availability = availability
        self.managedOrigin = managedOrigin
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, content, preview, createdAt, contentFingerprint
        case isPinned, availability, managedOrigin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(ItemType.self, forKey: .type)
        content = try container.decode(String.self, forKey: .content)
        preview = try container.decode(String.self, forKey: .preview)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        contentFingerprint = try container.decodeIfPresent(String.self, forKey: .contentFingerprint)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        availability = try container.decodeIfPresent(ItemAvailability.self, forKey: .availability) ?? .available
        managedOrigin = try container.decodeIfPresent(ManagedItemOrigin.self, forKey: .managedOrigin) ?? .legacyUnknown
    }
}

enum ItemType: String, Codable, Sendable {
    case text
    case file           // 通用文件（兜底）
    case image
    case url
    case archive        // 压缩包
    case document       // Word, Excel, PPT
    case pdf
    case video          // 视频
    case audio          // 音频
    case code           // 代码文件
    case design         // 设计文件 (PSD, AI, Sketch, Figma 等)
    case droppedFile    // 拖入的文件（统一分类）
    case others         // 其他类型（仅用于过滤，不存储）

    var icon: String {
        switch self {
        case .text: return "doc.text.fill"
        case .file: return "doc.fill"
        case .image: return "photo.fill"
        case .url: return "link"
        case .archive: return "archivebox.fill"
        case .document: return "doc.richtext.fill"
        case .pdf: return "doc.text.fill"
        case .video: return "video.fill"
        case .audio: return "music.note"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .design: return "paintbrush.fill"
        case .droppedFile: return "folder.fill"
        case .others: return "square.grid.2x2.fill"
        }
    }

    var color: Color {
        switch self {
        case .text: return .blue
        case .file: return .purple
        case .image: return .green
        case .url: return .orange
        case .archive: return .brown
        case .document: return .indigo
        case .pdf: return .red
        case .video: return .pink
        case .audio: return .teal
        case .code: return .mint
        case .design: return .cyan
        case .droppedFile: return .gray
        case .others: return .gray
        }
    }

    /// 是否是本地文件（需要"打开"而不是"复制文本"）
    var isLocalFile: Bool {
        switch self {
        case .text, .url, .image, .others: return false
        default: return true
        }
    }

    /// 内容字段是否指向由 QuickStash 管理的本地文件。
    var isFileBacked: Bool {
        switch self {
        case .text, .url, .others:
            return false
        default:
            return true
        }
    }

    static func fromFileExtension(_ ext: String) -> ItemType {
        let lowercased = ext.lowercased()
        switch lowercased {
        // 压缩包
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "lz4", "zst", "cab", "iso", "dmg", "pkg":
            return .archive
        // Office 文档
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "numbers", "pages", "odt", "ods", "odp", "rtf", "csv":
            return .document
        // PDF
        case "pdf":
            return .pdf
        // 图片
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "svg", "ico", "raw", "cr2", "nef", "arw":
            return .image
        // 视频
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "m4v", "webm", "rmvb", "3gp":
            return .video
        // 音频
        case "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma", "aiff", "opus", "ape":
            return .audio
        // 代码
        case "swift", "py", "js", "jsx", "tsx", "html", "css", "scss", "json", "xml",
             "java", "kt", "go", "rs", "cpp", "c", "h", "rb", "php", "sh", "bash",
             "zsh", "yaml", "yml", "toml", "md", "sql", "dart", "vue", "env", "ts":
            return .code
        // 设计文件
        case "psd", "ai", "sketch", "fig", "xd", "afdesign", "afphoto", "indd", "eps", "cdr":
            return .design
        default:
            return .file
        }
    }
}

struct DailyGroup: Identifiable {
    let id: String
    let title: String
    let date: Date
    var items: [StashItem]
    let isLocked: Bool
    var isExpanded: Bool = true

    init(id: String, title: String, date: Date, items: [StashItem], isLocked: Bool, isExpanded: Bool = true) {
        self.id = id
        self.title = title
        self.date = date
        self.items = items
        self.isLocked = isLocked
        self.isExpanded = isExpanded
    }
}
