#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 导轨+舱体融合形状：沿屏边全高窄导轨；舱体停在 barY 处，交界处凹弧随 fuse(0...1) 生长/收回
struct RailShape: Shape {
    let mode: String        // "left" / "right"
    var barY: CGFloat       // 舱体中心 y（view 坐标）
    var barH: CGFloat = 176
    var fuse: CGFloat = 1   // 0 = 直角交界（分离感），1 = 完全融合凹弧
    var showBar: Bool = true
    var strip: CGFloat = 9
    var wing: CGFloat = 20
    var radius: CGFloat = 16

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fuse, barY) }
        set { fuse = newValue.first; barY = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let s = strip, f = wing * fuse, r = radius
        let oy = barY - barH / 2
        let ob = barY + barH / 2
        if mode == "right" {
            p.move(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w - s, y: 0))
            if showBar {
                p.addLine(to: CGPoint(x: w - s, y: oy - f))
                p.addQuadCurve(to: CGPoint(x: w - s - f, y: oy), control: CGPoint(x: w - s, y: oy))
                p.addLine(to: CGPoint(x: r, y: oy))
                p.addQuadCurve(to: CGPoint(x: 0, y: oy + r), control: CGPoint(x: 0, y: oy))
                p.addLine(to: CGPoint(x: 0, y: ob - r))
                p.addQuadCurve(to: CGPoint(x: r, y: ob), control: CGPoint(x: 0, y: ob))
                p.addLine(to: CGPoint(x: w - s - f, y: ob))
                p.addQuadCurve(to: CGPoint(x: w - s, y: ob + f), control: CGPoint(x: w - s, y: ob))
            }
            p.addLine(to: CGPoint(x: w - s, y: h))
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: s, y: 0))
            if showBar {
                p.addLine(to: CGPoint(x: s, y: oy - f))
                p.addQuadCurve(to: CGPoint(x: s + f, y: oy), control: CGPoint(x: s, y: oy))
                p.addLine(to: CGPoint(x: w - r, y: oy))
                p.addQuadCurve(to: CGPoint(x: w, y: oy + r), control: CGPoint(x: w, y: oy))
                p.addLine(to: CGPoint(x: w, y: ob - r))
                p.addQuadCurve(to: CGPoint(x: w - r, y: ob), control: CGPoint(x: w, y: ob))
                p.addLine(to: CGPoint(x: s + f, y: ob))
                p.addQuadCurve(to: CGPoint(x: s, y: ob + f), control: CGPoint(x: s, y: ob))
            }
            p.addLine(to: CGPoint(x: s, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
        return p
    }
}

/// 侧边悬浮坞：全高导轨 + 可拖拽舱体；拖拽中舱体脱离导轨成为独立圆角浮块，
/// 松手后滑回较近一侧并沿导轨融合（凹弧 fuse 0→1 形变动画）
@MainActor
final class SideDockController: ObservableObject {
    static let barSize = NSSize(width: 64, height: 176)

    @Published var currentMode: String = "right"
    @Published var fuse: CGFloat = 1
    @Published var showBar: Bool = true
    @Published var barY: CGFloat = 0      // view 坐标（导轨面板内）
    @Published var floating: Bool = false

    private var railPanel: NSPanel?
    private var floatPanel: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var mouseUpObserver: Any?
    private var floatStartOrigin: NSPoint = .zero
    private var dragStartCenter: CGFloat = 0

