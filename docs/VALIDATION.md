# QuickStash 1.1.0 (3) 验证记录

初次验证日期：2026-07-28

安装镜像复验日期：2026-08-03

剪贴板图片可靠性复验日期：2026-08-27

最终安装镜像复验日期：2026-08-27

本文只保留可复现的验证结论，不记录本机用户名、临时目录、PID、临时代码身份或交付二进制哈希。

## 2026-08-27 剪贴板图片可靠性复验

- PNG、TIFF、JPEG、HEIC 和 WebP 单一/后备表示均可读取，并统一生成真实 PNG 历史文件。
- 首选 PNG 暂不可用、数据不完整或输出超限时继续尝试后备图片表示；图片最终不可用时保留同一事件的文字/链接后备。
- TIFF/JPEG 转换保持物理像素尺寸，EXIF 方向转正，TIFF Alpha 保留；旧 TIFF 历史复制时输出 PNG 且原文件不被改写。
- 图片源、单边尺寸、总像素、位深/通道估算解码内存、实际 raster 和 PNG 输出均有上限；PNG 原样保留前校验 chunk、CRC 并立即解码像素。
- 不可取消的同步 provider 最多并行两条；软超时、迟到同计数提交、新旧计数隔离、跨停用 generation、有界退出和保存取消均有确定性回归测试。
- 纯文字和 URL 一次稳定读取即提交；Hosted 实时同步用例连续 10 次通过，明确声明的待就绪图片仍保留后备文字和有限重试。

## 2026-08-27 最终安装镜像复验

- Release Archive 和 DMG 均从最终源码重新构建，版本为 `1.1.0 (3)`。
- DMG 通过 `hdiutil verify`，只读挂载后包含 `QuickStash.app` 和指向 `/Applications` 的安装链接。
- 挂载镜像中的 App 主程序与 `QuickStashClipboardReader` helper 均为 `x86_64 + arm64` 通用二进制。
- App 通过 `codesign --verify --deep --strict`；App 和 helper 均为 ad-hoc Hardened Runtime 签名，不含 `get-task-allow`。
- Release 主程序、helper 和 App bundle 均不含 LLVM profile 符号、section 或 `.profraw` 文件。
- 当前机器没有 Developer ID Application 身份，因此该镜像是本机测试版，未公证或 staple。

## 2026-08-03 安装镜像复验（1.1.0 (2) 历史记录）

- `verify_without_xcode.sh` 单独运行通过；另有 4 个完全隔离的并发实例同时通过，每个实例均包含 100 次截图组件循环。
- Release `clean build` 通过，Swift strict concurrency 与 warnings-as-errors 保持开启。
- Release 显式关闭代码覆盖率，最终可执行文件不包含 LLVM profile 符号，实际启动后未生成 `default.profraw`。
- Hosted XCTest：33/33 通过，0 失败、0 跳过。
- DMG 校验通过；挂载后的 App 为 `x86_64 + arm64` 通用二进制，版本为 `1.1.0 (2)`。
- App 复制到隔离安装目录后签名验证和实际启动均通过，运行日志为空，未访问真实 QuickStash Application Support。
- 交付 App 使用 Hardened Runtime 的 ad-hoc 本地签名，不含 `get-task-allow`；仍未完成 Developer ID 签名、公证或 staple。

## 自动化矩阵

- `verify_without_xcode.sh` 连续运行 20 次：20/20 通过。
- 每次无 Xcode 验证包含 100 个完整截图组件循环，共 2000 个循环。
- Debug 构建：通过。
- Release 构建：通过。
- `SWIFT_STRICT_CONCURRENCY=complete`：通过。
- `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`：通过。
- Xcode Analyze：通过。
- Hosted XCTest：33/33 通过，0 失败、0 跳过。
- Thread Sanitizer Hosted XCTest：排除依赖未插桩 helper 读取系统剪贴板的单个跨进程用例后 32/32 通过；剪贴板 ViewModel、helper 超时和 `changeCount` 状态机另以独立 TSan 可执行文件通过，均未报告数据竞争。
- 真实 ScreenCaptureKit 压力：100/100 通过。

