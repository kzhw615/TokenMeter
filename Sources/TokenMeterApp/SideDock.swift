#if os(macOS)
import Combine
import SwiftUI
import AppKit
import TokenMeterCore

/// 舱体形状：fuse 0→1 单路径参数化形变——
/// 0 = 完整圆角矩形浮块（上下留 wing 空间）；1 = 贴边喇叭口融合（凹曲线收尖于屏边）
/// 外侧角弧与喇叭口凹弧共用一组三次贝塞尔控制点插值，全程连续无叠影
struct BarFlareShape: Shape {
    let side: String
    var fuse: CGFloat
    var ix: CGFloat = 8       // 非贴边侧内缩（可见宽度 = w - ix）
    var barInsetY: CGFloat = 28  // 顶部内缩
    var bottomInset: CGFloat = 28  // 底部内缩（有 harness 行时收窄）
    var flare: CGFloat = 5    // 喇叭口水平外扩（凹弧大小）
    var rise: CGFloat = 7     // 凹弧沿屏边爬升高度
    static let defaultRadius: CGFloat = 26
    var radius: CGFloat = Self.defaultRadius
    /// 外侧（贴屏幕）喇叭口的半径：比内侧圆角小，避免视觉上比另一侧更重
    var flareRadius: CGFloat = 20

    var animatableData: CGFloat {
        get { fuse }
        set { fuse = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = radius
        let oy = barInsetY           // 舱体顶
        let ob = h - bottomInset     // 舱体底
        let ixL = side == "right" ? ix : 0     // 内侧边 x
        let ixR = side == "right" ? w : w - ix
        // fuse 0→1 的形变：外侧角和内侧角用同一半径，只在「凸/凹」之间插值
        //   f=0 外凸圆角（浮块）   f=1 内凹喇叭口（融入屏边）
        // 端点沿屏边移动 ±r，控制点移动 ±0.45r，全程切线保持水平/垂直，不会出现拐角或越界裁切
        let d = (1 - 2 * fuse)               // 1 → -1
        // 外侧半径随 fuse 插值：脱边(fuse=0)时与内侧同半径 → 四角一致；
        // 贴边(fuse=1)时用较小的喇叭口半径，避免视觉上比左侧更重
        let fr = radius + (flareRadius - radius) * fuse
        let k = 0.5523 * fr * d              // 0.5523 = 三次贝塞尔拟合圆的标准系数
        var p = Path()

        if side == "right" {
            p.move(to: CGPoint(x: ixL + r, y: oy))
            p.addLine(to: CGPoint(x: w - fr, y: oy))
            // 右上角
            p.addCurve(to: CGPoint(x: w, y: oy + fr * d),
                       control1: CGPoint(x: w - fr + 0.5523 * fr, y: oy),
                       control2: CGPoint(x: w, y: oy + k))
            // 右下角
            p.addLine(to: CGPoint(x: w, y: ob - fr * d))
            p.addCurve(to: CGPoint(x: w - fr, y: ob),
                       control1: CGPoint(x: w, y: ob - k),
                       control2: CGPoint(x: w - fr + 0.5523 * fr, y: ob))
            p.addLine(to: CGPoint(x: ixL + r, y: ob))
            p.addArc(center: CGPoint(x: ixL + r, y: ob - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: ixL, y: oy + r))
            p.addArc(center: CGPoint(x: ixL + r, y: oy + r), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: ixR - r, y: oy))
            p.addLine(to: CGPoint(x: fr, y: oy))
            p.addCurve(to: CGPoint(x: 0, y: oy + fr * d),
                       control1: CGPoint(x: 0.5523 * fr, y: oy),
                       control2: CGPoint(x: 0, y: oy + 0.5523 * r * d))
            p.addLine(to: CGPoint(x: 0, y: ob - fr * d))
            p.addCurve(to: CGPoint(x: r, y: ob),
                       control1: CGPoint(x: 0, y: ob - 0.5523 * r * d),
                       control2: CGPoint(x: 0.5523 * fr, y: ob))
            p.addLine(to: CGPoint(x: ixR - r, y: ob))
            p.addArc(center: CGPoint(x: ixR - r, y: ob - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: ixR, y: oy + r))
            p.addArc(center: CGPoint(x: ixR - r, y: oy + r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
            p.closeSubpath()
        }
        return p
    }
}

/// 坞的毛玻璃背景：AppKit 视图 + 层圆角裁切。
/// 为什么不用 SwiftUI 的 material / glassEffect：这类「系统效果图层」在上屏合成时
/// 不理会 SwiftUI 的 clipShape / in: 参数，会铺满整个窗口（表现为直角方块）。
/// NSVisualEffectView 是自己的视图，layer.masksToBounds + cornerRadius 一定能裁住。
final class DockBackdropView: NSView {
    private let blur = NSVisualEffectView()
    var style: String = "glass"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.cornerRadius = 30
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.masksToBounds = true
        blur.layer?.cornerCurve = .continuous
        addSubview(blur)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 铺满整个窗口，圆角由容器层裁切（窗口即胶囊，不留 4pt 边）
        blur.frame = bounds
        blur.layer?.cornerRadius = 30
    }
}

/// 悬浮坞面板：右键菜单交给 SwiftUI 的 .contextMenu，
/// 这样才能区分「坞空白处」和「某个工具行」，各自弹不同的菜单。
final class DockPanel: NSPanel {}

/// 侧边悬浮坞：单窗口。拖动=独立圆角浮块；松手=滑向较近屏边并 cross-fade 成贴边融合形态；
/// 位置/侧别记忆；双击回位；单击弹面板。四角完全透明（无投影 haze）
@MainActor
final class SideDockController: ObservableObject {
    static let barWidth: CGFloat = 64
    static let barBlockHeight: CGFloat = 168   // 舱体块恒定（已知安全组合）；可见舱体由形状内缩参数控制
    var rowCount: Int = 0
    // 必须 ≥ 喇叭口半径（26），否则下喇叭口会被窗口底边裁掉（右下角缺一块）
    var bottomInset: CGFloat { max(28, BarFlareShape.defaultRadius + 2) }
    var dockHeight: CGFloat { max(Self.barBlockHeight, 28 + 112 + (rowCount > 0 ? 10 + CGFloat(rowCount) * 34 : 0) + bottomInset) }

