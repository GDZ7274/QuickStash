# QuickStash 1.1.0 (2) 修复与交付审计

更新时间：2026-07-28

## 结论

本轮已完成菜单栏拖文件卡死修复、普通窗口拖近图标误弹修复、文件导入工程化、截图功能，以及文字、HTTP(S) 链接和图片的实时剪贴板历史同步。全局拖动事件不读取拖拽剪贴板或协调源文件，只武装不可见接收层；只有 AppKit 确认真正的 `.fileURL` 拖放后才显示收录界面。普通窗口标题栏拖动不会显示收录窗或悬停预览，Finder 文件靠近自动显示能力保留。复制、目录遍历、持久化、恢复、截图渲染、编码和保存均不在主线程执行。

版本号已统一为 `1.1.0 (2)`。截图使用 ScreenCaptureKit，不使用 `CGWindowListCreateImage`，没有外部依赖、辅助功能权限请求或虚构的 plist 截图权限键。

## 拖放与文件管线

### 卡死修复

- 全局事件监听只转发 `mouseMoved`、`leftMouseDragged` 和 `leftMouseUp` 类型，`GlobalPointerEventRelay` 将高频事件合并为最多一个待处理的主线程回调，并保留时间上最新的事件；上一轮 `leftMouseUp` 不会压过下一轮新到达的 drag。
- 靠近检测只计算状态栏图标、热区、覆盖窗和鼠标的屏幕坐标，不访问 Finder 拖拽剪贴板。
- 任意拖动进入热区时只 `armDropTarget()`：创建透明、无阴影的前层拖放目标但不绘制内容。只有 `DraggableStatusButton` 或 `DropOverlayView` 的原生 `draggingEntered` 确认 `.fileURL` 后才 `showOverlay()`；普通窗口拖动不会产生该回调。
- 状态栏悬停由 `StatusItemHoverGate` 抑制：按住任意鼠标键进入时不显示，并要求指针先真正离开图标才能恢复普通 hover。成功文件投递仍通过专用路径显示收录结果。
- 透明目标由 100 ms 左键状态看门狗、全局/本地 `leftMouseUp`、后续 `mouseMoved`、`draggingEnded`、截图暂停和应用退出共同清理；即使终止事件偶发丢失，也不会长期留下透明点击遮挡层。
- `DraggableStatusButton` 和 `DropOverlayView` 在进入/移动阶段只检查 `.fileURL` 类型，真正投递时才提取 URL 字符串；提取上限为默认 500 个源项目加 1 个超限哨兵，不调用 `NSFileCoordinator`，也不在拖放回调里打开或遍历源文件。
- 覆盖窗的显示/隐藏使用 generation token，使过期定时器不能关闭新一轮拖放窗口。截图暂停会同步清除按钮 tint、接收态和覆盖层高亮；应用退出先挂起 gate、移除全局与本地 monitor、释放 relay 并无条件 `orderOut`，排队事件不能在异步 flush 期间重新武装窗口。

### 已保留并验证的能力

- `copyfile`/`fcopyfile` 回调提供逐字节和逐项进度，并能从回调中中止当前文件或目录复制。
- 预检和复制后复检覆盖单批源数量、目录条目数、单项大小、批次大小、50 GB 总配额、磁盘可用量和预留空间。
- 临时副本进入 `Importing`，完成后原子移动；取消或失败会回滚本批已提交项目并持久化未完成清理状态。
- 导入、删除和孤儿恢复使用持久化 manifest。应用重启后可恢复已复制但尚未进入 metadata 的文件，并清理 partial、orphan 和中断删除状态。
- `items.json` 采用带 schema version 的原子写入，支持旧数组迁移、损坏备份、未来版本只读保护、revision 去旧和退出前异步 flush。
- 剪贴板首次使用要求明确授权，“启用实时记录”为主操作；监听可关闭，以 `0.25` 秒间隔记录文字、HTTP(S) 链接、PNG 和 TIFF，过滤常见 concealed/transient 类型，并有限额和保留数量/期限。后台读取绑定稳定 `changeCount`，内部写入只抑制自己的精确计数，不再取消已经稳定读到的外部图片。正常退出会在有界等待后确认最后一条 provisional 文字或链接、排空进行中的图片保存并刷盘，重启恢复时不会重复记录。
- `FailSelectedQuarantine` 按标准化源路径注入一次失败，不再依赖 `Set<UUID>` 的无序遍历；临时 `phase3:` 输出已删除。

