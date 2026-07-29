import SwiftUI

// 自定义窗口类，允许无边框窗口接受键盘输入
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }
}

@main
@MainActor
class QuickStashApp: NSObject, NSApplicationDelegate {
    #if DEBUG
        static var isRunningHostedTests: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["QUICKSTASH_TEST_MODE"] == "1"
                || environment["XCTestConfigurationFilePath"] != nil
                || environment["XCInjectBundleInto"] != nil
                || NSClassFromString("XCTestCase") != nil
        }
    #endif

    static func main() {
        let app = NSApplication.shared
        let delegate = QuickStashApp()
        app.delegate = delegate
        app.run()
    }

    var statusItem: NSStatusItem?
    var hoverWindow: NSWindow?
    var hoverWindowFrame: NSRect = .zero
    var floatingWindow: NSWindow?
    var mouseTracker: Any?
    var pointerEventRelay: GlobalPointerEventRelay?
    var localDragTracker: Any?
    var localMouseTracker: Any?
    var draggableButton: DraggableStatusButton?
    var floatingWindowCloseObserver: NSObjectProtocol?
    var terminationTask: Task<Void, Never>?
    // Hosted tests return before touching app state; lazy initialization keeps their I/O isolated.
    lazy var viewModel = StashViewModel.shared

    // 拖拽覆盖窗口（覆盖状态栏附近区域用于接收拖拽）
    var dropOverlayWindow: DropOverlayWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            if Self.isRunningHostedTests {
                return
            }
            if DebugScreenshotStressHarness.launchIfRequested() {
                return
            }
        #endif

        // 隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        statusItem?.autosaveName = "QuickStash"

        if let button = statusItem?.button {
            // 创建自定义拖拽按钮
            let customButton = DraggableStatusButton(frame: button.bounds)
            customButton.onClick = { [weak self] in
                self?.handleClick()
            }
            customButton.onRightClick = { [weak self] in
                self?.showStatusMenu()
            }
            customButton.onFilesDropped = { [weak self] urls in
                self?.handleFilesDropped(urls)
            }
            customButton.onDragEntered = { [weak self] in
                self?.showDropOverlay()
            }
            customButton.onDragExited = { [weak self] in
                self?.scheduleHideDropOverlay()
            }
            customButton.onMouseEntered = { [weak self] in
                self?.showHoverWindow()
            }
            customButton.onMouseExited = { [weak self] in
                // 鼠标离开图标，如果不在悬浮窗内则隐藏
                guard let self = self else { return }
                if let win = self.hoverWindow, win.isVisible {
                    // 给一点延迟让鼠标有机会移入悬浮窗
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let mouse = NSEvent.mouseLocation
                        if !(win.frame.contains(mouse)) {
                            self.hideHoverWindow()
                        }
                    }
                }
            }

            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(customButton)
            customButton.autoresizingMask = [.width, .height]

            draggableButton = customButton

            // Finder 拖拽时状态栏子视图不一定收到 draggingEntered，因此同时监听全局坐标。
            // 这里只判断事件类型和鼠标位置，不读取拖拽剪贴板或文件内容。
            let relay = GlobalPointerEventRelay { [weak self] event in
                self?.handleGlobalPointerEvent(event)
            }
            pointerEventRelay = relay
            mouseTracker = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]
            ) { event in
                switch event.type {
                case .leftMouseDragged:
                    relay.submit(.dragged)
                case .leftMouseUp:
                    relay.submit(.released)
                default:
                    relay.submit(.moved)
                }
            }
            localDragTracker = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]
            ) { event in
                switch event.type {
                case .leftMouseDragged:
                    relay.submit(.dragged)
                case .leftMouseUp:
                    relay.submit(.released)
                default:
                    relay.submit(.moved)
                }
                return event
            }
        }

        ClipboardMonitor.shared.onNewItem = { [weak self] item in
            self?.viewModel.addItem(item)
        }
        ClipboardMonitor.shared.onError = { [weak self] message in
            self?.viewModel.lastError = message
        }
        presentClipboardPrivacyChoiceIfNeeded()
        ClipboardMonitor.shared.startMonitoring()
        ScreenshotCoordinator.shared.configure(
            activityHandler: { [weak self] active in
                self?.setScreenshotInteractionSuspended(active)
            },
            errorHandler: { [weak self] message in
                self?.viewModel.lastError = message
            }
        )

        #if DEBUG
            if ProcessInfo.processInfo.environment["QUICKSTASH_OPEN_WINDOW_ON_LAUNCH"] == "1" {
                createFloatingWindow()
            }

            if let rawPaths = ProcessInfo.processInfo.environment["QUICKSTASH_IMPORT_PATHS"] {
                let urls = rawPaths
                    .split(separator: "\n")
                    .map { URL(fileURLWithPath: String($0)) }
                if !urls.isEmpty {
                    handleFilesDropped(urls)
                }
            }

            if ProcessInfo.processInfo.environment["QUICKSTASH_SHOW_DROP_OVERLAY_ON_LAUNCH"] == "1" {
                showDropOverlay()
            }
        #endif
    }

    private func presentClipboardPrivacyChoiceIfNeeded() {
        guard ClipboardMonitor.shared.consent == .undecided else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "启用剪贴板实时记录"
        alert.informativeText = "自动记录之后复制的文字、链接和图片，内容只保存在本机。之后可随时在设置中关闭。"
        let enable = alert.addButton(withTitle: "启用实时记录")
        enable.keyEquivalent = "\r"
        let keepDisabled = alert.addButton(withTitle: "暂不启用")
        keepDisabled.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        ClipboardMonitor.shared.setConsent(response == .alertFirstButtonReturn ? .enabled : .disabled)
    }

    var lastCheckTime = Date()
    var isHoverWindowShowing = false

    func handleGlobalPointerEvent(_ event: GlobalPointerEventKind) {
        guard !isScreenshotInteractionSuspended else { return }
        switch event {
        case .dragged:
            checkDragPosition()
        case .released:
            if isDragOverlayVisible {
                scheduleHideDropOverlay(after: 0.2)
            } else if isDropTargetActive {
                hideDropOverlay()
            }
        case .moved:
            if isDropTargetActive {
                hideDropOverlay()
            }
            checkMousePosition()
        }
    }

    // MARK: - 鼠标悬停

    func checkMousePosition() {
        guard Date().timeIntervalSince(lastCheckTime) > 0.05 else { return }
        lastCheckTime = Date()

        guard let hoverWin = hoverWindow, hoverWin.isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        if !hoverWin.frame.contains(mouseLocation) {
            // 检查是否在状态栏图标上（避免从图标移入悬浮窗的过渡期误关）
            if let button = statusItem?.button, let buttonWindow = button.window {
                let buttonFrame = button.convert(button.bounds, to: nil)
                let screenFrame = buttonWindow.convertToScreen(buttonFrame)
                if !screenFrame.contains(mouseLocation) {
                    hideHoverWindow()
                }
            }
        }
    }

    // MARK: - 拖拽到顶栏

    var dragPresentationGate = DragPresentationGate()
    var isDragOverlayVisible: Bool { dragPresentationGate.isOverlayVisible }
    var isDropTargetActive: Bool { dragPresentationGate.isActive }
    var isScreenshotInteractionSuspended: Bool { dragPresentationGate.isSuspended }
    var lastDragCheckTime = Date.distantPast
    var hideOverlayTimer: Timer?
    var armedDropTargetWatchdog: Timer?

    func checkDragPosition() {
        guard !isScreenshotInteractionSuspended else { return }
        guard Date().timeIntervalSince(lastDragCheckTime) > 0.05 else { return }
        lastDragCheckTime = Date()

        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let statusFrame = buttonWindow.convertToScreen(buttonFrame)
        let mouseLocation = NSEvent.mouseLocation
        let hotZone = NSRect(
            x: statusFrame.midX - 100,
            y: statusFrame.minY - 200,
            width: 200,
            height: 200 + statusFrame.height
        )
        let overlayContainsMouse = isDropTargetActive
            && dropOverlayWindow?.frame
                .insetBy(dx: -12, dy: -12)
                .contains(mouseLocation) == true

        if statusFrame.contains(mouseLocation) {
            draggableButton?.suppressHoverUntilPointerExit()
        }

        if hotZone.contains(mouseLocation) || overlayContainsMouse {
            cancelScheduledOverlayHide()
            if !isDragOverlayVisible {
                armDropTarget()
            }
        } else if isDragOverlayVisible {
            if hideOverlayTimer == nil {
                scheduleHideDropOverlay()
            }
        } else if isDropTargetActive {
            hideDropOverlay()
        }
    }

    func armDropTarget() {
        guard !isScreenshotInteractionSuspended, !isDragOverlayVisible else { return }
        guard let overlay = prepareDropOverlay() else { return }

        if dragPresentationGate.armDropTarget() {
            overlay.setPresentationVisible(false)
            overlay.orderFront(nil)
            startArmedDropTargetWatchdog()
        }
    }

    func showDropOverlay() {
        cancelScheduledOverlayHide()
        guard !isScreenshotInteractionSuspended else { return }
        guard !isDragOverlayVisible else { return }
        guard let overlay = prepareDropOverlay() else { return }

        guard dragPresentationGate.showOverlay() else { return }
        overlay.setPresentationVisible(true)
        overlay.orderFront(nil)
        stopArmedDropTargetWatchdog()
    }

    private func prepareDropOverlay() -> DropOverlayWindow? {
        guard let overlayFrame = frameBelowStatusItem(width: 300, height: 220) else { return nil }

        hideOverlayTimer?.invalidate()
        if let existing = dropOverlayWindow {
            existing.setFrame(overlayFrame, display: true)
            return existing
        }

        let overlay = DropOverlayWindow(contentRect: overlayFrame)
        overlay.onFilesDropped = { [weak self] urls in
            self?.handleFilesDropped(urls)
            self?.hideDropOverlay()
        }
        overlay.onDragEntered = { [weak self] in
            self?.showDropOverlay()
        }
        overlay.onDragExited = { [weak self] in
            self?.scheduleHideDropOverlay()
        }
        dropOverlayWindow = overlay
        return overlay
    }

    func scheduleHideDropOverlay(after delay: TimeInterval = 0.35) {
        hideOverlayTimer?.invalidate()
        let generation = dragPresentationGate.makeHideToken()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard self?.dragPresentationGate.acceptsHideToken(generation) == true else { return }
                self?.hideOverlayTimer = nil
                self?.hideDropOverlay()
            }
        }
        hideOverlayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hideDropOverlay() {
        cancelScheduledOverlayHide()
        stopArmedDropTargetWatchdog()
        _ = dragPresentationGate.hideOverlay()
        dropOverlayWindow?.setPresentationVisible(false)
        dropOverlayWindow?.orderOut(nil)
    }

    private func startArmedDropTargetWatchdog() {
        guard armedDropTargetWatchdog == nil, !isDragOverlayVisible else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isDropTargetActive, !self.isDragOverlayVisible else {
                    self.stopArmedDropTargetWatchdog()
                    return
                }
                if ArmedDropTargetWatchdogPolicy.shouldHide(
                    isDropTargetActive: self.isDropTargetActive,
                    isPresentationVisible: self.isDragOverlayVisible,
                    hasActiveFileDrag: self.dropOverlayWindow?.hasActiveFileDrag == true,
                    pressedMouseButtons: NSEvent.pressedMouseButtons
                ) {
                    self.hideDropOverlay()
                }
            }
        }
        armedDropTargetWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopArmedDropTargetWatchdog() {
        armedDropTargetWatchdog?.invalidate()
        armedDropTargetWatchdog = nil
    }

    func cancelScheduledOverlayHide() {
        dragPresentationGate.invalidatePendingHide()
        hideOverlayTimer?.invalidate()
        hideOverlayTimer = nil
    }

    func setScreenshotInteractionSuspended(_ suspended: Bool) {
        guard isScreenshotInteractionSuspended != suspended else { return }
        let wasActive = isDropTargetActive
        dragPresentationGate.setSuspended(suspended)
        draggableButton?.setDropEnabled(!suspended)
        if suspended {
            hideOverlayTimer?.invalidate()
            hideOverlayTimer = nil
            stopArmedDropTargetWatchdog()
            if wasActive {
                dropOverlayWindow?.setPresentationVisible(false)
                dropOverlayWindow?.orderOut(nil)
            }
        }
    }

    // MARK: - 悬停窗口

    func showHoverWindow() {
        guard StatusItemHoverPolicy.shouldPresentHover(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else { return }
        if let floatingWindow, floatingWindow.isVisible { return }
        guard !isHoverWindowShowing else { return }

        if hoverWindow == nil {
            createHoverWindow()
        }
        guard let window = hoverWindow,
              let currentFrame = frameBelowStatusItem(width: 420, height: 640) else { return }
        hoverWindowFrame = currentFrame
        isHoverWindowShowing = true

        if localMouseTracker == nil {
            localMouseTracker = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.checkMousePosition()
                return event
            }
        }

        window.alphaValue = 0
        window.setFrame(hoverWindowFrame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        })
    }

    func hideHoverWindow() {
        guard isHoverWindowShowing, let window = hoverWindow else { return }
        isHoverWindowShowing = false

        if let tracker = localMouseTracker {
            NSEvent.removeMonitor(tracker)
            localMouseTracker = nil
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else { return }
                if !self.isHoverWindowShowing {
                    window.orderOut(nil)
                }
            }
        })
    }

    func createHoverWindow() {
        guard let frame = frameBelowStatusItem(width: 420, height: 640) else { return }

        let window = KeyableWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hoverWindowFrame = frame

        window.contentViewController = NSHostingController(rootView: ContentView(viewModel: viewModel))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hasShadow = true

        // 允许接受键盘输入
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false

        // 添加圆角
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 16
            contentView.layer?.masksToBounds = true
        }

        hoverWindow = window
    }

    func showStatusMenu() {
        let menu = NSMenu()

        let screenshotItem = NSMenuItem(title: "截图", action: #selector(captureScreenshot), keyEquivalent: "")
        screenshotItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "截图")
        screenshotItem.target = self
        menu.addItem(screenshotItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 QuickStash", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func captureScreenshot() {
        ScreenshotCoordinator.shared.startCapture()
    }

    @objc func handleClick() {
        // 点击时显示独立窗口
        if floatingWindow == nil {
            createFloatingWindow()
        } else {
            showFloatingWindowWithAnimation()
        }

        // 关闭悬停窗口（如果打开）
        hideHoverWindow()
    }

    func handleFilesDropped(_ urls: [URL]) {
        hideDropOverlay()
        if !isScreenshotInteractionSuspended {
            showHoverWindowForDrop()
        }
        Task {
            await viewModel.importFiles(urls)
        }
    }

    /// 拖入文件后强制显示悬浮窗（忽略 floatingWindow 守卫）
    func showHoverWindowForDrop() {
        // 如果独立窗口已开着，直接激活它即可
        if let fw = floatingWindow, fw.isVisible {
            fw.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if hoverWindow == nil {
            createHoverWindow()
        }

        guard let window = hoverWindow,
              let currentFrame = frameBelowStatusItem(width: 420, height: 640) else { return }

        hoverWindowFrame = currentFrame
        isHoverWindowShowing = true
        if localMouseTracker == nil {
            localMouseTracker = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.checkMousePosition()
                return event
            }
        }

        window.alphaValue = 0
        let originalFrame = hoverWindowFrame
        let scaledFrame = NSRect(
            x: originalFrame.midX - originalFrame.width * 0.9 / 2,
            y: originalFrame.midY - originalFrame.height * 0.9 / 2,
            width: originalFrame.width * 0.9,
            height: originalFrame.height * 0.9
        )

        window.setFrame(scaledFrame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
            window.animator().setFrame(originalFrame, display: true)
        })
    }

    func showFloatingWindowWithAnimation() {
        guard let window = floatingWindow else { return }

        // 设置初始状态
        window.alphaValue = 0
        let originalFrame = window.frame
        let scaledFrame = NSRect(
            x: originalFrame.midX - originalFrame.width * 0.9 / 2,
            y: originalFrame.midY - originalFrame.height * 0.9 / 2,
            width: originalFrame.width * 0.9,
            height: originalFrame.height * 0.9
        )

        window.setFrame(scaledFrame, display: false)
        window.makeKeyAndOrderFront(nil)

        // 缩放和淡入动画
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
            window.animator().setFrame(originalFrame, display: true)
        })
    }

    func createFloatingWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "QuickStash"
        window.contentViewController = NSHostingController(rootView: ContentView(viewModel: viewModel))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("QuickStashWindow")
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 监听窗口关闭
        if let observer = floatingWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        floatingWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.floatingWindow = nil
            }
        }

        floatingWindow = window

        // 显示时带动画
        showFloatingWindowWithAnimation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        ScreenshotCoordinator.shared.shutdown()
        hideOverlayTimer?.invalidate()
        hideOverlayTimer = nil
        stopArmedDropTargetWatchdog()
        dragPresentationGate.setSuspended(true)
        draggableButton?.setDropEnabled(false)
        dropOverlayWindow?.setPresentationVisible(false)
        dropOverlayWindow?.orderOut(nil)
        if let mouseTracker {
            NSEvent.removeMonitor(mouseTracker)
            self.mouseTracker = nil
        }
        if let localDragTracker {
            NSEvent.removeMonitor(localDragTracker)
            self.localDragTracker = nil
        }
        if let localMouseTracker {
            NSEvent.removeMonitor(localMouseTracker)
            self.localMouseTracker = nil
        }
        pointerEventRelay = nil

        terminationTask = Task { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await ScreenshotCoordinator.shared.drainAfterShutdown()
            await ClipboardMonitor.shared.shutdownForTermination()
            await self.viewModel.flushForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = floatingWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func frameBelowStatusItem(width: CGFloat, height: CGFloat) -> NSRect? {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return nil }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let statusFrame = buttonWindow.convertToScreen(buttonFrame)
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        guard let visibleFrame else {
            return NSRect(
                x: statusFrame.midX - width / 2,
                y: statusFrame.minY - height,
                width: width,
                height: height
            )
        }

        let x = min(max(statusFrame.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let y = max(statusFrame.minY - height, visibleFrame.minY)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
