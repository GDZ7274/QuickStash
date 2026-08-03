import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject private var viewModel: StashViewModel
    @State private var searchText = ""
    @State private var isSelectionMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var expandedGroups: Set<String> = []
    @State private var groupMode: GroupMode = .time
    @State private var typeFilter: ItemType? = nil

    init(viewModel: StashViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                isSelectionMode: $isSelectionMode,
                selectedCount: selectedItems.intersection(Set(visibleItems.map(\.id))).count,
                totalCount: visibleItems.count,
                onDeleteSelected: deleteSelected,
                onPinSelected: pinSelected,
                onCancelSelection: cancelSelection,
                onSelectAll: selectAll
            )

            if !viewModel.visibleImportJobs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(viewModel.visibleImportJobs) { job in
                        ImportJobRow(
                            job: job,
                            onCancel: { viewModel.cancelImport(job.id) },
                            onRetry: { viewModel.retryImport(job.id) },
                            onDismiss: { viewModel.dismissImportJob(job.id) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            if let error = viewModel.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { viewModel.lastError = nil }) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            SearchBar(text: $searchText, groupMode: $groupMode, typeFilter: $typeFilter)

            ScrollView {
                LazyVStack(spacing: 16, pinnedViews: typeFilter == nil ? [.sectionHeaders] : []) {
                    if typeFilter != nil {
                        // 有类型过滤时，直接显示列表不分组
                        let allItems = viewModel.filteredGroups(searchText: searchText, groupMode: groupMode, typeFilter: typeFilter).flatMap { $0.items }
                        ForEach(allItems) { item in
                            StashItemCard(
                                item: item,
                                isSelectionMode: isSelectionMode,
                                isSelected: selectedItems.contains(item.id),
                                onCopy: { viewModel.copyToClipboard(item) },
                                onDelete: { viewModel.deleteItem(item) },
                                onToggleSelection: { toggleSelection(item.id) }
                            )
                            .contextMenu {
                                if !isSelectionMode {
                                    Button(action: { viewModel.copyToClipboard(item) }) {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }
                                    Button(action: { viewModel.togglePin(item) }) {
                                        Label(item.isPinned ? "取消固定" : "固定", systemImage: item.isPinned ? "pin.slash" : "pin")
                                    }
                                    Divider()
                                    Button(role: .destructive, action: { viewModel.deleteItem(item) }) {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } else {
                        // 无类型过滤时，按分组显示
                        ForEach(viewModel.filteredGroups(searchText: searchText, groupMode: groupMode, typeFilter: typeFilter)) { group in
                            let isExpanded = expandedGroups.contains(group.title)
                            let groupItemIds = Set(group.items.map { $0.id })
                            let allSelected = !groupItemIds.isEmpty && groupItemIds.isSubset(of: selectedItems)

                            Section {
                                if isExpanded {
                                    ForEach(group.items) { item in
                                        StashItemCard(
                                            item: item,
                                            isSelectionMode: isSelectionMode,
                                            isSelected: selectedItems.contains(item.id),
                                            onCopy: { viewModel.copyToClipboard(item) },
                                            onDelete: { viewModel.deleteItem(item) },
                                            onToggleSelection: { toggleSelection(item.id) }
                                        )
                                        .contextMenu {
                                            if !isSelectionMode {
                                                Button(action: { viewModel.copyToClipboard(item) }) {
                                                    Label("复制", systemImage: "doc.on.doc")
                                                }
                                                Button(action: { viewModel.togglePin(item) }) {
                                                    Label(item.isPinned ? "取消固定" : "固定", systemImage: item.isPinned ? "pin.slash" : "pin")
                                                }
                                                Divider()
                                                Button(role: .destructive, action: { viewModel.deleteItem(item) }) {
                                                    Label("删除", systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                }
                            } header: {
                                GroupHeader(
                                    title: group.title,
                                    count: group.items.count,
                                    isLocked: group.isLocked,
                                    isExpanded: isExpanded,
                                    isSelectionMode: isSelectionMode,
                                    allItemsSelected: allSelected,
                                    onToggleExpand: { toggleGroup(group.title) },
                                    onSelectAll: { selectAllInGroup(groupItemIds) }
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 480, idealHeight: 640)
        .background(.ultraThinMaterial)
        .onAppear {
            // 默认展开所有分组
            expandedGroups = Set(viewModel.filteredGroups(searchText: "", groupMode: groupMode, typeFilter: typeFilter).map { $0.title })

        }
        .onChange(of: groupMode) {
            // 切换分组模式时重新初始化展开状态
            expandedGroups = Set(viewModel.filteredGroups(searchText: searchText, groupMode: groupMode, typeFilter: typeFilter).map { $0.title })
        }
        .onChange(of: typeFilter) {
            // 切换类型过滤时重新初始化展开状态
            expandedGroups = Set(viewModel.filteredGroups(searchText: searchText, groupMode: groupMode, typeFilter: typeFilter).map { $0.title })
            reconcileSelection()
        }
        .onChange(of: searchText) {
            reconcileSelection()
        }
        .onChange(of: viewModel.items) {
            let titles = viewModel.filteredGroups(
                searchText: searchText,
                groupMode: groupMode,
                typeFilter: typeFilter
            ).map(\.title)
            expandedGroups.formUnion(titles)
            reconcileSelection()
        }
    }

    private var visibleItems: [StashItem] {
        viewModel.filteredGroups(
            searchText: searchText,
            groupMode: groupMode,
            typeFilter: typeFilter
        ).flatMap(\.items)
    }

    private func reconcileSelection() {
        selectedItems.formIntersection(Set(visibleItems.map(\.id)))
    }

    func toggleSelection(_ id: UUID) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    func toggleGroup(_ groupTitle: String) {
        if expandedGroups.contains(groupTitle) {
            expandedGroups.remove(groupTitle)
        } else {
            expandedGroups.insert(groupTitle)
        }
    }

    func selectAllInGroup(_ groupItemIds: Set<UUID>) {
        let allSelected = groupItemIds.isSubset(of: selectedItems)
        if allSelected {
            // 取消全选
            selectedItems.subtract(groupItemIds)
        } else {
            // 全选
            selectedItems.formUnion(groupItemIds)
        }
    }

    func deleteSelected() {
        for id in selectedItems {
            if let item = viewModel.items.first(where: { $0.id == id }) {
                viewModel.deleteItem(item)
            }
        }
        selectedItems.removeAll()
        isSelectionMode = false
    }

    func pinSelected() {
        // 检查选中项目中是否有未固定的，如果有就全部固定，否则全部取消固定
        let selectedItemsList = viewModel.items.filter { selectedItems.contains($0.id) }
        let hasUnpinned = selectedItemsList.contains { !$0.isPinned }

        for id in selectedItems {
            if let index = viewModel.items.firstIndex(where: { $0.id == id }) {
                let item = viewModel.items[index]
                // 如果有未固定的项目，就全部固定；否则全部取消固定
                if hasUnpinned && !item.isPinned {
                    viewModel.togglePin(item)
                } else if !hasUnpinned && item.isPinned {
                    viewModel.togglePin(item)
                }
            }
        }
        selectedItems.removeAll()
        isSelectionMode = false
    }

    func cancelSelection() {
        selectedItems.removeAll()
        isSelectionMode = false
    }

    func selectAll() {
        let allItemIds = Set(visibleItems.map(\.id))

        if selectedItems == allItemIds {
            // 已经全选，取消全选
            selectedItems.removeAll()
        } else {
            // 全选
            selectedItems = allItemIds
        }
    }
}

private struct ImportJobRow: View {
    let job: ImportJob
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stateIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if job.canCancel {
                    actionButton(systemName: "xmark.circle", help: "取消存入", action: onCancel)
                } else if job.canRetry {
                    actionButton(systemName: "arrow.clockwise", help: "重试失败项目", action: onRetry)
                } else if !job.state.isActive {
                    actionButton(systemName: "xmark", help: "关闭", action: onDismiss)
                }
            }

            if job.state == .preflighting {
                ProgressView()
                    .controlSize(.small)
            } else if job.state == .importing || job.state == .cancelling {
                ProgressView(value: job.progress)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .queued, .preflighting, .importing, .cancelling:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 16, height: 16)
        case .retrying:
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.blue)
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16, height: 16)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private var title: String {
        switch job.state {
        case .queued:
            return "等待存入 \(job.totalItems) 个项目"
        case .preflighting:
            return "正在检查 \(job.totalItems) 个项目"
        case .importing:
            return "正在存入 \(job.completedItems)/\(job.totalItems) 个项目"
        case .cancelling:
            return "正在取消并清理临时文件"
        case .retrying:
            return "已创建重试任务"
        case .completed:
            return "已存入 \(job.importedItemCount) 个项目"
        case .failed:
            return "已存入 \(job.importedItemCount) 个，\(job.failures.count) 个失败"
        case .cancelled:
            return job.needsRecovery ? "已取消，但清理未完成" : "存入已取消"
        }
    }

    private var detail: String {
        switch job.state {
        case .queued:
            return "等待前一个任务完成"
        case .preflighting:
            return "检查数量、大小、配额和磁盘空间"
        case .importing, .cancelling:
            let bytes = job.totalBytes > 0
                ? "\(format(job.completedBytes)) / \(format(job.totalBytes))"
                : "准备复制"
            if let currentItemName = job.currentItemName, !currentItemName.isEmpty {
                return "\(bytes)  ·  \(currentItemName)"
            }
            return bytes
        case .retrying:
            return "原失败记录已锁定，不能重复提交"
        case .completed:
            return format(job.completedBytes)
        case .failed:
            if let cleanupFailure = job.cleanupFailures.first {
                return "需要恢复：\(URL(fileURLWithPath: cleanupFailure.path).lastPathComponent)"
            }
            return job.failures.first?.message ?? "可重试失败项目"
        case .cancelled:
            if let cleanupFailure = job.cleanupFailures.first {
                return "需要恢复：\(URL(fileURLWithPath: cleanupFailure.path).lastPathComponent)"
            }
            return job.retryURLs.isEmpty ? "临时文件已清理" : "可重新存入原始项目"
        }
    }

    private func actionButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
