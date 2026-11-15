#if os(macOS)
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
    var radius: CGFloat = 14

    var animatableData: CGFloat {
        get { fuse }
        set { fuse = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = radius
        let f = flare * fuse         // 喇叭口水平外扩量
        let oR = radius * (1 - fuse) // 外侧圆角半径
        let oy = barInsetY           // 舱体顶
        let ob = h - bottomInset     // 舱体底
        let ixL = side == "right" ? ix : 0     // 内侧边 x
        let ixR = side == "right" ? w : w - ix
        // 外侧上角：浮块角弧端点 (w, oy+oR) ↔ 融合收尖端 (w, oy-rise)
        let topEndY = oy + oR * (1 - fuse) - rise * fuse
        let botEndY = ob - oR * (1 - fuse) + rise * fuse
        // 控制点插值：浮块圆弧近似 (0.55r) ↔ 融合凹弧 (0.75f / 0.45wing)
        let c1x = w - (r - 0.55 * r) * (1 - fuse) - (flare * 0.75) * fuse
        let c2yTop = (oy + 0.45 * r) * (1 - fuse) + (oy - rise * 0.55) * fuse
        let c2yBot = (ob - 0.45 * r) * (1 - fuse) + (ob + rise * 0.55) * fuse
        var p = Path()
        if side == "right" {
            p.move(to: CGPoint(x: ixL + r, y: oy))
            p.addLine(to: CGPoint(x: w - f - oR, y: oy))
            p.addCurve(to: CGPoint(x: w, y: topEndY),
                       control1: CGPoint(x: c1x, y: oy),
                       control2: CGPoint(x: w, y: c2yTop))
            p.addLine(to: CGPoint(x: w, y: botEndY))
            p.addCurve(to: CGPoint(x: w - f - oR, y: ob),
                       control1: CGPoint(x: w, y: c2yBot),
                       control2: CGPoint(x: c1x, y: ob))
            p.addLine(to: CGPoint(x: ixL + r, y: ob))
            p.addQuadCurve(to: CGPoint(x: ixL, y: ob - r), control: CGPoint(x: ixL, y: ob))
            p.addLine(to: CGPoint(x: ixL, y: oy + r))
            p.addQuadCurve(to: CGPoint(x: ixL + r, y: oy), control: CGPoint(x: ixL, y: oy))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: ixR - r, y: oy))
            p.addLine(to: CGPoint(x: f + oR, y: oy))
            p.addCurve(to: CGPoint(x: 0, y: topEndY),
                       control1: CGPoint(x: w - c1x, y: oy),
                       control2: CGPoint(x: 0, y: c2yTop))
            p.addLine(to: CGPoint(x: 0, y: botEndY))
            p.addCurve(to: CGPoint(x: f + oR, y: ob),
                       control1: CGPoint(x: 0, y: c2yBot),
                       control2: CGPoint(x: w - c1x, y: ob))
            p.addLine(to: CGPoint(x: ixR - r, y: ob))
            p.addQuadCurve(to: CGPoint(x: ixR, y: ob - r), control: CGPoint(x: ixR, y: ob))
            p.addLine(to: CGPoint(x: ixR, y: oy + r))
            p.addQuadCurve(to: CGPoint(x: ixR - r, y: oy), control: CGPoint(x: ixR, y: oy))
            p.closeSubpath()
        }
        return p
    }
}

/// 悬浮坞面板：SwiftUI hosting 会吞掉右键，需在窗口层捕获
final class DockPanel: NSPanel {
    var contextMenu: NSMenu?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu, let view = contentView else {
            super.rightMouseDown(with: event)
            return
        }
        let point = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

/// 侧边悬浮坞：单窗口。拖动=独立圆角浮块；松手=滑向较近屏边并 cross-fade 成贴边融合形态；
/// 位置/侧别记忆；双击回位；单击弹面板。四角完全透明（无投影 haze）
@MainActor
final class SideDockController: ObservableObject {
    static let barWidth: CGFloat = 64
    static let barBlockHeight: CGFloat = 168   // 舱体块恒定（已知安全组合）；可见舱体由形状内缩参数控制
    var rowCount: Int = 0
    var bottomInset: CGFloat { rowCount > 0 ? 10 : 28 }
    var dockHeight: CGFloat { max(Self.barBlockHeight, 28 + 112 + (rowCount > 0 ? 10 + CGFloat(rowCount) * 34 : 0) + bottomInset) }

    @Published var fuse: CGFloat = 1     // 0 = 浮块圆角矩形，1 = 贴边融合
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
        panel.contentView = NSHostingView(rootView:
            SideDockView(controller: self).environmentObject(model))
        panel.contextMenu = AppActions.shared.buildMenu(model: model)
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
    /// 悬浮某个工具时，底行改为显示「状态 + 判定依据」
    @State private var hoveredSource: String?
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

    private func stateColor(_ state: Int) -> Color {
        switch state {
        case 0: return .orange
        case 1: return .green
        default: return .white.opacity(0.55)
        }
    }

