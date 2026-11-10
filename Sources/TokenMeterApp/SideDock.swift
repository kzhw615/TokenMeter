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
    var barInsetY: CGFloat = 28  // 上下内缩（可见高度 = h - 2*barInsetY）
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
        let ob = h - barInsetY       // 舱体底
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

/// 侧边悬浮坞：单窗口。拖动=独立圆角浮块；松手=滑向较近屏边并 cross-fade 成贴边融合形态；
/// 位置/侧别记忆；双击回位；单击弹面板。四角完全透明（无投影 haze）
@MainActor
final class SideDockController: ObservableObject {
    static let barSize = NSSize(width: 64, height: 168)   // 面板恒定；可见舱体由形状内缩参数控制

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
        fuse = 1

        let panel = NSPanel(
            contentRect: NSRect(origin: originFor(side: side, vf: vf, saved: useSaved), size: Self.barSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView:
            SideDockView(controller: self).environmentObject(model))
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
    func snap() {
        guard let panel, let screen = NSScreen.main else { return }
        snapping = true
        let vf = screen.visibleFrame
        let newSide = panel.frame.midX < vf.midX ? "left" : "right"
        let targetX = newSide == "left" ? vf.minX : vf.maxX - Self.barSize.width
        let targetY = min(max(panel.frame.origin.y, vf.minY), vf.maxY - Self.barSize.height)
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
        guard let panel, let screen = NSScreen.main else { return }
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
        let x = side == "left" ? vf.minX : vf.maxX - Self.barSize.width
        var y = vf.midY - Self.barSize.height / 2
        if saved, let sy = UserDefaults.standard.object(forKey: "dockY") as? Double {
            y = min(max(sy, vf.minY), vf.maxY - Self.barSize.height)
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
            win.contentView = NSHostingView(rootView: PanelView().environmentObject(model))
            win.isReleasedWhenClosed = false
            detail = win
        }
        detail?.center()
        detail?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SideDockView: View {
    @ObservedObject var controller: SideDockController
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
                    .frame(width: 13, height: 13)
            }
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    var body: some View {
        let ink = Color.black
        return VStack(spacing: 3) {
            iconView
            Text("今天").font(.system(size: 7)).foregroundStyle(.white.opacity(0.55))
            Text(tokensText)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(costText)
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            Rectangle().fill(.white.opacity(0.15)).frame(width: 20, height: 1)
            Text(bottomText)
                .font(.system(size: 7, weight: model.isBurning ? .semibold : .regular))
                .foregroundStyle(model.isBurning ? Color.orange : Color.white.opacity(0.55))
        }
        .frame(width: 56, height: 112)
        .frame(width: 64, height: 168, alignment: controller.side == "right" ? .trailing : .leading)
        .background(BarFlareShape(side: controller.side, fuse: controller.fuse).fill(ink))
        .overlay(BarFlareShape(side: controller.side, fuse: controller.fuse).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
        .frame(width: 64, height: 168)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
        .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