    @Published var fuse: CGFloat = 1     // 0 = 浮块圆角矩形，1 = 贴边融合（拖动/回弹时渐变）
    @Published var side: String = "right"

    private var panel: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var mouseUpLocal: Any?
    private var mouseUpGlobal: Any?
    private var snapping = false

    /// useSaved=true 仅首启：沿用上次吸附的侧别；设置切换走 false：显式意图优先
    func apply(mode: String, model: AppModel, useSaved: Bool = false) {
        teardown()
        guard mode == "left" || mode == "right" else { return }
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        side = useSaved ? (UserDefaults.standard.string(forKey: "dockSide") ?? mode) : mode
        rowCount = model.visibleDockSources.count
        fuse = 1

        let panel = DockPanel(
            contentRect: NSRect(origin: originFor(side: side, vf: vf, saved: useSaved), size: NSSize(width: Self.barWidth, height: dockHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        // 黑色档配白字（深色外观）；玻璃档是浅色底，用浅色外观让材质与文字都跟着变
        panel.appearance = NSAppearance(named: model.dockStyle == "glass" ? .aqua : .darkAqua)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false   // 改由视图内的 DragGesture 显式移动
        let hosting = NSHostingView(rootView:
            SideDockView(controller: self).environmentObject(model))
        if model.dockStyle == "glass" {
            let backdrop = DockBackdropView(frame: NSRect(x: 0, y: 0,
                                                          width: Self.barWidth, height: dockHeight))
            hosting.frame = backdrop.bounds
            hosting.autoresizingMask = [.width, .height]
            backdrop.addSubview(hosting)
            panel.contentView = backdrop
        } else {
            panel.contentView = hosting
        }
        panel.orderFrontRegardless()
        self.panel = panel

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.snapping, self.fuse == 1 else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        self.fuse = 0      // 脱边：融合形态淡出为圆角浮块
                    }
                }
            }

        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.fuse == 0, !self.snapping else { return }
                self.snap()
            }
        }
        mouseUpLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { e in
            handler(e)
            return e
        } as Any?
        mouseUpGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp], handler: handler) as Any?

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self, weak model] _ in
                Task { @MainActor [weak self] in
                    guard let self, let model else { return }
                    self.apply(mode: model.sideDock, model: model, useSaved: true)   // 保留吸附侧别记忆
                }
            }
    }

    func teardown() {
        for obs in [screenObserver, moveObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(obs)
        }
        screenObserver = nil
        moveObserver = nil
        if let m = mouseUpLocal { NSEvent.removeMonitor(m); mouseUpLocal = nil }
        if let m = mouseUpGlobal { NSEvent.removeMonitor(m); mouseUpGlobal = nil }
        panel?.orderOut(nil)
        panel = nil
    }

    /// 60fps 手动插值滑动（borderless nonactivating 面板上 NSAnimationContext/animator 不生效）
    private static func slidePanel(_ panel: NSPanel, to target: NSPoint, duration: TimeInterval, completion: @escaping () -> Void) {
        let from = panel.frame.origin
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { t in
            let k = min(1, Date().timeIntervalSince(start) / duration)
            let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2   // easeInOutQuad
            panel.setFrameOrigin(NSPoint(x: from.x + (target.x - from.x) * e,
                                         y: from.y + (target.y - from.y) * e))
            if k >= 1 {
                t.invalidate()
                completion()
            }
        }
    }

    /// 松手：按中心距离吸附到较近屏边；水平滑动 + fuse 形变融合
    /// 面板所在屏幕（多显示器时 NSScreen.main 可能是主屏，不能用来判断吸附目标）
    private func screen(for panel: NSPanel) -> NSScreen? {
        panel.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// 供视图内的显式拖拽手势使用
    var dragPanel: NSPanel? { panel }

    func beginUserDrag() {
        guard fuse == 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { fuse = 0 }
    }

    func endUserDrag() {
        snap()
    }

    func snap() {
        guard let panel, let screen = screen(for: panel) else { return }
        snapping = true
        let vf = screen.visibleFrame
        let newSide = panel.frame.midX < vf.midX ? "left" : "right"
        let targetX = newSide == "left" ? vf.minX : vf.maxX - Self.barWidth
        let targetY = min(max(panel.frame.origin.y, vf.minY), vf.maxY - dockHeight)
        let target = NSPoint(x: targetX, y: targetY)
        Self.slidePanel(panel, to: target, duration: 0.26) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapping = false
                self.side = newSide
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.fuse = 1      // 圆角浮块形变为贴边融合形态
                }
                self.save(side: newSide, originY: targetY)
            }
        }
    }

    func resetPosition(mode: String) {
        guard let panel, let screen = screen(for: panel) else { return }
        let vf = screen.visibleFrame
        panel.setFrameOrigin(originFor(side: mode, vf: vf, saved: false))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.side = mode
            self.fuse = 1
        }
        UserDefaults.standard.removeObject(forKey: "dockSide")
        UserDefaults.standard.removeObject(forKey: "dockY")
    }

    private func originFor(side: String, vf: NSRect, saved: Bool) -> NSPoint {
        let x = side == "left" ? vf.minX : vf.maxX - Self.barWidth
        var y = vf.midY - dockHeight / 2
        if saved, let sy = UserDefaults.standard.object(forKey: "dockY") as? Double {
            y = min(max(sy, vf.minY), vf.maxY - dockHeight)
        }
        return NSPoint(x: x, y: y)
    }

    private func save(side: String, originY: Double) {
        UserDefaults.standard.set(side, forKey: "dockSide")
        UserDefaults.standard.set(originY, forKey: "dockY")
    }

    func showDetail(model: AppModel) {
        if detail == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            win.title = "TokenMeter"
            win.contentView = NSHostingView(rootView:
                PanelView()
                    .environmentObject(model)
                    .environmentObject(AppActions.shared)
                    .background(.regularMaterial))
            win.isReleasedWhenClosed = false
            detail = win
        }
        detail?.center()
        detail?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 呼吸脉冲点：表达"AI 正在跑但暂无 token 落盘"
