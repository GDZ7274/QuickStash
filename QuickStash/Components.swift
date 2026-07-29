import SwiftUI

struct HeaderView: View {
    @Binding var isSelectionMode: Bool
    let selectedCount: Int
    let totalCount: Int
    let onDeleteSelected: () -> Void
    let onPinSelected: () -> Void
    let onCancelSelection: () -> Void
    let onSelectAll: () -> Void

    @State private var showSettings = false

    var allSelected: Bool { totalCount > 0 && selectedCount == totalCount }

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Button(action: onCancelSelection) {
                    Text("取消")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Text("已选 \(selectedCount)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onSelectAll) {
                    Text(allSelected ? "取消全选" : "全选")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                if selectedCount > 0 {
                    Button(action: onPinSelected) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDeleteSelected) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 4) {
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
                }
                Spacer()
                Button(action: { ScreenshotCoordinator.shared.startCapture() }) {
                    Image(systemName: "camera")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("截图")

                Button(action: { isSelectionMode = true }) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct SearchBar: View {
    @Binding var text: String
    @Binding var groupMode: GroupMode
    @Binding var typeFilter: ItemType?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)

                TextField("搜索...", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)

                if !text.isEmpty {
                    Button(action: {
                        text = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
            .cornerRadius(10)

            // 快捷分类按钮
            HStack(spacing: 6) {
                TypeFilterButton(
                    type: .text,
                    isActive: typeFilter == .text,
                    action: {
                        if typeFilter == .text {
                            typeFilter = nil
                            groupMode = .time
                        } else {
                            typeFilter = .text
                            groupMode = .type
                        }
                    }
                )

                TypeFilterButton(
                    type: .url,
                    isActive: typeFilter == .url,
                    action: {
                        if typeFilter == .url {
                            typeFilter = nil
                            groupMode = .time
                        } else {
                            typeFilter = .url
                            groupMode = .type
                        }
                    }
                )

                TypeFilterButton(
                    type: .image,
                    isActive: typeFilter == .image,
                    action: {
                        if typeFilter == .image {
                            typeFilter = nil
                            groupMode = .time
                        } else {
                            typeFilter = .image
                            groupMode = .type
                        }
                    }
                )

                TypeFilterButton(
                    type: .others,
                    isActive: typeFilter == .others,
                    action: {
                        if typeFilter == .others {
                            typeFilter = nil
                            groupMode = .time
                        } else {
                            typeFilter = .others
                            groupMode = .type
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct TypeFilterButton: View {
    let type: ItemType
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: type.icon)
                .font(.system(size: 16))
                .foregroundStyle(isActive ? type.color : .secondary)
                .frame(width: 32, height: 32)
                .background(isActive ? type.color.opacity(0.15) : Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct GroupHeader: View {
    let title: String
    let count: Int
    let isLocked: Bool
    let isExpanded: Bool
    let isSelectionMode: Bool
    let allItemsSelected: Bool
    let onToggleExpand: () -> Void
    let onSelectAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("(\(count))")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Spacer()

            if isSelectionMode && isExpanded {
                Button(action: onSelectAll) {
                    Image(systemName: allItemsSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(allItemsSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
            }

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.8))
        .cornerRadius(12)
        .contentShape(Rectangle())
    }
}
