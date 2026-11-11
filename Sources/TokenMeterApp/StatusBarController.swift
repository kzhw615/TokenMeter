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
    private let item: NSStatusItem
    private var panel: NSPanel?
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var settingsObservers: [NSObjectProtocol] = []

    private static let panelSize = NSSize(width: 430, height: 560)

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // 持久化位置/可见性，避免系统在菜单栏拥挤时把图标隐藏后不再恢复
        item.autosaveName = "TokenMeterStatusItem"
        item.isVisible = true

        configureButton()
        rebuildPanel()

        actions.openPanel = { [weak self] in self?.showPanel() }
        actions.closePanel = { [weak self] in self?.hidePanel() }
        actions.togglePanel = { [weak self] in self?.togglePanel() }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.refresh = { [weak model] in model?.refresh() }
        actions.checkUpdate = { [weak model] in model?.checkForUpdates(force: true) }
        actions.quit = { [weak self] in self?.quitApp() }
    }

    // MARK: - 状态栏按钮

    private func configureButton() {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeft
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
    private var lastRendered: (frame: Int, size: CGFloat, text: String, red: Bool)?

    private func refreshButton() {
        guard let button = item.button else { return }

        // 先算好本次要渲染的内容，与上次一致则直接返回
        let frameIdx = model.isBurning ? model.flame.frame % max(1, model.currentFlameFrames.count) : -1
        let size = model.isBurning ? model.flamePointSize : 20
        let displayText: String
        if model.menuBarStyle == "icon" {
            displayText = ""
        } else if let s = model.summary, s.counts.total > 0 {
            displayText = " " + model.menuBarText(s)
        } else {
            displayText = model.scanning ? " …" : " 0"
        }
        let red = model.budgetOver
        if let last = lastRendered, last.frame == frameIdx, last.size == size,
           last.text == displayText, last.red == red {
            return
        }
        lastRendered = (frameIdx, size, displayText, red)

        if model.isBurning {
            let frames = model.currentFlameFrames
            if !frames.isEmpty {
                let size = model.flamePointSize
                let base = frames[model.flame.frame % frames.count]
                let img = (base.copy() as? NSImage) ?? base
                img.size = NSSize(width: size, height: size)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "燃烧中")
            }
        } else {
            button.image = MenuBarAssets.barIcon
                ?? NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "TokenMeter")
        }

        if model.menuBarStyle == "icon" {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        guard let s = model.summary, s.counts.total > 0 else {
            button.attributedTitle = NSAttributedString(string: model.scanning ? " …" : " 0")
            return
        }
        let text = " " + model.menuBarText(s)
        let color: NSColor = model.budgetOver ? .systemRed : .labelColor
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
    }

// MARK: - 面板

    private func rebuildPanel() {
        panel?.orderOut(nil)
        let hosting = NSHostingView(rootView:
            PanelView()
                .environmentObject(model)
                .environmentObject(actions)
                .background(.regularMaterial))
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
