#if os(macOS)
import SwiftUI
import AppKit
import Combine
import TokenMeterCore

/// 可成为 key window 的无边框面板：非激活面板默认收不到键盘事件，重写后才能响应 ⌘R / Esc
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    private var flameTimer: Timer?
    private var outsideMonitor: Any?
    private var settingsObservers: [NSObjectProtocol] = []

    private static let panelSize = NSSize(width: 430, height: 560)

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        rebuildPanel()
        startFlameTimer()

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
        guard let button = item.button else { return }
        let menu = actions.buildMenu(model: model)
        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    /// 同步按钮图标与文字
    private func refreshButton() {
        guard let button = item.button else { return }
        if model.isBurning {
            let frames = model.currentFlameFrames
            if !frames.isEmpty {
                let size = model.flamePointSize
                let img = frames[model.flame.frame % frames.count]
                img.size = NSSize(width: size, height: size)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "燃烧中")
            }
        } else {
            button.image = MenuBarLabel.barIcon
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

    private func startFlameTimer() {
        flameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.model.isBurning else { return }
                self.refreshButton()
            }
        }
        // 火苗帧推进由 AppModel 内部计时器负责，这里只需重绘按钮
        flameTimer.map { RunLoop.main.add($0, forMode: .common) }
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
        panel.makeKeyAndOrderFront(nil)
        model.panelOpen = true
        installOutsideMonitor()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        model.panelOpen = false
        removeOutsideMonitor()
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

    // MARK: - 设置窗口

    private func openSettings() {
        hidePanel()
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show(model: model)
    }

    // MARK: - 退出

    private func quitApp() {
        hidePanel()
        settingsWindow?.close()
        NSApp.terminate(nil)
    }
}
#endif