## 覆盖范围

### 文件与拖放

- 普通窗口拖动不会触发 `.fileURL` 收录界面。
- Finder 文件拖放只在原生 `NSDraggingInfo` 确认后显示和解析。
- 全局指针事件合并、松手清理、看门狗和截图暂停互斥。
- 文件预检、复制、取消、进度、配额、磁盘空间和 recovery manifest。
- import partial、committed orphan 和 deletion manifest 恢复。
- `FailSelectedQuarantine` 按明确标准化源路径注入失败。

### 剪贴板

- 普通文字、显式 URL、纯文本 HTTP(S) 链接，以及 PNG、TIFF、JPEG、HEIC 和 WebP 图片。
- provider 延迟物化、稳定 `changeCount`、重试和只记录一次。
- 图片统一 PNG 落盘、格式后备、旧 TIFF 内存转 PNG、迟到 provider 和最多两条读取 lane。
- 内部复制只抑制精确的自身 `changeCount`。
- 外部图片保存不会被后续文字或链接复制取消。
- QuickStash 截图 PNG 在系统写入成功后准确提交一次历史。
- 正常退出时 provisional 文字、URL 和进行中的图片保存会完成并刷盘。
- 重启后内容恢复且不重复。
- 关闭记录和清空历史保持立即失效语义。

### 截图与编辑

- ScreenCaptureKit 捕获和取消。
- 多屏坐标、负坐标、混合缩放和物理像素转换。
- 8 个手柄、移动、缩放、窗口吸附和自动/手调圆角。
- 箭头、矩形、涂鸦、马赛克和 `NSTextView` 中文 IME。
- 标注选择、移动、调整、样式修改和删除。
- 100 步撤销/重做及分支失效。
- PNG 透明圆角和 JPEG 白底合成。
- `0.95` JPEG 质量和保存取消。
- generation/revision/operation token 的迟到结果拒绝。
- 截图会话与菜单栏拖文件呈现互斥。

## 真实捕获压力

获 macOS 屏幕录制权限的同一 Debug 构建完成：

- 100 次真实显示器捕获。
- 100 次取消检查。
- 100 次命名剪贴板 PNG 写入。
- 100 次 PNG 保存。
- 100 次 JPEG 保存。
- 其中 50 次覆盖圆角 PNG 透明角和 JPEG 白角。

## 主线程与死锁审计

生产 Swift 源码未使用：

- `DispatchQueue.main.sync`
- `DispatchSemaphore.wait()`
- `NSFileCoordinator`
- `CGWindowListCreateImage`

文件、metadata、渲染、编码和保存工作由专用串行 queue 或 actor 执行。输出状态锁只保护内存 token，不跨越 `remove` 或 `rename` 文件 I/O。

## 本地复现

基础验证：

```bash
./verify_without_xcode.sh
```

Hosted XCTest：

```bash
xcodebuild \
  test \
  -project QuickStash.xcodeproj \
  -scheme QuickStash \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/quickstash-xctest
```

所有测试应使用 `/tmp`、临时目录或隔离的 `CFFIXED_USER_HOME`，不得读写真实 QuickStash Application Support。

## 仍需特定环境验证

- 实际混合 DPI 多显示器上的每屏选区、工具栏和 IME 候选窗。
- 交替进行普通窗口标题栏拖动和 Finder 文件真实拖近菜单栏图标。
- 与其他应用发生的真实 Carbon 快捷键冲突。
- Save Panel 取消、覆盖及其他应用中的 PNG/JPEG 兼容性。
- iCloud 未下载文件、外接卷、只读卷、源消失和磁盘临界状态。
- Developer ID 签名、公证、staple 和干净机器安装。
