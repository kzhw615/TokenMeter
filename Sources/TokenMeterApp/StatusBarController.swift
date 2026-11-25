#if os(macOS)
import SwiftUI
import AppKit
import Darwin
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

        actions.openPanel = { [weak self] in self?.showPanel() }
        actions.closePanel = { [weak self] in self?.hidePanel() }
        actions.togglePanel = { [weak self] in self?.togglePanel() }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.refresh = { [weak model] in model?.refresh() }
        actions.checkUpdate = { [weak model] in model?.checkForUpdates(force: true) }
        actions.markAllRead = { [weak model] in model?.markAllRead() }
        // 右键菜单「隐藏悬浮坞」：等价于设置里把位置设为「关闭」
        actions.hideDock = { [weak model] in model?.sideDock = "off" }
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
        lastTitleKey = nil
        refreshButton()
    }

    private func configureButton() {
        // 面板尺寸/主题变化时重绘
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.refreshButton()
            }
            .store(in: &cancellables)
        // 玻璃/外观切换：订阅具体字段（objectWillChange 在赋值前触发，读不到新值）
        model.$glassOpacity
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPanelContent() }
            .store(in: &cancellables)
        model.$panelAppearance
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPanelContent() }
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
        model.flame.$frame
            .sink { [weak self] frame in
                self?.refreshIcon(frame: frame)
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

    /// 火苗缩放结果缓存：每帧都 copy + 设 size 会持续分配内存，
    /// 只缓存当前尺寸和素材序列；更换时释放上一组。
    private var flameCache: [Int: NSImage] = [:]
    private var cachedFirstFrame: NSImage?
    private var cachedSize: CGFloat = 0
    /// 上次面板的 x（用于平滑定位，避免数值变化导致面板横移）
    private var lastPanelX: CGFloat?

    /// 最近一次隐藏面板的时间：用于抑制「点图标关闭后又被同一次点击重新打开」的竞态
    private var lastHideAt: Date?
    private var lastGlassStyle: String?
    private static let idleIcon = MenuBarAssets.barIcon
        ?? NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "TokenMeter")
    private static let fallbackFlame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "燃烧中")
    private var lastTitleKey: String?
    /// 「带速率」时标题需要的宽度（pt），用于判断菜单栏放不放得下
    private var lastWideWidth: CGFloat = 0
    /// 火苗用 CALayer 绘制：每帧改 layer.contents 不会触发菜单栏重新度量，
    /// 而 button.image = 每帧重设会整条菜单栏重新合成（实测 30fps 下吃掉 21% 单核）。
    private var flameLayer: CALayer?
    private var flameLayerSize: CGFloat = 0
    private var frameCache: [Int: CGImage] = [:]

    private func refreshIcon(frame: Int) {
        // 诊断：跳过菜单栏火苗刷新，用于确认这部分的开销
        if ProcessInfo.processInfo.environment["TOKENMETER_NO_BARFLAME"] != nil { return }
        guard let button = item.button else { return }
        if ProcessInfo.processInfo.environment["TOKENMETER_OLD_BARFLAME"] != nil {
            refreshIconLegacy(frame: frame, button: button)
            return
        }
        // ── 菜单栏火苗：画在按钮的 CALayer 上 ─────────────────────
        // 设 button.image 会让整条菜单栏重新合成（30fps 实测 20%+ 单核），
        // 改 layer.contents 便宜得多（8%）。两个坑必须处理：
        //   ① 图层位置要等按钮布局完成（bounds 非零）再设，否则零尺寸看不见
        //   ② 状态项重建时 button 会换新对象，图层要重新挂上去
        if model.isBurning {
            let size = model.flamePointSize
            let frames = model.flameFrames(for: size)
            guard !frames.isEmpty else { return }
            ensureFlameLayer(button)
            if flameLayerSize != size {
                flameLayerSize = size
                frameCache.removeAll(keepingCapacity: true)
                button.image = Self.spacerImage(size: size)   // 占位，只换尺寸时重设
            }
            if button.bounds.height > 0, let layer = flameLayer {
                // 靠右贴住文字：状态项给图片的位置比图片本身宽（实测 12pt 图占 22pt 槽），
                // 左对齐会留出 10pt 空白，看起来「火苗离文字很远」。
                // 这里按槽宽把火焰画大一点并贴右侧，间隙≈按钮自身的 2pt 间距。
                let slot = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
                let drawSize = slot.width > 4 ? max(9, min(size, slot.width - 1)) : size
                let x = slot.width > 4 ? slot.maxX - drawSize - 1 : 2
                let want = CGRect(x: x, y: (button.bounds.height - drawSize) / 2,
                                  width: drawSize, height: drawSize)
                if layer.frame != want {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.frame = want
                    CATransaction.commit()
                }
            }
            let index = frame % frames.count
            let cg: CGImage? = frameCache[index] ?? {
                var rect = CGRect(origin: .zero, size: frames[index].size)
                let image = frames[index].cgImage(forProposedRect: &rect, context: nil, hints: nil)
                if let image { frameCache[index] = image }
                return image
            }()
            if let cg { flameLayer?.contents = cg }
            flameLayer?.isHidden = false
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil, index == 0,
               let cell = button.cell {
                let titleRect = cell.titleRect(forBounds: button.bounds)
                let imageRect = cell.imageRect(forBounds: button.bounds)
                FileHandle.standardError.write(Data(String(format: "DBG gap imgMaxX=%.1f titleMinX=%.1f 间隙=%.1fpt flameFrame=%@ size=%.1f\n",
                    imageRect.maxX, titleRect.minX, titleRect.minX - imageRect.maxX,
                    "\(flameLayer?.frame ?? .zero)", size).utf8))
            }
        } else {
            flameLayer?.isHidden = true
            flameLayerSize = 0
            if button.image !== Self.idleIcon { button.image = Self.idleIcon }
        }
    }

    /// 透明占位图：只为了让状态项预留火苗的宽度
    private static func spacerImage(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        img.unlockFocus()
        return img
    }

    private func ensureFlameLayer(_ button: NSStatusBarButton) {
        // 状态项被重建后 button 换了对象：旧图层还挂在旧按钮上，必须重挂
        if let layer = flameLayer, layer.superlayer !== button.layer {
            flameLayer = nil
            flameLayerSize = 0
            frameCache.removeAll(keepingCapacity: true)
        }
        guard flameLayer == nil else { return }
        button.wantsLayer = true
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.isHidden = true
        layer.zPosition = 100
        button.layer?.addSublayer(layer)
        flameLayer = layer
    }

    private func refreshIconLegacy(frame: Int, button: NSStatusBarButton) {
        if model.isBurning {
            let size = model.flamePointSize
            let frames = model.flameFrames(for: size)
            guard let first = frames.first else {
                if button.image !== Self.fallbackFlame { button.image = Self.fallbackFlame }
                return
            }
            let rounded = (size * 2).rounded() / 2
            if first !== cachedFirstFrame || rounded != cachedSize {
                cachedFirstFrame = first
                cachedSize = rounded
                flameCache.removeAll(keepingCapacity: true)
            }
            let index = frame % frames.count
            let image: NSImage
            if let hit = flameCache[index] {
                image = hit
            } else {
                image = (frames[index].copy() as? NSImage) ?? frames[index]
                image.size = NSSize(width: rounded, height: rounded)
                flameCache[index] = image
            }
            if button.image !== image { button.image = image }
        } else if button.image !== Self.idleIcon {
            button.image = Self.idleIcon
        }
    }

    private func refreshButton() {
        guard let button = item.button else { return }
        refreshIcon(frame: model.flame.frame)

        // ── 标题（只在文字/颜色变化时重设）────────────────────────
        // 关键：每帧无条件给 NSStatusItem 设 attributedTitle 会触发菜单栏
        // 重新度量与合成，实测能吃掉 20%+ 的单核 CPU（火焰动画 10fps 时）。
        let title: String
        if model.menuBarStyle == "icon" {
            title = ""
        } else if let s = model.summary, s.counts.total > 0 {
            // menuBarText 内部已经带速率前缀（燃烧中才加），这里不要再加一遍。
            // 菜单栏挤的时候不显示速度，只用用量（宽度能省约 60pt）。
            title = " " + model.menuBarText(s, includeRate: !model.menuBarCrowded)
        } else {
            title = model.scanning ? " …" : " 0"
        }
        let red = model.budgetOver
        // 记录「带速率」时需要的宽度
        if let summary = model.summary {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let wide = " " + model.menuBarText(summary, includeRate: true)
            lastWideWidth = ceil(NSAttributedString(string: wide, attributes: [.font: font]).size().width)
        }
        let titleKey = "\(red)-\(title)"
        guard lastTitleKey != titleKey else { return }
        lastTitleKey = titleKey
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: red ? NSColor.systemRed : NSColor.labelColor,
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
        // ── 自适应宽度：菜单栏拥挤时只显示用量 ────────────────
        // macOS 不会压缩我们的标题（实测 465pt 的标题依然完整显示），挤不下时是直接
        // 把项藏起来，所以「有没有被压缩」测不到。改用可测的几何：我们的项随着其他
        // 项变多会一路左移，当它跑到屏幕左侧 48% 以内就认为很挤了。
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button, let win = button.window, let screen = win.screen,
                  win.frame.minX > 1, win.frame.width > 1 else { return }   // 还没布局好，先不判断
            // 用状态项的【右边界】而不是左边界：变宽时项是往左长的，右边界不变，
            // 判断不会因为自己变宽而反复翻转。
            let notchLeft = screen.auxiliaryTopRightArea.map(\.minX) ?? 0
            let available = max(0, win.frame.maxX - notchLeft)   // 这块区域总共能给我们多宽
            let need = self.lastWideWidth + 8                    // 带速率需要多宽
            // 调试：TOKENMETER_FORCE_RATIO=0.3 可模拟「只剩三成空间」
            let forced = ProcessInfo.processInfo.environment["TOKENMETER_FORCE_RATIO"].flatMap(Double.init)
            let fits = forced.map { $0 * available >= need } ?? (available >= need + 20)
            let fitsLoose = forced.map { $0 * available >= need + 20 } ?? (available >= need + 40)
            switch self.model.menuBarRateMode {
            case "always": self.model.menuBarCrowded = false
            case "never": self.model.menuBarCrowded = true
            default:
                // 迟滞：放不下就收起；要恢复到「明显放得下」才重新显示，避免来回抖
                if self.model.menuBarCrowded ? fitsLoose : !fits {
                    self.model.menuBarCrowded.toggle()
                }
            }
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "DBG itemX=%.0f avail=%.0f need=%.0f crowded=%@ titleLen=%d\n",
                    win.frame.minX, available, need, self.model.menuBarCrowded ? "是" : "否", title.count).utf8))
            }
        }
    }