## 截图实现

### 入口与捕获

- 全局快捷键默认 `Command-Shift-A`，可在设置中录制修改。
- Carbon `RegisterEventHotKey` 使用 `kEventHotKeyNoOptions` 注册；回调校验 `QSTS` signature 后才分发，冲突会显示错误，失败时旧快捷键继续有效，退出时完成注销和 handler 清理。
- 状态栏右键菜单和主窗口相机按钮使用同一 `ScreenshotCoordinator`。
- ScreenCaptureKit 为每块显示器分别生成截图；每块屏幕有独立覆盖窗、选区和编辑历史。用户点击哪块屏幕，哪块成为当前输出屏幕。
- 同一次 `SCShareableContent` 快照提供顶层窗口边界；`CGWindowListCopyWindowInfo` 只读取窗口 ID 的前后顺序，不获取图像。未建立选区时悬停高亮最前窗口，单击按每屏可见交集吸附，拖动仍可自由框选。完整可见的普通窗口按标准 `10 pt` macOS 圆角和该屏实际像素比例生成圆角；跨屏裁切或铺满显示器时保持直角，避免在显示器裁切边缘伪造圆角；不请求辅助功能权限。
- 捕获 continuation 具备成功、错误、取消和 10 秒超时的单次完成门禁，迟到回调不会二次 resume。
- 覆盖窗调用 `NSPanel` 指定初始化器，避免带 `screen:` 的便利初始化器重新进入子类未实现的 designated initializer。Hosted XCTest 会为每个已连接屏幕实际构造并关闭覆盖窗。

### 选择与标注

- 屏幕点坐标按每块捕获图像的实际像素尺寸映射并四舍五入到整数物理像素，覆盖负坐标、垂直排列和混合缩放显示器。
- 选区提供四角和四边中点共 8 个手柄，可缩放、移动、显示坐标与像素尺寸；首次提交非空标注后选区边界永久锁定。自动窗口圆角随吸附选区落定，手动画框默认直角；建立选区后可通过独立图标和无刻度滑杆无级调整四角，取值为 `0...min(120 px, 短边/2)`，边界锁定后仍可调整。
- 标注包括箭头、无填充矩形、自由涂鸦、马赛克和文字；支持命中选择、移动、手柄缩放、箭头端点调整、样式修改和删除。涂鸦采用圆头圆角路径，一次轨迹只提交一个 undo 步骤。
- 主工具栏不再常驻颜色和 `2/4/6` 粗细按钮。点击箭头、矩形或涂鸦时直接展开 6 个无残留字符的实色色块和 `1...24 px` 无刻度连续滑杆；文字使用明确的文字工具且只展开颜色，马赛克不展开无效样式。当前工具图标和辅助功能值会直观显示所选颜色与粗细。
- 箭头头长最多 36 个源像素且不超过箭身长度的 40%。箭杆再使用分段非线性映射：样式宽度 `1...4 px` 原样绘制，超过 `4 px` 的增量按 30% 压缩，因此 `8/16/24 px` 分别得到 `5.2/7.6/10 px` 箭杆；预览和最终输出共用同一物理像素公式，放大箭头时箭杆不会随样式值等比例变粗。
- 粗细调整使用独立 `ScreenshotLineWidthAdjustment` 事务，圆角调整使用独立 `ScreenshotCornerRadiusAdjustment` 事务：滑动期间实时预览，多次预览只提交一个 undo 步骤；取消、切屏或关闭覆盖层恢复原值，撤销/重做、删除、改色、切工具、复制和保存会先结算预览。Retina 上 `1 px` 预览按一个物理像素绘制。
- 文字编辑使用真实 `NSTextView`；IME marked text 期间 Enter 不会误提交，完成组字后可提交，双击可重新编辑。
- 历史以统一 `ScreenshotEditValue` 保存标注和选区圆角，最多支持 100 步撤销/重做；圆角滑动可单独撤销和重做且不改变已有标注，分支编辑会清空 redo 栈。圆角提交同时触发会话 mutation，使旧 revision 的异步输出失效。

