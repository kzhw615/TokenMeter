#if os(macOS)
import SwiftUI
import AppKit
import Combine
import TokenMeterCore

/// 可成为 key window 的无边框面板：非激活面板默认收不到键盘事件，重写后才能响应 ⌘R / Esc
final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onRefresh: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// ⌘R 刷新 / ⌘Q 退出
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "r" { onRefresh?(); return }
        }
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
}

/// 菜单栏控制器：NSStatusItem 提供「左键打开面板 / 右键功能菜单」
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let actions: AppActions
    private var item: NSStatusItem
    private var panel: NSPanel?
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var visibilityTimer: Timer?
    private var island: IslandController?
    private var resignObserver: NSObjectProtocol?
    private var settingsObservers: [NSObjectProtocol] = []

    private static let panelSize = NSSize(width: 430, height: 560)

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureItem()
        startVisibilityWatchdog()

        configureButton()
        rebuildPanel()
        island = IslandController(model: model, actions: actions, anchor: { [weak self] in
            self?.statusItemFrame() ?? .zero
        })
        island?.setEnabled(model.showIsland)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, let island = self.island else { return }
                island.setEnabled(self.model.showIsland)
                island.reposition()
            }
            .store(in: &cancellables)

        actions.openPanel = { [weak self] in self?.showPanel() }
        actions.closePanel = { [weak self] in self?.hidePanel() }
        actions.togglePanel = { [weak self] in self?.togglePanel() }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.refresh = { [weak model] in model?.refresh() }
        actions.checkUpdate = { [weak model] in model?.checkForUpdates(force: true) }
        actions.markAllRead = { [weak model] in model?.markAllRead() }
        actions.quit = { [weak self] in self?.quitApp() }
    }

    // MARK: - 状态栏按钮

    /// 状态项基础配置（重建时复用）
    private func configureItem() {
        // 持久化位置/可见性，避免系统在菜单栏拥挤时把图标隐藏后不再恢复
        item.autosaveName = "TokenMeterStatusItem"
        item.isVisible = true
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeft
    }

    /// 看门狗：菜单栏拥挤时系统可能把状态项挪出可见区域甚至隐藏，
    /// 此时 App 仍在运行（悬浮坞还在），但用户看不到图标 —— 定期检查并重建。
    private func startVisibilityWatchdog() {
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkItemVisibility() }
        }
        visibilityTimer.map { RunLoop.main.add($0, forMode: .common) }
    }

    /// 状态项在屏幕坐标系里的位置（灵动岛据此贴靠）
    func statusItemFrame() -> NSRect {
        guard let button = item.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func checkItemVisibility() {
        guard item.isVisible else {
            // 被系统标记为隐藏：重新声明可见
            item.isVisible = true
            refreshButton()
            return
        }
        guard let button = item.button else { rebuildItem(); return }
        guard let window = button.window, window.isVisible, window.frame.width > 1 else {
            rebuildItem()
            return
        }
        island?.reposition()
        // 落在屏幕外或刘海区域 ⇒ 实际不可见
        if let screen = window.screen ?? NSScreen.main {
            let frame = window.frame
            let notch = screen.auxiliaryTopLeftArea ?? .zero
            let right = screen.auxiliaryTopRightArea ?? .zero
            let inNotch = !notch.isEmpty && !right.isEmpty
                && frame.minX < right.minX && frame.maxX > notch.maxX
            let offscreen = frame.minX < screen.frame.minX || frame.maxX > screen.frame.maxX
            if inNotch || offscreen {
                if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("DBG watchdog rebuild: inNotch=\(inNotch) offscreen=\(offscreen) frame=\(frame)\n".utf8))
                }
                rebuildItem()
            }
        }
    }

    /// 重建状态栏项（先移除旧的，避免留下不可见的僵尸项）
    private func rebuildItem() {
        NSStatusBar.system.removeStatusItem(item)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureItem()
        lastIconKey = nil
        lastTitleKey = nil
        refreshButton()
    }

    private func configureButton() {
        // 面板尺寸/主题变化时重绘
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
            .store(in: &cancellables)
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let btn = self.item.button else { return }
                let rect = btn.window.map { $0.convertToScreen(btn.convert(btn.bounds, to: nil)) } ?? .zero
                let scr = btn.window?.screen ?? NSScreen.main
                let notchL = scr?.auxiliaryTopLeftArea ?? .zero
                let notchR = scr?.auxiliaryTopRightArea ?? .zero
                let dump = "DBG bar visible=\(self.item.isVisible) frame=\(rect) img=\(btn.image.map { "\($0.size)" } ?? "nil") title=\"\(btn.attributedTitle.string)\"\n"
                let notch = "DBG notch screen=\(scr?.frame ?? .zero) left=\(notchL) right=\(notchR) safeTop=\(scr?.safeAreaInsets.top ?? 0)\n"
                FileHandle.standardError.write(Data((dump + notch).utf8))
            }
        }
        // 火苗帧由独立 ticker 驱动：只在帧变化时重绘状态栏按钮（不再轮询）
        model.flame.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.refreshButton() }
            }
            .store(in: &cancellables)
        refreshButton()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = actions.buildMenu(model: model)
        // 临时挂到 statusItem 上再模拟点击：由系统负责锚定到图标下方（popUp(at:in:) 会飘到屏幕中间）
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// 同步按钮图标与文字
    /// 上次渲染结果，用于跳过无变化的重绘（状态栏文字排版较贵）

    /// 火苗缩放结果缓存：每帧都 copy + 设 size 会持续分配内存，
    /// 按「档位 + 帧号 + 0.5pt 尺寸」缓存后，同一尺寸只生成一次。
    private var flameCache: [String: NSImage] = [:]

    private func scaledFlame(_ base: NSImage, tier: AppModel.FlameTier, frame: Int, size: CGFloat) -> NSImage? {
        let rounded = (size * 2).rounded() / 2
        let key = "\(tier)-\(frame)-\(rounded)"
        if let hit = flameCache[key] { return hit }
        if flameCache.count > 240 { flameCache.removeAll(keepingCapacity: true) }
        let img = (base.copy() as? NSImage) ?? base
        img.size = NSSize(width: rounded, height: rounded)
        flameCache[key] = img
        return img
    }

    /// 上一次真正写入菜单栏的图标状态与标题，用于避免每帧重复设置
    private var lastIconKey: String?
    private var lastTitleKey: String?

    private func refreshButton() {
        guard let button = item.button else { return }

        // ── 图标（火焰动画）──────────────────────────────────────
        // 菜单栏图标按 6fps 更新（每 2 帧取一帧）：NSStatusItem 每次换图都会触发
        // 菜单栏重新合成，实测 10fps → 6fps 省约 5% 单核 CPU，而 20pt 的小图标
        // 肉眼分辨不出差别；坞内仍按完整帧率播放。
        let rawFrame = model.flame.frame
        let menuFrame = (rawFrame / 2) * 2
        let frameIdx = model.isBurning ? menuFrame % max(1, model.currentFlameFrames.count) : -1
        let size = model.isBurning ? model.flamePointSize : 20
        let iconKey = "\(model.isBurning)-\(frameIdx)-\(size)"
        if lastIconKey != iconKey {
            lastIconKey = iconKey
            if model.isBurning {
                let frames = model.currentFlameFrames
                if !frames.isEmpty {
                    let idx = menuFrame % frames.count
                    button.image = scaledFlame(frames[idx], tier: model.flameTier, frame: idx, size: size)
                        ?? frames[idx]
                } else {
                    button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "燃烧中")
                }
            } else {
                button.image = MenuBarAssets.barIcon
                    ?? NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "TokenMeter")
            }
        }

        // ── 标题（只在文字/颜色变化时重设）────────────────────────
        // 关键：每帧无条件给 NSStatusItem 设 attributedTitle 会触发菜单栏
        // 重新度量与合成，实测能吃掉 20%+ 的单核 CPU（火焰动画 10fps 时）。
        let title: String
        if model.showIsland {
            // 灵动岛已经展示用量/费用，菜单栏只留火苗
            title = ""
        } else if model.menuBarStyle == "icon" {
            title = ""
        } else if let s = model.summary, s.counts.total > 0 {
            title = " " + model.menuBarText(s)
        } else {
            title = model.scanning ? " …" : " 0"
        }
        let red = model.budgetOver
        let titleKey = "\(red)-\(title)"
        guard lastTitleKey != titleKey else { return }
        lastTitleKey = titleKey
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: red ? NSColor.systemRed : NSColor.labelColor,
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
    }

