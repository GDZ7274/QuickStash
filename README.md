<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="QuickStash app icon">
</p>

# QuickStash

QuickStash 是一款原生 macOS 菜单栏工具，用于临时收录文件、实时记录剪贴板内容，以及完成带标注的区域截图。项目基于 AppKit、SwiftUI、ScreenCaptureKit 和 Carbon 构建，不依赖第三方运行库。

当前版本：`1.1.0 (4)`

**Design by GDZ**

> 本仓库公开提供源码用于查看、学习、问题复现和个人非商业评估，但不是开源软件。GDZ 保留全部权利；复制、修改、再分发、商用和品牌使用边界以 [LICENSE](LICENSE) 为准。

## 主要功能

### 剪贴板历史

- 首次启用前要求应用内明确授权，之后可随时在设置中关闭。
- 每 `0.25` 秒检查一次系统剪贴板，记录普通文字、显式或纯文本 HTTP(S) 链接，以及 PNG、TIFF、JPEG、HEIC/HEIF、WebP 等系统可解码图片。
- 再次复制已有文字或链接时保留原记录 ID 和固定状态，并把它刷新到列表最前，不生成重复记录；QuickStash 自身的复制按钮遵循相同规则，且只有系统剪贴板写入成功后才刷新。
- 所有新剪贴板图片都会在后台解码、校正 EXIF 方向并统一编码为真实 PNG 后写入 `Images`；旧 TIFF 历史复制出去时也会在内存中转换为 PNG，不改写旧历史文件。
- 图片重复判断基于规范化后的像素指纹；解码后像素完全一致时，不受来源容器或编码字节差异影响。重复复制会刷新已有记录到最新位置，不生成多份历史，原有固定状态保持不变。
- 启动恢复期间产生的重复项会建立 incoming ID 到 canonical ID 的别名；并发发生的删除、固定、复制确认和迟到图片复制都会落到最终保留的记录，不会用临时 ID 复活重复项。
- 冗余图片丢弃会先写入删除 intent；manifest 保存源文件设备号与 inode，恢复时不会误删后来复用同一路径的新文件。损坏图片由同像素新 PNG 接管时，先持久化 replacement intent，再切换并刷入 metadata，随后隔离旧 backing，最后确认 manifest。中途退出后由下次启动继续，不会留下无恢复依据的半完成替换。
- 启动恢复会合并旧版本遗留的同像素图片记录，保留 canonical ID、固定状态并采用最新时间；canonical backing 损坏但存在有效同指纹 orphan 时，会保留原记录身份并接管有效 backing。无法解码且没有引用的图片 orphan 会被隔离，不会作为历史恢复。
- QuickStash 自身复制的截图 PNG 也会在系统剪贴板写入成功后准确记录一次。
- 纯文字和 URL 在一次稳定读取后立即进入历史；只有剪贴板明确声明了尚未就绪的图片表示时，才保留后备文字并有限重试。
- 通过稳定的 `changeCount`、最多两条有界 provider 读取 lane、迟到结果精确绑定和内部写入抑制，避免遗漏、重复或旧请求污染新内容。不可取消的同步读取采用软超时，瞬时图片保存失败最多重试两次。
- 正常退出会在全局 8 秒总预算内尽力确认最后一条文字或链接、排空图片工作并刷入最新 metadata revision；完成或超时都只向 macOS 回复一次，底层 I/O 永久不返回时不会让 App 无限卡在退出阶段。尚未完成的可恢复清理由 manifest 在下次启动继续。
- 默认最多保留 100 条、最长 30 天；固定项目不会被自动清理。

### 文件暂存

- 将 Finder 文件拖近菜单栏图标后显示收录窗口；普通窗口标题栏拖动不会误触发。
- 文件发现、容量检查、复制、清理和恢复均在非主线程执行。
- 支持逐字节和逐项进度、取消、50 GB 配额、磁盘空间预检及复制后复检。
- 导入先进入 `Importing`，完成后原子移动到 `Files`；中断导入和 orphan 文件会在下次启动时恢复。
- 删除内容先进入 QuickStash 自有的七天 Trash；顶层和嵌套符号链接会被拒绝。

### 截图与标注

- 三个入口：全局快捷键、状态栏菜单、主窗口相机按钮。
- 默认快捷键为 `Command-Shift-A`，可自定义；使用 Carbon 非独占注册并处理冲突和注销。
- 使用 ScreenCaptureKit 捕获每块显示器，不使用 `CGWindowListCreateImage`。
- 支持每屏独立物理像素选区、8 个缩放手柄、移动、缩放和窗口单击吸附。
- 完整可见的普通窗口自动使用标准 macOS 圆角；选区圆角可在 `0...120 px` 范围内无级调节。
- 标注工具包括箭头、无填充矩形、自由涂鸦、马赛克和文字。
- 支持已有标注的选择、移动、调整、改色、删除，以及最多 100 步撤销和重做。
- 文字编辑基于 `NSTextView`，支持中文输入法 marked text 和双击重新编辑。
- 可复制透明圆角 PNG，或另存为 PNG/JPEG；JPEG 质量为 `0.95`。
- 截图期间暂停菜单栏拖文件呈现，结束或取消后恢复。
- 捕获、渲染、编码和保存均受 session generation/revision 与 operation token 保护。

## 系统要求

- macOS 14.0 或更高版本。
- 当前命令行验证脚本面向 Apple Silicon `arm64`。
- 推荐 Xcode 26.6；当前源码按 Swift 5 language mode 构建。
- `verify_without_xcode.sh` 不调用 `xcodebuild`，但仍需要 Xcode Command Line Tools、`xcrun`、`swiftc`、`plutil` 和 `rg`。
- 无第三方运行时依赖。

