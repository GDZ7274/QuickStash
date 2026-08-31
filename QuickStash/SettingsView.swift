import SwiftUI

struct SettingsView: View {
    @ObservedObject var launchManager = LaunchAtLoginManager.shared
    @ObservedObject var clipboardMonitor = ClipboardMonitor.shared
    @ObservedObject var viewModel = StashViewModel.shared
    @ObservedObject var screenshotPreferences = ScreenshotPreferences.shared
    @ObservedObject var hotKeyManager = GlobalHotKeyManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var showClearConfirmation = false
    @State private var isClearing = false
    @State private var clearSummary: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingRow(
                        title: "开机自启动",
                        detail: "登录时自动启动 QuickStash"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { launchManager.isEnabled },
                            set: { _ in launchManager.toggle() }
                        ))
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("截图快捷键")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            ShortcutRecorderView(descriptor: screenshotPreferences.hotKey) { descriptor in
                                _ = hotKeyManager.update(descriptor)
                            }
                            .frame(width: 116, height: 28)
                        }
                        if let error = hotKeyManager.registrationError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                    .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("剪贴板实时记录")
                                    .font(.system(size: 14, weight: .medium))
                                Text(consentDescription)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if clipboardMonitor.consent == .undecided {
                                HStack(spacing: 8) {
                                    Button("保持关闭") { clipboardMonitor.setConsent(.disabled) }
                                    Button("启用") { clipboardMonitor.setConsent(.enabled) }
                                        .buttonStyle(.borderedProminent)
                                }
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { clipboardMonitor.isEnabled },
                                    set: { clipboardMonitor.setEnabled($0) }
                                ))
                                .labelsHidden()
                            }
                        }

                        Divider()

                        Picker("最多保留", selection: Binding(
                            get: { clipboardMonitor.retentionCount },
                            set: { value in
                                clipboardMonitor.setRetentionCount(value)
                                viewModel.updateClipboardRetentionPolicy(clipboardMonitor.retentionPolicy)
                            }
                        )) {
                            Text("50 条").tag(50)
                            Text("100 条").tag(100)
                            Text("200 条").tag(200)
                            Text("不限").tag(0)
                        }
                        .pickerStyle(.menu)

                        Picker("最长保留", selection: Binding(
                            get: { clipboardMonitor.retentionDays },
                            set: { value in
                                clipboardMonitor.setRetentionDays(value)
                                viewModel.updateClipboardRetentionPolicy(clipboardMonitor.retentionPolicy)
                            }
                        )) {
                            Text("1 天").tag(1)
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("不限").tag(0)
                        }
                        .pickerStyle(.menu)

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("清理剪贴板记录")
                                    .font(.system(size: 13, weight: .medium))
                                Text("固定内容、拖入文件和系统剪贴板不受影响")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                showClearConfirmation = true
                            } label: {
                                if isClearing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("清理", systemImage: "trash")
                                }
                            }
                            .disabled(isClearing)
                        }

                        if let clearSummary {
                            Text(clearSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                    .cornerRadius(8)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Design by GDZ")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(Self.versionDescription)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .combine)
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 520)
        .background(.ultraThinMaterial)
        .alert("清理未固定的剪贴板记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { clearClipboardHistory() }
        } message: {
            Text("只清理 QuickStash 中未固定的剪贴板文字、链接和图片。不会清空系统剪贴板，也不会删除拖入的文件。")
        }
    }

    private var consentDescription: String {
        switch clipboardMonitor.consent {
        case .undecided: return "尚未授权；启用后记录新复制的文字、链接和图片"
        case .enabled: return "已启用；每 0.25 秒检查变化，敏感类型会跳过"
        case .disabled: return "已关闭；不会读取新的剪贴板内容"
        }
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "Version \(version) (\(build))"
    }

    private func settingRow<Accessory: View>(
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(12)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
        .cornerRadius(8)
    }

    private func clearClipboardHistory() {
        isClearing = true
        Task {
            let result = await viewModel.clearUnpinnedClipboardItems()
            isClearing = false
            clearSummary = result.failedCount == 0
                ? "已清理 \(result.removedCount) 条记录"
                : "已清理 \(result.removedCount) 条，\(result.failedCount) 条图片因隔离失败而保留"
        }
    }
}