// MARK: - 面板

    private func rebuildPanel() {
        panel?.orderOut(nil)
        let hosting = NSHostingView(rootView:
            PanelView()
                .environmentObject(model)
                .environmentObject(actions)
                .glassBackground(cornerRadius: 20, tint: model.theme.primary))
        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentView = hosting
        p.isReleasedWhenClosed = false
        p.onEscape = { [weak self] in self?.hidePanel() }
        p.onRefresh = { [weak self] in self?.model.refresh() }
        panel = p
    }

    func showPanel() {
        island?.setHidden(true)
        guard let panel, let button = item.button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - Self.panelSize.width / 2
        let y = buttonRect.minY - Self.panelSize.height - 6
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 8), vf.maxX - Self.panelSize.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, 8)))
        // 激活本应用后键盘事件才会送到面板（Esc / ⌘R）
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.panelOpen = true
        installOutsideMonitor()
        installKeyMonitor()
        // 切到别的应用时自动收起面板
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.hidePanel() }
                }
        }
    }

    func hidePanel() {
        island?.setHidden(false)
        panel?.orderOut(nil)
        model.panelOpen = false
        removeOutsideMonitor()
        removeKeyMonitor()
    }

    func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                if panel.frame.contains(mouse) { return }
                // 点在菜单栏图标上时交给按钮自己处理（避免「关掉又立刻打开」）
                if let btn = self.item.button, let win = btn.window {
                    let rect = win.convertToScreen(btn.convert(btn.bounds, to: nil))
                    if rect.contains(mouse) { return }
                }
                self.hidePanel()
            }
        }
    }

    private func removeOutsideMonitor() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    /// 面板内的键盘：Esc 关闭、⌘R 刷新、⌘, 设置
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if event.keyCode == 53 {              // Esc
                self.hidePanel()
                return nil
            }
            if event.modifierFlags.contains(.command),
               let ch = event.charactersIgnoringModifiers?.lowercased() {
                switch ch {
                case "r": self.model.refresh(); return nil
                case ",": self.openSettings(); return nil
                case "q": self.quitApp(); return nil
                default: break
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: - 设置窗口

    private func openSettings() {
        hidePanel()
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show(model: model)
    }

    // MARK: - 退出

    /// 单实例保护：若已有别的 TokenMeter 在跑，本实例退出，避免出现两个菜单栏图标
    static func terminateIfDuplicate() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.tokenmeter.menubar")
            .filter { $0.processIdentifier != me }
        if let other = others.first {
            other.activate(options: [])
            return true
        }
        return false
    }

    private func quitApp() {
        hidePanel()
        settingsWindow?.close()
        NSApp.terminate(nil)
    }
}
#endif