/// 运行中的橙色脉冲点。
/// 用 Core Animation 而不是 SwiftUI 的 repeatForever：后者会让 SwiftUI 以 60fps
/// 持续重算这一小块（实测在有任务运行时白吃掉 10%+ 单核），CA 的动画在渲染进程跑，主线程零成本。
/// 逐帧图片视图：订阅 FlameTicker，直接设置 NSImageView.image。
/// 走 Combine 而不是 SwiftUI 状态，避免每帧触发布局/重绘。
/// 承载火苗图层的视图：在 layout() 里同步图层尺寸。
/// 之前只在 observe() 里设 layer.frame，那时 bounds 还是 0，图层永远是 0×0 → 看不见。
final class FlameLayerView: NSView {
    var flameLayer: CALayer?
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flameLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct FrameSequenceView: NSViewRepresentable {
    let frames: [NSImage]
    let ticker: FlameTicker
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        // 用 CALayer 贴图而不是 NSImageView.image：30fps 下每次设 image 都要
        // 重新走视图绘制（实测坞里火苗单独就吃 5% 单核），改 layer.contents 便宜得多。
        let v = FlameLayerView(frame: .zero)
        v.wantsLayer = true
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        v.layer?.addSublayer(layer)
        v.flameLayer = layer
        context.coordinator.flameLayer = layer
        context.coordinator.observe(v, frames: frames, ticker: ticker)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.observe(v, frames: frames, ticker: ticker)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var cancellable: AnyCancellable?
        private weak var view: NSView?
        var flameLayer: CALayer?
        private var imageCache: [Int: CGImage] = [:]
        private var cacheKey = 0
        private var lastFrame = -1
        /// 当前档位对应的帧序列。必须随档位更新：
        /// 之前闭包捕获的是首次传入的 frames，速率涨到爆燃档后坞里还用着旧的平淡帧，
        /// 看上去就像「状态栏烧得旺、坞里不旺」。
        private var frames: [NSImage] = []

        func observe(_ v: NSView, frames: [NSImage], ticker: FlameTicker) {
            view = v
            if self.frames.count != frames.count { imageCache.removeAll(keepingCapacity: true) }
            self.frames = frames
            v.needsLayout = true
            // 档位切换会导致帧数变化，重置帧号避免越界/跳帧
            if lastFrame >= frames.count { lastFrame = -1 }
            if cancellable == nil {
                cancellable = ticker.$frame.sink { [weak self] f in
                    MainActor.assumeIsolated { self?.show(frame: f) }
                }
            }
            show(frame: ticker.frame)
        }
        /// 把第 frame 帧贴到 layer 上（CGImage 缓存，避免每帧转换）
        private func show(frame: Int) {
            guard let layer = flameLayer, !frames.isEmpty else { return }
            let idx = frame % frames.count
            guard idx != lastFrame else { return }
            lastFrame = idx
            let cg: CGImage? = imageCache[idx] ?? {
                let img = frames[idx]
                var rect = CGRect(origin: .zero, size: img.size)
                let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                if let cg { imageCache[idx] = cg }
                return cg
            }()
            guard let cg else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = cg
            CATransaction.commit()
        }
    }
}

