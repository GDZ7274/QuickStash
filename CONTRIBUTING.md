# QuickStash 协作指南

本仓库公开提供源码和 Issue/PR 协作入口，但不采用开源许可证。提交贡献即表示你有权提交相关内容，并同意项目维护者在 QuickStash 中使用、修改和分发该贡献；仓库其他内容仍受 [LICENSE](LICENSE) 约束。

## 开发环境

- macOS 14.0+
- Apple Silicon（当前命令行脚本目标为 `arm64`）
- Xcode 26.6 或兼容版本
- Xcode Command Line Tools
- `rg`

打开共享 scheme：

```bash
open QuickStash.xcodeproj
```

## 代码约定

- 保持现有 AppKit、SwiftUI 和 `@MainActor` 边界。
- 文件、metadata、渲染、编码和保存 I/O 不得同步阻塞主线程。
- `MainActor` 不得新增 semaphore/group wait；确需同步桥接时必须位于非主线程、有明确 deadline，并证明不会形成 queue 反向等待。
- 截图异步结果必须继续使用 generation/revision 和 operation token 校验。
- 拖放全局事件不得读取 Finder drag pasteboard；文件 URL 只在原生拖放确认后解析。
- 不使用 `CGWindowListCreateImage`，截图捕获保持 ScreenCaptureKit 路径。
- 不新增外部依赖，除非先说明必要性、维护成本和分发影响。
- 不新增辅助功能权限或虚构的 Info.plist 权限键。
- 保留 UI、README、许可文件中的 `Design by GDZ` 标志；不得删除、遮蔽或误导性修改。

## 剪贴板与恢复不变量

- 重复文字、链接或图片必须保留 canonical ID 和固定状态，只更新时间与排序；bootstrap 期间的 incoming ID 必须通过 alias 解析到 canonical ID，删除、固定、复制确认和迟到回调不得复活临时记录。
- 新剪贴板图片保持真实 PNG；跨容器去重继续使用规范化 sRGB RGBA8 像素指纹，不能退回按文件字节或扩展名比较。
- 冗余图片 discard 必须在移动前写入 deletion intent，失败后保留 manifest 供重启恢复。新版 intent 必须保存并在移动前核对源文件设备号与 inode，防止同路径复用误删。损坏 backing 替换必须遵循“持久化 replacement intent -> 切换并 flush metadata -> 隔离旧 backing -> 确认 manifest”的顺序。
- 旧版同像素记录迁移必须保留 canonical ID，合并固定状态并使用最新时间；canonical backing 损坏但存在有效同指纹 orphan 时，只能接管经过解码与指纹核验的受管理文件。
- 退出排空共享 8 秒总预算；无论完成、取消还是超时，只能对 `applicationShouldTerminate` 回复一次。不得以等待永久阻塞的 provider 或文件 I/O 换取所谓完整 flush。

## 数据隔离

测试不得读写真实的：

```text
~/Library/Application Support/QuickStash
```

使用 `/tmp`、临时目录或隔离的 `CFFIXED_USER_HOME`。测试和脚本不得修改 `/Applications/QuickStash.app`、Launch at Login，也不得执行 `tccutil reset`。

禁止把以下内容提交到仓库：

- `xcuserdata`、`*.xcuserstate`
- `DerivedData`、`.build`、`*.xcresult`
- `*.profraw`、日志和压力测试 JSON
- `.app`、ZIP、签名证书或 provisioning profile
- 真实 QuickStash 应用数据、剪贴板内容和本机绝对路径

## 提交前验证

至少运行：

```bash
./verify_without_xcode.sh
```

影响共享状态、截图会话、文件导入或持久化时，还应运行：

```bash
xcodebuild \
  test \
  -project QuickStash.xcodeproj \
  -scheme QuickStash \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/quickstash-xctest
```

高风险改动需要额外覆盖：

- Debug 和 Release 构建。
- `SWIFT_STRICT_CONCURRENCY=complete`。
- warnings-as-errors。
- Xcode Analyze。
- Thread Sanitizer。
- 截图/取消/复制/保存压力测试。
- 普通窗口拖动与 Finder 文件拖动互斥测试。

## Pull Request 检查清单

- 说明行为变化、风险和不在本次范围内的内容。
- 附上实际执行过的验证命令与结果。
- UI 改动应在普通和 Retina 缩放下检查文本截断、控件重叠和物理像素对齐。
- 权限、持久化格式或数据目录发生变化时，同步更新 `README.md` 和 `PRIVACY.md`。
- 用户可见变化同步更新 `CHANGELOG.md`。
- 确认 `Design by GDZ` 仍存在于设置界面、README 和 LICENSE。
- 安全漏洞按 `SECURITY.md` 使用已核验的私密入口，或只公开请求安全联系方式；不要在公开 Issue 中附带漏洞细节或真实用户数据。
