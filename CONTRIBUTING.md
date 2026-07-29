# QuickStash 协作指南

本仓库为私有项目。提交代码前请确认自己已获得仓库访问和修改授权。

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
- 截图异步结果必须继续使用 generation/revision 和 operation token 校验。
- 拖放全局事件不得读取 Finder drag pasteboard；文件 URL 只在原生拖放确认后解析。
- 不使用 `CGWindowListCreateImage`，截图捕获保持 ScreenCaptureKit 路径。
- 不新增外部依赖，除非先说明必要性、维护成本和分发影响。
- 不新增辅助功能权限或虚构的 Info.plist 权限键。

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