### 输出与会话隔离

- 复制输出只编码 PNG；同一份数据先准备托管的剪贴板历史图片，系统剪贴板写入成功后恰好提交一次。取消、过期 token 或写入失败会清理准备文件，不会产生迟到历史项。圆角之外的像素保持透明，圆弧边缘保留抗锯齿 Alpha。
- 点击复制按钮或已有选区外的暗区都会走同一异步复制链路；只有 PNG 成功写入系统剪贴板后才关闭覆盖层，失败会保留编辑状态。
- 另存为支持 PNG 和 JPEG：PNG 保留透明圆角，JPEG 在编码前将透明像素显式合成到不透明白底，quality 为 `0.95`。渲染和编码由串行 actor 执行；保存先在目标目录生成临时文件，再通过输出 commit gate 提交。
- `ScreenshotSessionGate` 为每次会话和编辑维护 generation/revision；每个输出另有 operation UUID。捕获、马赛克预览、渲染、编码和保存均检查当前 token；最终提交先在短时纯内存锁内完成取消/token 校验，再由输出 actor 执行原子 `rename`。主线程的取消与 revision 更新不等待文件系统，迟到完成回调仍由 operation/token 二次拦截。
- 截图开始后 `DragPresentationGate` 进入 suspended 状态，立即隐藏投递窗并禁用接收；截图完成或取消时恢复。

## 主线程与死锁审计

- 生产退出路径为 `applicationShouldTerminate -> await flushForTermination()`，不会从主线程 `sync` 等待 metadata queue。
- MainActor 不再暴露同步持久化入口。`StorageManager.flushSynchronously()` 和 `loadSnapshotSynchronously()` 仅由隔离测试直接调用，生产退出统一使用异步 `flushForTermination()`。测试宿主的 ViewModel 采用 lazy 初始化，`QUICKSTASH_TEST_MODE` 早退不会启动真实目录 bootstrap。
- 文件系统读取、路径解析、容量计算、复制、恢复、删除、图片读写和 Trash 清理由 `com.quickstash.file-io` 执行；metadata 读写由 `com.quickstash.metadata-io` 执行。拖出预览使用已有类型图标，不再同步查询文件图标。
- 截图保存的输出状态锁只读写 generation/revision token，不再跨越临时文件删除或 `rename`。Hosted 回归会故意阻塞文件提交，并确认 MainActor 的 invalidate 在 100 ms 上限内立即返回。
- `FileImportProgressEmitter.finish()` 最多等待一次节流窗口，但它只在 file-I/O queue 上运行。生产源码没有 `DispatchSemaphore.wait()`、主线程 `DispatchQueue.sync` 或 `NSFileCoordinator`。
- `copyfile`/`fcopyfile` 的取消依赖系统回调。若 File Provider、网络卷或 iCloud 的底层 syscall 长期不返回，当前没有可强制终止 syscall 的严格墙钟上限，串行 file-I/O queue 可能被占用到系统调用返回；这是 OS/存储提供器边界，不是主线程同步等待。
- `NSAlert` 的权限/隐私选择和系统 `NSSavePanel` 是显式用户交互的模态边界，不承载文件复制、渲染或持久化工作。
- 串行 actor/queue 的回调只异步返回 MainActor；没有发现 queue 反向同步等待或循环锁依赖。

## 自动化验证记录

验证均使用 `/tmp` 或隔离的 `CFFIXED_USER_HOME`，未读写真实 `~/Library/Application Support/QuickStash`。

