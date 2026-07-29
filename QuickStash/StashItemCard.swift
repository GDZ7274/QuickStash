import SwiftUI
import AppKit
import QuickLookThumbnailing

struct StashItemCard: View {
    let item: StashItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let onCopy: () -> Void
    let onToggleSelection: () -> Void

    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var showCopied = false

    var body: some View {
        if isSelectionMode {
            Button(action: {
                onToggleSelection()
            }) {
                cardContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(backgroundColor)
                    .cornerRadius(16)
                    .overlay(borderOverlay)
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { isHovered = $0 }
        } else {
            ZStack(alignment: .topTrailing) {
                cardContent
                    .padding(12)
                    .background(backgroundColor)
                    .cornerRadius(16)
                    .overlay(borderOverlay)
                    .overlay(
                        // 拖拽层只覆盖卡片主体，不覆盖右上角复制按钮区域
                        StashItemDragSource(item: item)
                            .cornerRadius(16)
                            .padding(.trailing, 44) // 留出复制按钮的空间
                            .allowsHitTesting(true)
                    )
                    .contextMenu {
                        if item.type.isLocalFile || item.type == .image {
                            Button(action: {
                                revealInFinder()
                            }) {
                                Label("在访达中显示", systemImage: "folder")
                            }
                        }
                    }

                // 复制按钮单独浮在最上层，确保点击不被拦截
                if !isSelectionMode {
                    copyButton
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
            }
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { isHovered = $0 }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            imagePreview
            bottomRow
        }
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            typeIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(item.preview)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // 选择模式下在 topRow 保留占位（非选择模式 copyButton 已在 ZStack 顶层）
            if isSelectionMode {
                // 无按钮
            } else {
                // 占位，保持 topRow 右侧留白与 ZStack 复制按钮对齐
                Color.clear.frame(width: 28, height: 28)
            }
        }
    }

    private var typeIcon: some View {
        Image(systemName: item.type.icon)
            .font(.system(size: 20))
            .foregroundStyle(item.type.color)
            .frame(width: 32, height: 32)
            .background(item.type.color.opacity(0.15))
            .cornerRadius(10)
    }

    private var copyButton: some View {
        Button(action: {
            if item.type.isLocalFile {
                // 文件类型，打开文件
                QuickStashFileManager.shared.openFile(at: item.content)
            } else {
                // 其他类型，复制
                onCopy()
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    showCopied = false
                }
            }
        }) {
            Image(systemName: showCopied ? "checkmark" : (item.type.isLocalFile ? "arrow.up.forward.square" : "doc.on.doc"))
                .font(.system(size: 14))
                .foregroundStyle(showCopied ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.3))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0.6)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if item.type == .image {
            StashImagePreview(path: item.content, isExpanded: isExpanded)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Text(timeAgo(item.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if !isSelectionMode && (item.preview.count > 100 || item.type == .image) {
                Button(action: { isExpanded.toggle() }) {
                    Text(isExpanded ? "收起" : "展开")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var backgroundColor: some ShapeStyle {
        if isSelected {
            return Color(nsColor: NSColor(white: 0.5, alpha: 0.25))
        } else {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.2)
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                Color.primary.opacity(0.04),
                lineWidth: 0.5
            )
    }

    private func revealInFinder() {
        let path = item.content
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}

@MainActor
private struct StashImagePreview: View {
    let path: String
    let isExpanded: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: isExpanded ? 400 : 150)
        .cornerRadius(12)
        .task(id: "\(path)-\(isExpanded)") {
            thumbnail = nil
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: isExpanded ? CGSize(width: 800, height: 800) : CGSize(width: 500, height: 240),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )

            let generated = await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.nsImage)
                }
            }
            guard !Task.isCancelled else { return }
            thumbnail = generated
        }
    }
}

// MARK: - 通用拖拽支持（文字、链接、图片、文件）

struct StashItemDragSource: NSViewRepresentable {
    let item: StashItem

    func makeNSView(context: Context) -> DraggableItemView {
        let view = DraggableItemView()
        view.item = item
        return view
    }

    func updateNSView(_ nsView: DraggableItemView, context: Context) {
        nsView.item = item
    }
}

final class DraggableItemView: NSView, NSDraggingSource {
    var item: StashItem?
    private var isDragging = false

    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let item = item, !isDragging else { return }
        isDragging = true

        var draggingItems: [NSDraggingItem] = []
        let bounds = self.bounds
        // Use the existing type symbol so drag start never performs synchronous file-system I/O.
        let previewImage = makeDragPreview(for: item)

        switch item.type {

        // 文字 → 提供纯文本，聊天窗口直接填充
        case .text:
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.content, forType: .string)
            let di = NSDraggingItem(pasteboardWriter: pbItem)
            di.setDraggingFrame(bounds, contents: previewImage)
            draggingItems.append(di)

        // 链接 → NSPasteboardItem 同时写 URL 类型和字符串，兼容所有聊天窗口
        case .url:
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.content, forType: .string)
            if let url = URL(string: item.content) {
                pbItem.setString(url.absoluteString, forType: NSPasteboard.PasteboardType("public.url"))
                pbItem.setString(url.absoluteString, forType: NSPasteboard.PasteboardType("public.url-name"))
            }
            let di = NSDraggingItem(pasteboardWriter: pbItem)
            di.setDraggingFrame(bounds, contents: previewImage)
            draggingItems.append(di)

        // 图片按文件 URL 拖出，避免在主线程解码并复制整张图片数据。
        case .image:
            let fileURL = URL(fileURLWithPath: item.content)
            let di = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            di.setDraggingFrame(bounds, contents: previewImage)
            draggingItems.append(di)

        // 本地文件（文档、压缩包、PDF 等）→ 提供文件 URL
        default:
            let fileURL = URL(fileURLWithPath: item.content)
            let di = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            di.setDraggingFrame(bounds, contents: previewImage)
            draggingItems.append(di)
        }

        guard !draggingItems.isEmpty else {
            isDragging = false
            return
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
    }

    // 生成拖拽时跟随鼠标的预览图
    private func makeDragPreview(for item: StashItem) -> NSImage {
        NSImage(systemSymbolName: item.type.icon, accessibilityDescription: nil) ?? NSImage()
    }
}