    private func stateText(_ state: Int) -> String {
        switch state {
        case 0: return "运行中"
        case 1: return "待阅读"
        default: return "空闲"
        }
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
            FlameIcon(ticker: model.flame, frames: model.currentFlameFrames,
                      size: model.flameTier == .blast ? 30 : 26)
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 20))
                .foregroundStyle(textTertiary)
        }
    }

    /// 品牌色字母徽章（无真 App 图标时）
    private func badgeColor(_ name: String) -> Color {
        switch name {
        case "Claude Code": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "Codex": return Color(red: 0.06, green: 0.64, blue: 0.50)
        case "DSH": return Color(red: 0.30, green: 0.42, blue: 0.99)
        case "OpenCode": return Color(red: 0.88, green: 0.64, blue: 0.35)
        case "Hermes": return Color(red: 0.49, green: 0.36, blue: 1.0)
        case "ZCode": return Color(red: 0.13, green: 0.77, blue: 0.37)
        default: return Color.gray
        }
    }
    private func monogram(_ name: String) -> String {
        switch name {
        case "Claude Code": return "C"
        case "Codex": return "X"
        case "DSH": return "D"
        case "OpenCode": return "O"
        case "Hermes": return "H"
        case "ZCode": return "Z"
        default: return String(name.prefix(1))
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
                        Text(monogram(name))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(textPrimary)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(badgeColor(name)))
                    }
                }
                .padding(.trailing, 5)
                // 黑色档靠透明度淡化"空闲"图标；玻璃档是浅底，半透明会看不清，保持不透明
                .opacity(isGlassDock ? 1 : (state == 2 ? 0.45 : 1))
                .frame(width: 44)
                .frame(width: 56)
                .onHover { inside in
                    if inside { hoveredSource = name }
                    else if hoveredSource == name { hoveredSource = nil }
                }
                .help("\(name)｜\(stateText(state))\n\(ActivityDetector.stateBasis(for: name))")
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
                style: .continuous)
                .inset(by: 4))
        }
        // 黑色档：贴边融合的凹角要和左侧圆角视觉一致，否则一大一小很怪。
        // flare/rise 是凹弧的水平外扩与爬升，都取 radius 后两个角大小就对得上了。
        return AnyShape(BarFlareShape(side: controller.side,
                                      fuse: controller.fuse,
                                      bottomInset: controller.bottomInset,
                                      flare: 26,
                                      rise: 26,
                                      radius: 26))
    }

    /// 悬浮坞底色：纯黑 / 液态玻璃（macOS 26+ 走系统 glassEffect，旧系统用材质）
    @ViewBuilder
    private func dockBackground(ink: Color) -> some View {
        let shape = dockShape
        if model.dockStyle == "glass" {
            if #available(macOS 26.0, *) {
                // 与面板共用同一个不透明度设置。
                // 注意：系统玻璃即使 tint 为 0 也会带一层膜，所以 0% 时必须完全不叠玻璃层，
                // 否则永远"不透"。
                let v = min(max(model.glassOpacity, 0), 1)
                if v < 0.04 {
                    shape.fill(.clear)
                } else {
                    ZStack {
                        // ① 系统玻璃：提供真实背景模糊 + 边缘折射
                        shape.fill(.clear)
                            .glassEffect(.regular, in: shape)
                        // ② 主体薄雾：拉高滑块才明显
                        shape.fill(Color.white.opacity(0.42 * v))
                        // ③ 自绘反光：顶部高光带（玻璃最直观的特征）
                        shape.fill(
                            LinearGradient(
                                colors: [.white.opacity(0.55 * v), .white.opacity(0.12 * v),
                                         .clear, .white.opacity(0.10 * v)],
                                startPoint: .top, endPoint: .bottom))
                            .blendMode(.plusLighter)
                        // ④ 斜面亮边 + 底部内阴影：立体感
                        shape.stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.95), .white.opacity(0.30), .clear],
                                startPoint: .topLeading, endPoint: .center),
                            lineWidth: 1.3)
                        shape.fill(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.10)],
                                startPoint: .center, endPoint: .bottom))
                        shape.stroke(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.12)],
                                startPoint: .center, endPoint: .bottomTrailing),
                            lineWidth: 1)
                    }
                    .compositingGroup()
                    .clipShape(shape)
                }
            } else {
                shape.fill(.ultraThinMaterial)
            }
        } else {
            shape.fill(ink)
        }
    }

    var body: some View {
        let ink = Color.black
        return VStack(spacing: 0) {
          VStack(spacing: 3) {
            iconView
            Text("今天").font(.system(size: 9)).foregroundStyle(textSecondary)
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
            if let hovered = hoveredSource {
                VStack(spacing: 0) {
                    Text(stateText(model.sourceStates.first { $0.0 == hovered }?.1 ?? 2))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(stateColor(model.sourceStates.first { $0.0 == hovered }?.1 ?? 2))
                    Text(ActivityDetector.shortBasis(for: hovered))
                        .font(.system(size: 6))
                        .foregroundStyle(textSecondary)
                }
                .lineLimit(1)
                .frame(width: 56)
            } else {
                Text(bottomText)
                    .font(.system(size: 7, weight: model.isBurning ? .semibold : .regular))
                    .foregroundStyle(model.isBurning ? Color.orange : textSecondary)
            }
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
        .gesture(dragGesture)
        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
        .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