1. `verify_without_xcode.sh`：通过。
2. `verify_without_xcode.sh` 连续 20 次：20/20 通过；每轮包含 100 个完整组件压力循环，每个循环都执行取消、命名剪贴板 PNG 复制、PNG 保存和 JPEG 保存。
3. Xcode Debug：通过。
4. Xcode Release：通过。
5. `SWIFT_STRICT_CONCURRENCY=complete`：通过。
6. `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`：通过。
7. Xcode Analyze：通过。
8. Hosted XCTest：33/33 通过、0 失败、0 跳过；除原有截图/IME/输出与拖放覆盖外，覆盖箭杆非线性压缩、端点拉伸不增粗、自动窗口圆角、圆角滑动事务与撤销/重做、PNG 透明角、JPEG 白底合成、慢文件提交期间 MainActor 不阻塞，以及最后一条文字、URL 和进行中图片在正常退出后的持久化恢复。
9. Thread Sanitizer Hosted XCTest：33/33 通过、0 失败、0 跳过，未报告数据竞争。
10. 坐标、多屏混合缩放、8 手柄、箭杆缩放、自动/手调圆角、100 步 undo/redo、真实 `NSTextView` IME、快捷键冲突、PNG/JPEG、文字/URL/PNG/TIFF 剪贴板和像素方向：通过。
11. 截图与拖文件互斥 generation token：通过。
12. 100 轮合成截图会话 gate、确定性 pre-cancel、命名剪贴板复制、PNG 保存和 JPEG 保存完整组件压力：通过。
13. 主线程同步 I/O、信号量等待和死锁风险静态审计：通过；输出锁跨 `rename/remove` 的风险已修复并由阻塞注入测试覆盖，边界见上一节。
14. 本次最终 Debug 二进制真实 ScreenCaptureKit 压力：当前 ad-hoc `cdhash` 已获 macOS 屏幕与系统录音授权，结构化报告为 `passed`、100/100；真实显示器捕获、取消检查、命名剪贴板 PNG 写入、PNG 保存和 JPEG 保存均各完成 100 次。
15. 可见 UI：隔离 HOME 验收确认了主窗口相机入口、窗口单击吸附的 `10 px` 默认圆角、复制成功后自动退出，以及普通文字、HTTP(S) 链接、外部 PNG 和 QuickStash 截图 PNG 的历史记录与重启恢复；截图历史文件与系统剪贴板 PNG 哈希一致且只出现一次。普通窗口移动未触发可见误弹，但快速 Finder 拖动无法可靠命中需先武装的接收层，因此没有把工具合成操作计作真实 Finder/标题栏交替拖动验收。

可复现的验证矩阵和仍需特定环境覆盖的项目记录在 `docs/VALIDATION.md`。

## 仍需人工或发布环境验证

- 当前机器可自动验证混合 DPI/负坐标的坐标模型，但仍需在实际多显示器、不同缩放组合上人工操作每屏选区、IME 和工具栏布局。
- 仍需在真实应用间验证 Carbon 快捷键冲突，以及 Save Panel 的取消和覆盖流程。
- 需人工交替拖动普通窗口标题栏与 Finder 文件到菜单栏热区，确认前者不弹、后者自动显示并可投递；iCloud 未下载文件、外接卷/只读卷、源文件中途消失和磁盘临界状态仍应在对应硬件/账号环境验收。
- 发布前需要配置正式 Developer ID team，完成签名、公证、staple 和干净机器安装验证。
- 本轮按约束未修改 `/Applications/QuickStash.app` 或 Launch at Login，未执行 `tccutil reset`，也未启用 App Sandbox；最终 Debug 的屏幕录制权限由用户在系统设置中手工授予。若未来改变分发策略，必须重新验证 security-scoped URL 和拖放。

## 明确不在 1.1.0 范围

OCR、长截图、浏览器页面元素识别、微信直发、线条、椭圆、模糊和跨屏连续选区未实现，符合本轮范围约束。已实现的是无需辅助功能权限的可见顶层 macOS 窗口吸附，不等同于滚动整页截图。
