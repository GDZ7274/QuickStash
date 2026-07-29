import Cocoa

/// 覆盖在状态栏下方的透明拖拽接收窗口
/// 解决 NSStatusItem subview 无法在 macOS 状态栏区域可靠接收 Finder 拖拽的问题
class DropOverlayWindow: NSPanel {
    var onFilesDropped: (([URL]) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    private let dropView = DropOverlayView()

    var isPresentationVisible: Bool {
        dropView.isPresentationVisible
    }

    var hasActiveFileDrag: Bool {
        dropView.hasActiveFileDrag
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar  // 与状态栏同层，确保能接收拖拽
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        dropView.onFilesDropped = { [weak self] urls in
            self?.onFilesDropped?(urls)
        }
        dropView.onDragEntered = { [weak self] in
            self?.onDragEntered?()
        }
        dropView.onDragExited = { [weak self] in
            self?.onDragExited?()
        }

        contentView = dropView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setPresentationVisible(_ visible: Bool) {
        dropView.isPresentationVisible = visible
        hasShadow = visible
    }
}

private class DropOverlayView: NSView {
    var onFilesDropped: (([URL]) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?

    private var isDragHighlighted = false {
        didSet { needsDisplay = true }
    }
    var hasActiveFileDrag: Bool { isDragHighlighted }
    var isPresentationVisible = false {
        didSet {
            if !isPresentationVisible {
                isDragHighlighted = false
            }
            guard oldValue != isPresentationVisible else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPresentationVisible else { return }

        let cornerRadius: CGFloat = 16
        let inset: CGFloat = 8
        let rect = bounds.insetBy(dx: inset, dy: inset)

        if isDragHighlighted {
            // 高亮状态：半透明蓝色背景 + 蓝色虚线边框
            NSColor.systemBlue.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

            let dashPattern: [CGFloat] = [6, 4]
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
            border.lineWidth = 2
            border.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
            border.stroke()

            // 提示文字
            let text = "松开以存入 QuickStash" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.9)
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (bounds.width - textSize.width) / 2,
                y: (bounds.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
        } else {
            // 默认状态：轻量提示
            NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

            let text = "拖入文件暂存" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (bounds.width - textSize.width) / 2,
                y: (bounds.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
        }
    }

    // MARK: - Drag Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        isDragHighlighted = true
        DispatchQueue.main.async { [weak self] in
            guard self?.isDragHighlighted == true else { return }
            self?.onDragEntered?()
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
        DispatchQueue.main.async { [weak self] in
            guard self?.isDragHighlighted == false else { return }
            self?.onDragExited?()
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        let urls = DragPasteboardReader.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.onFilesDropped?(urls)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragHighlighted = false
        DispatchQueue.main.async { [weak self] in
            guard self?.isDragHighlighted == false else { return }
            self?.onDragExited?()
        }
    }

    private func hasFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [.fileURL]) != nil
    }
}