## 获取源码

仓库公开提供源码，可直接克隆：

```bash
git clone https://github.com/GDZ7274/QuickStash.git
cd QuickStash
open QuickStash.xcodeproj
```

## 构建与运行

在 Xcode 中选择共享 scheme `QuickStash`，然后运行 Debug 构建。也可以使用隔离的 DerivedData：

```bash
xcodebuild \
  -project QuickStash.xcodeproj \
  -scheme QuickStash \
  -configuration Debug \
  -derivedDataPath /tmp/quickstash-derived-data \
  build
```

Release 构建：

```bash
xcodebuild \
  -project QuickStash.xcodeproj \
  -scheme QuickStash \
  -configuration Release \
  -derivedDataPath /tmp/quickstash-release \
  build
```

首次截图时，macOS 会请求“屏幕与系统音频录制”权限。授权后需要重新启动当前构建。QuickStash 不需要辅助功能权限。

## 验证

基础回归命令：

```bash
./verify_without_xcode.sh
```

该脚本会使用 `/tmp` 和隔离的 `CFFIXED_USER_HOME`，完成 plist/project 检查、完整 strict-concurrency 和 warnings-as-errors 类型检查、链接检查，以及 core、ViewModel 和截图组件测试。截图组件测试包含 100 次取消、PNG 剪贴板、PNG 保存和 JPEG 保存循环。

`1.1.0 (4)` 的最终门禁已完成：脚本连续 20 次通过，Hosted XCTest 33/33、适用的 Thread Sanitizer 32/32、真实 ScreenCaptureKit 压力 100/100，Debug、Release、Analyze、DMG 校验和隔离 HOME 启动均通过。详细范围与仍需人工覆盖的硬件/签名边界见验证记录。

Xcode Hosted XCTest：

```bash
xcodebuild \
  test \
  -project QuickStash.xcodeproj \
  -scheme QuickStash \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/quickstash-xctest
```

完整验证矩阵见 [docs/VALIDATION.md](docs/VALIDATION.md)，并发与拖放审计见 [AUDIT_AND_ROADMAP.md](AUDIT_AND_ROADMAP.md)。

## 权限与隐私

- 当前源码没有网络请求、遥测、账号系统或云同步。
- 剪贴板记录必须在应用内明确启用，内容只保存在本机。
- 截图只请求 macOS 屏幕录制权限，不请求辅助功能权限。
- 导入文件会复制到 QuickStash 管理目录，不只是保存原始路径引用。
- 当前工程未启用 App Sandbox。

应用数据默认位于：

```text
~/Library/Application Support/QuickStash/
```

详细说明见 [PRIVACY.md](PRIVACY.md)。

## 工程结构

```text
QuickStash/
├── QuickStash/                  # App 源码
├── ClipboardReaderHelper/       # 可超时终止的剪贴板 provider 读取 helper
├── Tests/                       # Core、ViewModel、截图和 Hosted XCTest
├── Assets.xcassets/             # App 图标和资源
├── QuickStash.xcodeproj/        # Xcode 工程与共享 scheme
├── docs/VALIDATION.md           # 可复现验证记录
├── AUDIT_AND_ROADMAP.md         # 并发、拖放和截图技术审计
├── PRIVACY.md                   # 本地数据与权限说明
├── CONTRIBUTING.md              # 公开协作约定
├── LICENSE                      # 源码可查看、保留全部权利条款
├── SECURITY.md                  # 安全问题报告与联系流程
├── CHANGELOG.md                 # 版本变更
└── verify_without_xcode.sh      # 命令行回归入口
```

核心职责：

- `QuickStashApp`：状态栏、窗口生命周期、拖放与截图互斥、带 8 秒总预算的异步退出。
- `ClipboardMonitor`：剪贴板授权、稳定读取、格式回退、文字/链接分类和图片保存协调。
- `StashViewModel`：UI 状态、revision 持久化、导入任务与恢复。
- `QuickStashFileManager`：文件复制、删除、剪贴板图片、两阶段替换 intent 和 orphan 恢复 I/O。
- `StorageManager`：版本化原子 metadata 读写。
- `ScreenshotCoordinator`：截图会话、覆盖窗、取消和输出 token。
- `ScreenshotRenderExecutor`：非主线程渲染、编码、马赛克和保存。

## 当前范围

本版本不包含 OCR、长截图、浏览器页面元素识别、微信直发、线条、椭圆、模糊或跨屏连续选区。窗口吸附仅识别可见顶层 macOS 窗口，不需要辅助功能权限。

## 分发状态

当前构建为开发测试用途的 ad-hoc 签名版本，未完成 Developer ID 签名、公证或 staple。正式分发前应完成干净机器安装、混合 DPI 多屏、真实 Finder 拖放、快捷键冲突、中文输入法候选窗、iCloud/外接卷和 Save Panel 验收。

## 源码许可

本仓库公开不代表授予开源许可。允许的查看、个人评估和 GitHub 平台内协作范围，以及禁止的再分发、商用和品牌使用，详见 [LICENSE](LICENSE)。安全问题请按 [SECURITY.md](SECURITY.md) 先确认可用的私密入口或请求安全联系方式，不要在公开 Issue 中附带漏洞细节、真实剪贴板、文件路径或截图。

## 相关文档

- [验证记录](docs/VALIDATION.md)
- [工程审计与路线图](AUDIT_AND_ROADMAP.md)
- [隐私说明](PRIVACY.md)
- [协作指南](CONTRIBUTING.md)
- [源码许可](LICENSE)
- [安全策略](SECURITY.md)
- [变更记录](CHANGELOG.md)
