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
    /// 底部内缩：黑档沿用原来的 28（融合凹弧的形状参数，改了形状就变）；
    /// 玻璃档是胶囊，用更小的 16 让最后一行更靠下。
    var bottomInset: CGFloat { isGlassStyle ? 16 : max(28, BarFlareShape.defaultRadius + 2) }
    /// 玻璃档顶部内边距更小（胶囊本身有弧度），黑档需要更多
    var isGlassStyle: Bool = true
    var topPadding: CGFloat { isGlassStyle ? 14 : 28 }
    /// 工具行占位高度：玻璃档 29pt 图标 + 11 行距；黑档保持原来的 26pt 图标 + 6 行距
    var rowsBlockHeight: CGFloat {
        guard rowCount > 0 else { return 0 }
        return isGlassStyle ? CGFloat(rowCount) * 40 - 3 : 10 + CGFloat(rowCount) * 34
    }
    var dockHeight: CGFloat { max(Self.barBlockHeight, topPadding + 112 + rowsBlockHeight + bottomInset) }

    @Published var fuse: CGFloat = 1     // 0 = 浮块圆角矩形，1 = 贴边融合（拖动/回弹时渐变）
    /// 坞是否真正显示着（用于判断「同一侧但被关掉了」这种状态）
    /// 防重入：apply 内部会回写 model.sideDock，其 didSet 又会调 apply，
    /// 不拦会出现「一次启动创建多个坞窗口」。
    private var isApplying = false
    var isShowing: Bool { panel != nil }
    /// 坞当前实际吸附在哪一侧（拖动后会和设置里的值同步）
    weak var appModel: AppModel?
    @Published var side: String = "right"
    @Published private(set) var glassDarkBackdrop: Bool?

    private var panel: NSPanel?
    private var glassBackdrop: DockBackdropView? { panel?.contentView as? DockBackdropView }
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var mouseUpLocal: Any?
    private var mouseUpGlobal: Any?
    private var snapping = false

    /// useSaved=true 仅首启：沿用上次吸附的侧别；设置切换走 false：显式意图优先
    func apply(mode: String, model: AppModel, useSaved: Bool = false) {
        self.appModel = model
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        isGlassStyle = model.dockStyle == "glass"
        teardown()
        guard mode == "left" || mode == "right" else { return }
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        side = useSaved ? (UserDefaults.standard.string(forKey: "dockSide") ?? mode) : mode
        // 启动时按「实际吸附的侧别」回写设置，避免坞在左边、设置/菜单却显示右边
        if model.sideDock != side { model.sideDock = side }
        rowCount = model.visibleDockSources.count
        fuse = 1

        let panel = DockPanel(
            contentRect: NSRect(origin: originFor(side: side, vf: vf, saved: useSaved), size: NSSize(width: Self.barWidth, height: dockHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        if !isGlassStyle { panel.appearance = NSAppearance(named: .darkAqua) }
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
        if isGlassStyle {
            panel.contentView = DockBackdropView(
                frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: dockHeight),
                content: hosting, opacity: model.glassOpacity
            ) { [weak self] dark in
                self?.glassDarkBackdrop = dark
            }
        } else {
            panel.contentView = hosting
        }
        panel.orderFrontRegardless()
        self.panel = panel
        glassBackdrop?.start()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.glassBackdrop?.updateRegion()
                    guard !self.snapping, self.fuse == 1 else { return }
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
        glassBackdrop?.stop()
        panel?.orderOut(nil)
        panel = nil
    }

    func updateGlassOpacity(_ opacity: Double) {
        glassBackdrop?.setOpacity(opacity)
    }

    func enableGlassEffects() {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            glassBackdrop?.recheckPermission()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
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
                // 菜单里的勾选和设置项都读 sideDock，拖到另一侧后要同步，
                // 否则会出现「坞在左边、菜单勾的却是右边」。
                if self.appModel?.sideDock != newSide { self.appModel?.sideDock = newSide }
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
        Toggle(isOn: Binding(get: { controller.side == "left" },
                             set: { if $0 { model.sideDock = "left" } })) {
            Text(L10n.t("移到左侧"))
        }
        Toggle(isOn: Binding(get: { controller.side == "right" },
                             set: { if $0 { model.sideDock = "right" } })) {
            Text(L10n.t("移到右侧"))
        }
        Divider()
        Toggle(isOn: Binding(get: { !isGlassDock },
                             set: { if $0 { model.dockStyle = "ink" } })) {
            Text(L10n.t("黑色"))
        }
        Toggle(isOn: Binding(get: { model.dockStyle == "glass" },
                             set: { if $0 { model.dockStyle = "glass" } })) {
            Text(L10n.t("液态玻璃"))
        }
        if isGlassDock && !CGPreflightScreenCaptureAccess() {
            Button(L10n.t("允许背景折射与自动字色…")) { controller.enableGlassEffects() }
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

    /// 燃烧时按显示设置选速率，其他时候展示缓存命中率。
    private var bottomIsRate: Bool { model.isBurning && model.rateDisplayMode != "never" }
    private var bottomText: String {
        guard let s = todaySummary else { return " " }
        if bottomIsRate { return Fmt.compactTokens(model.burnRate ?? 0) + "/s" }
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
        VStack(spacing: controller.isGlassStyle ? 11 : 6) {
            ForEach(model.visibleDockSources, id: \.0) { name, state in
                HStack(spacing: 0) {
                    if state == 0 {
                        PulseDot()
                            .frame(width: 7, height: 7)
                    } else {
                        Circle()
                            .fill(state == 1 ? Color.green : (isGlassDock ? textPrimary.opacity(0.46) : .white.opacity(0.3)))
                            .frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 6)
                    if let img = model.harnessIcons[name] {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: controller.isGlassStyle ? 29 : 26,
                                    height: controller.isGlassStyle ? 29 : 26)
                            .shadow(color: isGlassDock ? .black.opacity(usesLightText ? 0.16 : 0.35) : .clear,
                                    radius: isGlassDock ? 1.2 : 0)
                    } else {
                        // 没有官方图标时不要自己造字母徽章（看起来像另一个产品），
                        // 统一退到 harness 中性图标
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: controller.isGlassStyle ? 17 : 15, weight: .medium))
                            .foregroundStyle(textTertiary)
                            .frame(width: controller.isGlassStyle ? 29 : 26,
                                    height: controller.isGlassStyle ? 29 : 26)
                    }
                }
                .padding(.trailing, 5)
                // 玻璃上的品牌图标保留色彩，通过左侧圆点区分空闲状态。
                .opacity(isGlassDock ? 1 : (state == 2 ? 0.45 : 1))
                .frame(width: 44)
                .frame(width: 56)
                .contextMenu { rowMenu(name) }
            }
        }
        .padding(.top, 8)
    }

    private var isGlassDock: Bool { model.dockStyle == "glass" }
    private var usesLightText: Bool {
        !isGlassDock || (controller.glassDarkBackdrop ?? (scheme == .dark))
    }
    private var textPrimary: Color { usesLightText ? .white : Color(white: 0.04) }
    private var textSecondary: Color { textPrimary.opacity(isGlassDock ? 0.86 : 0.55) }
    private var textTertiary: Color { textPrimary.opacity(isGlassDock ? 0.82 : 0.7) }
    private var hairline: Color { textPrimary.opacity(isGlassDock ? 0.28 : 0.15) }

    private var inkShape: BarFlareShape {
        BarFlareShape(side: controller.side, fuse: controller.fuse, bottomInset: controller.bottomInset)
    }

    private var glassRim: some View {
        let rim = RoundedRectangle(cornerRadius: DockBackdropView.cornerRadius, style: .circular)
        return rim.strokeBorder(
            LinearGradient(stops: [
                .init(color: .white.opacity(0.84), location: 0),
                .init(color: .white.opacity(0.36), location: 0.17),
                .init(color: .black.opacity(0.16), location: 0.54),
                .init(color: .white.opacity(0.40), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
        .background {
            rim.strokeBorder(
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .clear, location: 0.36),
                    .init(color: .clear, location: 0.72),
                    .init(color: .white.opacity(0.17), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 3)
        }
        .overlay {
            rim.inset(by: 1.4).strokeBorder(
                LinearGradient(colors: [.black.opacity(0.15), .clear, .white.opacity(0.22)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }

    var body: some View {
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
                .font(.system(size: 7, weight: bottomIsRate ? .semibold : .regular))
                .foregroundStyle(bottomIsRate && !isGlassDock ? Color.orange : textSecondary)
          }
          .shadow(color: isGlassDock ? (usesLightText ? .black.opacity(0.44) : .white.opacity(0.54)) : .clear,
                  radius: 0.8)
          .frame(width: 44, height: 112)
          .frame(width: 56)
          .padding(.top, controller.topPadding)
          harnessRows
          Spacer(minLength: 0)
        }
        .padding(.bottom, controller.bottomInset)
        // 黑色档的可见区域贴着一侧（内缩 8pt），内容要跟着贴边；
        // 玻璃档是四边内缩 4pt 的胶囊，内容必须居中，否则会偏右
        .frame(width: 64, height: controller.dockHeight,
               alignment: isGlassDock ? .top : (controller.side == "right" ? .topTrailing : .topLeading))
        .background { if !isGlassDock { inkShape.fill(.black) } }
        .overlay {
            if isGlassDock { glassRim }
            else { inkShape.stroke(.white.opacity(0.06), lineWidth: 0.7) }
        }
        .contentShape(Rectangle())
        .contextMenu { dockMenu }
        .gesture(dragGesture)
        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
        .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