// MARK: - 面板


    /// 面板窗口外观：深色 + 圆角遮罩（contentView 每次重建后都要重设）
    private func applyPanelChrome(_ panel: NSPanel) {
        switch model.panelAppearance {
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        case "light": panel.appearance = NSAppearance(named: .aqua)
        default: panel.appearance = nil          // 跟随系统
        }
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 24
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true
    }

    private func rebuildPanel() {
        panel?.orderOut(nil)
        let hosting = NSHostingView(rootView:
            PanelView()
                .environmentObject(model)
                .environmentObject(actions)
                .liquidGlass(cornerRadius: 24, tint: model.theme.primary, opacity: model.glassOpacity))
        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // 强制深色：液态玻璃观感需要深色底；浅色模式下材质会发白，失去玻璃感
        p.appearance = NSAppearance(named: .darkAqua)
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
        applyPanelChrome(p)
        panel = p
    }

    /// 玻璃风格 / 外观变化后重建已打开的面板内容，让改动立即生效
    private func refreshPanelContent() {
        guard let panel, panel.contentView != nil else { return }
        if model.panelAppearance != "auto" || true {
            applyPanelChrome(panel)
        }
        panel.contentView = NSHostingView(rootView:
            PanelView()
                .environmentObject(model)
                .environmentObject(actions)
                .liquidGlass(cornerRadius: 24, tint: model.theme.primary, opacity: model.glassOpacity))
        applyPanelChrome(panel)
    }

    private func dbgLog(_ m: String) {
        guard ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("DBG panel \(m)\n".utf8))
    }

    func showPanel() {
        dbgLog("show")
        guard let panel, let button = item.button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - Self.panelSize.width / 2
        let y = buttonRect.minY - Self.panelSize.height - 6
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 8), vf.maxX - Self.panelSize.width - 8)
        }
        // 状态栏文字宽度会随数值长短变化（如 1.76亿 ↔ 1028.2万，切换含/不含缓存时尤其明显），
        // 而面板是按图标中心定位的，于是每次数值变化面板都会整体横移，
        // 看起来就像「内容左右留白不同」。这里做位置平滑：
        // 新位置与上次相差不大（< 40pt）就沿用上次的，只有明显移动时才重新定位。
        // 跨启动也保持稳定：把上次的 x 存起来，本次计算值与之相差不大就直接沿用。
        if let stored = UserDefaults.standard.object(forKey: "panelX") as? Double, stored != 0 {
            lastPanelX = CGFloat(stored)
        }
        if let last = lastPanelX, abs(last - x) < 200 {
            x = last
        }
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 8), vf.maxX - Self.panelSize.width - 8)
        }
        lastPanelX = x
        UserDefaults.standard.set(Double(x), forKey: "panelX")
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
            FileHandle.standardError.write(Data("DBG panel x=\(Int(x)) itemW=\(Int(buttonRect.width))\n".utf8))
        }
        if panel.contentView == nil {
            panel.contentView = NSHostingView(rootView:
                PanelView()
                    .environmentObject(model)
                    .environmentObject(actions)
                    .liquidGlass(cornerRadius: 24, tint: model.theme.primary, opacity: model.glassOpacity))
            applyPanelChrome(panel)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, 8)))
        // 激活本应用后键盘事件才会送到面板（Esc / ⌘R）
        NSApp.activate(ignoringOtherApps: true)
        // 先以透明显示：面板每次打开都会重建 SwiftUI 树（为了省 CPU），
        // 滚动位置必须等布局完成才能设置，直接显示会先闪一下顶部再跳过去。
        let needsRestore = (UserDefaults.standard.object(forKey: "panelScrollY") as? Double ?? 0) > 20
        panel.alphaValue = needsRestore ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        if needsRestore {
            DispatchQueue.main.async { [weak panel] in
                guard let panel else { return }
                panel.contentView?.layoutSubtreeIfNeeded()
                Self.restoreScroll(panel)
                panel.alphaValue = 1
            }
        }
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

    /// 把面板里的 NSScrollView 恢复到上次的位置（重建视图树后调用）
    static func restoreScroll(_ panel: NSPanel) {
        guard let saved = UserDefaults.standard.object(forKey: "panelScrollY") as? Double, saved > 20,
              let sv = findScrollView(in: panel.contentView) else { return }
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
        guard maxY > 20 else { return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(saved), maxY)))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    func hidePanel() {
        dbgLog("hide")
        lastHideAt = Date()
        panel?.orderOut(nil)
        model.panelOpen = false
        removeOutsideMonitor()
        removeKeyMonitor()
        // 释放 SwiftUI 视图树：隐藏状态下若继续跟着 @Published 重算，
        // 会白白吃掉十几% 的单核 CPU（Charts/表格布局都不便宜）。
        panel?.contentView = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
            return
        }
        // 全局点击监听在 mouseDown 就把面板收掉了，按钮的 mouseUp 还会再调一次；
        // 若不拦住，用户看到的会是「点一下关掉又立刻打开」。0.4 秒内视为同一次点击。
        if let t = lastHideAt, Date().timeIntervalSince(t) < 0.4 { return }
        showPanel()
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
                        .insetBy(dx: -12, dy: -12)     // 点图标文字边缘也算，避免误判为「点外面」
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