struct PulseDot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.wantsLayer = true
        guard let layer = view.layer else { return view }
        layer.backgroundColor = NSColor.systemOrange.cgColor
        layer.cornerRadius = 3.5
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.30
        anim.duration = 0.7
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "pulse")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// NSView 没有固有尺寸，不声明的话会被 SwiftUI 撑满整行（实测被拉成竖条）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 7, height: 7)
    }
}

struct SideDockView: View {
    @ObservedObject var controller: SideDockController
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var todaySummary: Summary? { model.summariesByRange[.today] }
    private var tokensText: String {
        guard let s = todaySummary else { return "—" }   // 数据未就绪时不留 0
        let t = model.includeCache ? s.counts.total : s.counts.input + s.counts.output
        return Fmt.tokens(t)
    }
    private var costText: String {
        guard let s = todaySummary else { return " " }
        return Fmt.cost(s.cost)
    }
    /// 拖拽起始时的「屏幕坐标鼠标位置」与「窗口原点」。
    /// 不能用 SwiftUI 的 translation：窗口自身在被移动，局部坐标系随之变化，
    /// 会形成反馈回路（实测表现为位移减半 + 来回抖动）。
    @State private var dragStartMouse: NSPoint?
    @State private var dragStartOrigin: NSPoint?

    /// 显式拖拽：SwiftUI 的点击手势会让 isMovableByWindowBackground 失效，
    /// 因此自己按「鼠标屏幕位移」移动窗口（3pt 阈值，单击/双击不受影响）
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                guard let panel = controller.dragPanel else { return }
                let mouse = NSEvent.mouseLocation          // 屏幕绝对坐标，不受窗口移动影响
                if dragStartMouse == nil {
                    dragStartMouse = mouse
                    dragStartOrigin = panel.frame.origin
                    controller.beginUserDrag()
                }
                guard let m0 = dragStartMouse, let o0 = dragStartOrigin else { return }
                panel.setFrameOrigin(NSPoint(x: o0.x + (mouse.x - m0.x),
                                             y: o0.y + (mouse.y - m0.y)))
            }
            .onEnded { _ in
                dragStartMouse = nil
                dragStartOrigin = nil
                controller.endUserDrag()
            }
    }




    /// 坞空白处右键：坞自己的设置项（位置 / 材质 / 回位）+ 隐藏 + 通用操作
    @ViewBuilder
    private var dockMenu: some View {
        Button(L10n.t("打开面板")) { controller.showDetail(model: model) }
        Divider()
        Toggle(isOn: Binding(get: { model.sideDock == "left" },
                             set: { if $0 { model.sideDock = "left" } })) {
            Text(L10n.t("移到左侧"))
        }
        Toggle(isOn: Binding(get: { model.sideDock == "right" },
                             set: { if $0 { model.sideDock = "right" } })) {
            Text(L10n.t("移到右侧"))
        }
        Divider()
        Toggle(isOn: Binding(get: { model.dockStyle == "ink" },
                             set: { if $0 { model.dockStyle = "ink" } })) {
            Text(L10n.t("黑色"))
        }
        Toggle(isOn: Binding(get: { model.dockStyle == "glass" },
                             set: { if $0 { model.dockStyle = "glass" } })) {
            Text(L10n.t("液态玻璃"))
        }
        Divider()
        Button(L10n.t("回到默认位置")) { model.resetDockPosition() }
        Button(L10n.t("隐藏悬浮坞")) { model.sideDock = "off" }
        Divider()
        Button(L10n.t("设置…")) { AppActions.shared.openSettings() }
        Button(L10n.t("退出 TokenMeter")) { AppActions.shared.quit() }
    }

    /// 工具行右键：只针对这一个工具
    @ViewBuilder
    private func rowMenu(_ name: String) -> some View {
        Button(L10n.t("隐藏") + "「" + name + "」") { model.hideDockSource(name) }
        Divider()
        Button(L10n.t("设置…")) { AppActions.shared.openSettings() }
    }

    /// 底行：燃烧中=速率（含 0/s），空闲=命中率；悬浮时改为判定说明
    private var bottomIsRate: Bool { model.isBurning }
    private var bottomText: String {
        guard let s = todaySummary else { return " " }
        if model.isBurning { return Fmt.compactTokens(model.burnRate ?? 0) + "/s" }
        return Fmt.percent(s.cacheHitRate)
    }

    @ViewBuilder
    private var iconView: some View {
        if model.isBurning {
            // 用 AppKit 直接换图：每帧只换 NSImage，
            // 不再让整个坞参与 SwiftUI 布局（10Hz 布局是主要 CPU 开销之一）。
            // 必须显式给 frame：NSViewRepresentable 会按 NSImageView 的固有尺寸排版，
            // 而固有尺寸是原始图片大小（上百像素），不约束就会显示成巨大火苗。
            let sz: CGFloat = model.flameTier == .blast ? 30 : 26
            FrameSequenceView(frames: model.flameFrames(for: sz), ticker: model.flame, size: sz)
                .frame(width: sz, height: sz)
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 20))
                .foregroundStyle(textTertiary)
        }
    }

    /// 坞底 harness 三态行：橙脉冲=运行中 / 绿=待阅读 / 灰=空闲；居左 + 图标
    private var harnessRows: some View {
        VStack(spacing: 6) {
            ForEach(model.visibleDockSources, id: \.0) { name, state in
                HStack(spacing: 0) {
                    if state == 0 {
                        PulseDot()
                            .frame(width: 7, height: 7)
                    } else {
                        Circle()
                            .fill(state == 1 ? Color.green : (isGlassDock ? Color.black.opacity(0.42) : Color.white.opacity(0.3)))
                            .frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 6)
                    if let img = model.harnessIcons[name] {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            // 浅色玻璃上白色 logo（如 Claude）会消失，加一层极淡描边阴影提对比
                            .shadow(color: isGlassDock ? Color.black.opacity(0.35) : .clear,
                                    radius: isGlassDock ? 1.2 : 0)
                    } else {
                        // 没有官方图标时不要自己造字母徽章（看起来像另一个产品），
                        // 统一退到 harness 中性图标
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(textTertiary)
                            .frame(width: 26, height: 26)
                    }
                }
                .padding(.trailing, 5)
                // 黑色档靠透明度淡化"空闲"图标；玻璃档是浅底，半透明会看不清，保持不透明
                .opacity(isGlassDock ? 1 : (state == 2 ? 0.45 : 1))
                .frame(width: 44)
                .frame(width: 56)
                .contextMenu { rowMenu(name) }
            }
        }
        .padding(.top, 8)
    }

    /// 玻璃档是浅色底，文字要用深色；黑色档沿用白字
    private var isGlassDock: Bool { model.dockStyle == "glass" }
    private var textPrimary: Color { isGlassDock ? .black.opacity(0.86) : .white }
    private var textSecondary: Color { isGlassDock ? .black.opacity(0.55) : .white.opacity(0.55) }
    private var textTertiary: Color { isGlassDock ? .black.opacity(0.45) : .white.opacity(0.7) }
    private var hairline: Color { isGlassDock ? .black.opacity(0.14) : .white.opacity(0.15) }

    /// 坞外形：玻璃档用完整圆角浮块（不做贴边融合的内凹角），黑色档保留融合凹角
    private var dockShape: AnyShape {
        if model.dockStyle == "glass" {
            // 玻璃档：正圆角胶囊，四角半径完全一致（BarFlareShape 的融合曲线各角不一致）
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 30, bottomLeadingRadius: 30,
                bottomTrailingRadius: 30, topTrailingRadius: 30,
                style: .continuous))
        }
        // 黑色档：贴边融合的凹角要和左侧圆角视觉一致，否则一大一小很怪。
        // flare/rise 是凹弧的水平外扩与爬升，都取 radius 后两个角大小就对得上了。
        return AnyShape(BarFlareShape(side: controller.side,
                                      fuse: controller.fuse,
                                      bottomInset: controller.bottomInset,
                                      radius: BarFlareShape.defaultRadius))
    }

    /// 悬浮坞底色：纯黑 / 液态玻璃（macOS 26+ 走系统 glassEffect，旧系统用材质）
    @ViewBuilder
    private func dockBackground(ink: Color) -> some View {
        let shape = dockShape
        if model.dockStyle == "glass" {
            let v = min(max(model.glassOpacity, 0), 1)
            let dark = scheme == .dark
            // 直接用系统液态玻璃视图（NSGlassEffectView）当背景：模糊、折射、边缘光都是系统的，
            // 比在 SwiftUI 里拿 Shape 拼材质更接近系统观感。
            let radius: CGFloat = 30
            let tintSwiftUI = (dark ? Color(white: 0.06) : Color(white: 0.99)).opacity(0.05 * v)
            ZStack {
                if v < 0.04 {
                    shape.fill(.clear)
                } else {
                    // 用 SwiftUI 原生 glassEffect：它是普通图层，会被 clipShape 正确裁切、
                    // 也不会盖住上面的高光（NSGlassEffectView 是独立 AppKit 视图，
                    // 实测既不被 clipShape 裁、又会压在高光之上，所以退回这里）。
                    // 材质/玻璃这类「系统效果图层」上屏合成时不吃 SwiftUI 的 clipShape
                    // （窗口截图里是圆角、屏幕上却是直角方块）。
                    // 必须用 background(_:in:) 让系统自己按形状裁切。
                    // 毛玻璃由 AppKit 的 DockBackdropView 负责（layer 裁切，上屏可靠）。
                    // 这里只保留一层极薄的着色，让玻璃档和黑档在色彩上区分开。
                    shape.fill(Color.white.opacity(0.06 * v))
                    shape.fill(LinearGradient(
                        colors: [tintSwiftUI.opacity(0.6), tintSwiftUI.opacity(0.2)],
                        startPoint: .top, endPoint: .bottom))
                    // 先画一圈很淡的暗边：玻璃压在浅色页面上时，圆角会「糊」进背景，
                    // 有了这圈边界，圆角轮廓才看得出来。
                    shape.stroke(Color.black.opacity(dark ? 0.28 : 0.13), lineWidth: 2.0)
                    // 高光限制在顶部 66×66 的方形区域内做渐变，对角线才是真正的 45°。
                    shape.stroke(Color.white, lineWidth: 2.6)
                        .mask(
                            LinearGradient(
                                stops: [.init(color: .white, location: 0.00),
                                        .init(color: .white.opacity(0.55), location: 0.12),
                                        .init(color: .white.opacity(0.12), location: 0.26),
                                        .init(color: .clear, location: 0.40)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: 66, height: 66)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        )
                    // 左上角径向辉光：光进入玻璃后的散射
                    Rectangle()
                        .fill(RadialGradient(
                            colors: [.white.opacity(dark ? 0.16 : 0.30), .clear],
                            center: .topLeading, startRadius: 0, endRadius: 90))
                        .frame(width: 150, height: 150)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // 右下背光侧暗边：厚度感，与左上亮边形成斜向明暗
                    shape.stroke(Color.black.opacity(dark ? 0.30 : 0.14), lineWidth: 2.2)
                        .mask(
                            LinearGradient(
                                stops: [.init(color: .clear, location: 0.72),
                                        .init(color: .white, location: 1.00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: 120, height: 120)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        )
                }
            }
            .clipShape(shape)
        } else {
            shape.fill(ink)
        }
    }

    var body: some View {
        let ink = Color.black
        return VStack(spacing: 0) {
          VStack(spacing: 3) {
            iconView
            Text(L10n.t("今天")).font(.system(size: 9)).foregroundStyle(textSecondary)
            Text(tokensText)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(costText)
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(textTertiary)
            Rectangle().fill(hairline).frame(width: 20, height: 1)
            Text(bottomText)
                .font(.system(size: 7, weight: model.isBurning ? .semibold : .regular))
                .foregroundStyle(model.isBurning ? Color.orange : textSecondary)
          }
          .frame(width: 44, height: 112)
          .frame(width: 56)
          .padding(.top, isGlassDock ? 14 : 28)
          harnessRows
          Spacer(minLength: 0)
        }
        .padding(.bottom, controller.bottomInset)
        // 黑色档的可见区域贴着一侧（内缩 8pt），内容要跟着贴边；
        // 玻璃档是四边内缩 4pt 的胶囊，内容必须居中，否则会偏右
        .frame(width: 64, height: controller.dockHeight,
               alignment: isGlassDock ? .top : (controller.side == "right" ? .topTrailing : .topLeading))
        .background(dockBackground(ink: ink))
        .overlay(dockShape.stroke(Color.white.opacity(model.dockStyle == "glass" ? 0.25 : 0.06), lineWidth: 0.7))
        .contentShape(Rectangle())
        .contextMenu { dockMenu }
        .gesture(dragGesture)
        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
        .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
