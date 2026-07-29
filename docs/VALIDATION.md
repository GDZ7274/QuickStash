# QuickStash 1.1.0 (2) 验证记录

验证日期：2026-07-28

本文只保留可复现的验证结论，不记录本机用户名、临时目录、PID、临时代码身份或交付二进制哈希。

## 自动化矩阵

- `verify_without_xcode.sh` 连续运行 20 次：20/20 通过。
- 每次无 Xcode 验证包含 100 个完整截图组件循环，共 2000 个循环。
- Debug 构建：通过。
- Release 构建：通过。
- `SWIFT_STRICT_CONCURRENCY=complete`：通过。
- `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`：通过。
- Xcode Analyze：通过。
- Hosted XCTest：33/33 通过，0 失败、0 跳过。
- Thread Sanitizer Hosted XCTest：33/33 通过，未报告数据竞争。
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

- 普通文字、显式 URL、纯文本 HTTP(S) 链接、PNG 和 TIFF。
- provider 延迟物化、稳定 `changeCount`、重试和只记录一次。
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