    func apply(mode: String, model: AppModel) {
        teardown()
        guard mode == "left" || mode == "right" else { return }
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let side = savedSide() ?? mode
        currentMode = side

        // 导轨面板：全高贴边
        let rail = NSPanel(
            contentRect: NSRect(x: side == "left" ? vf.minX : vf.maxX - 64, y: vf.minY, width: 64, height: vf.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        configureFloatingPanel(rail)
        rail.contentView = NSHostingView(rootView: RailView(controller: self).environmentObject(model))
        rail.orderFrontRegardless()
        railPanel = rail

        // 浮块面板：拖拽时的独立圆角矩形
        let float = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.barSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        configureFloatingPanel(float)
        float.isMovableByWindowBackground = true
        float.contentView = NSHostingView(rootView: FloatView(controller: self).environmentObject(model))
        floatPanel = float

        barY = initialBarY(vf: vf)
        fuse = 1
        showBar = true
        floating = false

        // 全局 mouseUp：浮块态松手即吸附（不再用定时器，按住多久都不会误触）
        mouseUpObserver = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.floating else { return }
                self.snapFloat()
            }
        } as Any?
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self, weak model] _ in
                Task { @MainActor [weak self] in
                    guard let self, let model else { return }
                    self.apply(mode: model.sideDock, model: model)
                }
            }
    }

    private func configureFloatingPanel(_ p: NSPanel) {
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
    }

    func teardown() {
        if let obs = mouseUpObserver { NSEvent.removeMonitor(obs); mouseUpObserver = nil }
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs); screenObserver = nil }
        railPanel?.orderOut(nil); railPanel = nil
        floatPanel?.orderOut(nil); floatPanel = nil
    }

    // MARK: - 拖拽：导轨舱体 → 浮块

    func beginFloat() {
        guard !floating, let rail = railPanel, let float = floatPanel else { return }
        let barScreen = barScreenOrigin()
        _ = rail
        floatStartOrigin = barScreen
        dragStartCenter = barScreen.x + Self.barSize.width / 2
        floating = true
        showBar = false
        fuse = 0
        float.setFrameOrigin(barScreen)
        float.orderFrontRegardless()
    }

    func moveFloat(translation: CGSize) {
        guard floating, let float = floatPanel else { return }
        let o = NSPoint(x: floatStartOrigin.x + translation.width,
                        y: floatStartOrigin.y - translation.height)
        float.setFrameOrigin(o)
    }

    /// 松手：滑向较近一侧导轨并融合
    func snapFloat() {
        guard floating, let float = floatPanel, let rail = railPanel, let screen = NSScreen.main else { return }
        floating = false
        let vf = screen.visibleFrame
        let center = float.frame.midX
        let side = center < vf.midX ? "left" : "right"
        let targetX = side == "left" ? vf.minX : vf.maxX - Self.barSize.width
        var targetY = float.frame.origin.y
        targetY = min(max(targetY, vf.minY), vf.maxY - Self.barSize.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            float.animator().setFrameOrigin(NSPoint(x: targetX, y: targetY))
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                float.setFrameOrigin(NSPoint(x: targetX, y: targetY))
                self.currentMode = side
                if side != self.railSide() { self.repositionRail(side: side, vf: vf) }
                // 舱体归位导轨：view 坐标 y = 屏幕顶 - 屏幕y
                let newBarY = (vf.maxY - targetY) - Self.barSize.height / 2
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    self.barY = newBarY
                    self.showBar = true
                    self.fuse = 1      // 凹弧生长 = 衍射融合
                }
                float.orderOut(nil)
                self.save(side: side, barScreenY: targetY + Self.barSize.height / 2)
                _ = rail
            }
        })
    }

    private func railSide() -> String { currentMode }

    private func repositionRail(side: String, vf: NSRect) {
        guard let rail = railPanel else { return }
        rail.setFrameOrigin(NSPoint(x: side == "left" ? vf.minX : vf.maxX - 64, y: vf.minY))
    }

    /// 舱体当前屏幕原点（用于浮块接管位置）
    func barScreenOrigin() -> NSPoint {
        guard let rail = railPanel else { return .zero }
        let rf = rail.frame
        // view y（顶向下）→ 屏幕 y（底向上）：barTopScreen = rf.maxY - barYView + barH/2 ... 计算原点(左下)
        let barTopScreen = rf.maxY - (barY - Self.barSize.height / 2)
        let x = currentMode == "left" ? rf.minX : rf.minX   // 导轨面板宽=舱宽，x 相同
        return NSPoint(x: x, y: barTopScreen - Self.barSize.height)
    }

    // MARK: - 持久化

    private func savedSide() -> String? { UserDefaults.standard.string(forKey: "dockSide") }
    private func save(side: String, barScreenY: Double) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        UserDefaults.standard.set(side, forKey: "dockSide")
        UserDefaults.standard.set((barScreenY - vf.minY) / max(1, vf.height), forKey: "dockYFrac")
    }
    private func initialBarY(vf: NSRect) -> CGFloat {
        let frac = UserDefaults.standard.object(forKey: "dockYFrac") == nil
            ? 0.5
            : UserDefaults.standard.double(forKey: "dockYFrac")
        let centerScreen = vf.minY + CGFloat(frac) * vf.height
        let viewY = (vf.maxY - centerScreen)
        return min(max(viewY, Self.barSize.height / 2 + 30), vf.height - Self.barSize.height / 2 - 30)
    }

    func resetPosition(mode: String) {
        guard let screen = NSScreen.main, let rail = railPanel else { return }
        let vf = screen.visibleFrame
        currentMode = mode
        repositionRail(side: mode, vf: vf)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            barY = rail.frame.height / 2
            fuse = 1
            showBar = true
        }
        UserDefaults.standard.removeObject(forKey: "dockSide")
        UserDefaults.standard.removeObject(forKey: "dockYFrac")
    }

    func showDetail(model: AppModel) {
        if detail == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            win.title = "TokenMeter"
            win.contentView = NSHostingView(rootView: PanelView().environmentObject(model))
            win.isReleasedWhenClosed = false
            detail = win
        }
        detail?.center()
        detail?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 舱体内容（导轨态与浮块态共用）
struct DockContentView: View {
    @EnvironmentObject var model: AppModel

    private var todaySummary: Summary? { model.summariesByRange[.today] }
    private var tokensText: String {
        let t = todaySummary.map { model.includeCache ? $0.counts.total : $0.counts.input + $0.counts.output } ?? 0
        return Fmt.compactTokens(t)
    }
    private var costText: String { Fmt.cost(todaySummary?.cost ?? 0) }
    private var bottomText: String {
        if model.isBurning { return Fmt.compactTokens(model.burnRate ?? 0) + "/s" }
        return Fmt.percent(todaySummary?.cacheHitRate ?? 0)
    }

    @ViewBuilder
    private var iconView: some View {
        if model.isBurning {
            let frames = model.currentFlameFrames
            if !frames.isEmpty {
                Image(nsImage: frames[model.flameFrame % frames.count])
                    .frame(width: 15, height: 15)
            }
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            iconView
            Text("今天").font(.system(size: 8)).foregroundStyle(.white.opacity(0.55))
            Text(tokensText)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(costText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            Rectangle().fill(.white.opacity(0.15)).frame(width: 26, height: 1)
            Text(bottomText)
                .font(.system(size: 8, weight: model.isBurning ? .semibold : .regular))
                .foregroundStyle(model.isBurning ? Color.orange : Color.white.opacity(0.55))
        }
        .frame(width: 64, height: 176)
    }
}

/// 导轨面板内容：全高融合形状 + 舱体内容（带拖拽/点击手势）
struct RailView: View {
    @ObservedObject var controller: SideDockController
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RailShape(mode: controller.currentMode,
                          barY: controller.barY,
                          fuse: controller.fuse,
                          showBar: controller.showBar)
                    .fill(Color(white: 0.08).opacity(0.94))
                if controller.showBar {
                    DockContentView()
                        .position(x: geo.size.width / 2, y: controller.barY)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { v in
                                    if !controller.floating { controller.beginFloat() }
                                    controller.moveFloat(translation: v.translation)
                                }
                        )
                        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
                        .onTapGesture { controller.showDetail(model: model) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 浮块面板内容：独立圆角矩形 + 投影
struct FloatView: View {
    @ObservedObject var controller: SideDockController
    @EnvironmentObject var model: AppModel

    var body: some View {
        DockContentView()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.08).opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
            .contentShape(Rectangle())
            .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
