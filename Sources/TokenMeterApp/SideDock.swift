#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// CodeBurn 式贴边融合形状：沿屏边一条全高窄条 + 主体圆角条 + 凹圆角过渡（融化进墙里）
struct DockShape: Shape {
    let mode: String          // "left" / "right"：窄条靠哪边
    var strip: CGFloat = 9    // 贴边窄条宽度
    var wing: CGFloat = 20    // 凹过渡圆角半径
    var radius: CGFloat = 16  // 主体内侧圆角

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let s = strip, f = wing, r = radius
        if mode == "right" {
            p.move(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w - s, y: 0))
            p.addQuadCurve(to: CGPoint(x: w - s - f, y: f), control: CGPoint(x: w - s, y: f))
            p.addLine(to: CGPoint(x: r, y: f))
            p.addQuadCurve(to: CGPoint(x: 0, y: f + r), control: CGPoint(x: 0, y: f))
            p.addLine(to: CGPoint(x: 0, y: h - f - r))
            p.addQuadCurve(to: CGPoint(x: r, y: h - f), control: CGPoint(x: 0, y: h - f))
            p.addLine(to: CGPoint(x: w - s - f, y: h - f))
            p.addQuadCurve(to: CGPoint(x: w - s, y: h), control: CGPoint(x: w - s, y: h - f))
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: s, y: 0))
            p.addQuadCurve(to: CGPoint(x: s + f, y: f), control: CGPoint(x: s, y: f))
            p.addLine(to: CGPoint(x: w - r, y: f))
            p.addQuadCurve(to: CGPoint(x: w, y: f + r), control: CGPoint(x: w, y: f))
            p.addLine(to: CGPoint(x: w, y: h - f - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h - f), control: CGPoint(x: w, y: h - f))
            p.addLine(to: CGPoint(x: s + f, y: h - f))
            p.addQuadCurve(to: CGPoint(x: s, y: h), control: CGPoint(x: s, y: h - f))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
        return p
    }
}

/// 侧边悬浮坞：贴边融合黑坞；可拖动，松手按距离自动吸附左/右边；位置记忆；双击回位；点击弹面板
@MainActor
final class SideDockController: ObservableObject {
    static let size = NSSize(width: 64, height: 176)

    @Published var currentMode: String = "right"

    private var dock: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var snapWork: DispatchWorkItem?
    private var clamping = false

    func apply(mode: String, model: AppModel) {
        dock?.orderOut(nil)
        dock = nil
        snapWork?.cancel()
        for obs in [screenObserver, moveObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(obs)
        }
        screenObserver = nil
        moveObserver = nil
        guard mode == "left" || mode == "right" else { return }
        currentMode = mode

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView:
            SideDockView(controller: self)
                .environmentObject(model))
        let start = initialOrigin(mode: mode)
        currentMode = start.mode
        panel.setFrameOrigin(start.origin)
        panel.orderFrontRegardless()
        dock = panel

        // 拖动中持续记忆；停止 0.3s 后自动吸附到较近的一边
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.dock, !self.clamping else { return }
                    let o = panel.frame.origin
                    UserDefaults.standard.set(Double(o.x), forKey: "dockX")
                    UserDefaults.standard.set(Double(o.y), forKey: "dockY")
                    self.snapWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        Task { @MainActor [weak self] in self?.snapToNearestEdge() }
                    }
                    self.snapWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.dock else { return }
                    panel.setFrameOrigin(self.clamped(panel.frame.origin))
                }
            }
    }

    /// 松手后：按坞中心与屏幕中线距离吸附到左/右边缘（x 贴边，y 保持），形状朝向随之翻转
    func snapToNearestEdge() {
        guard let panel = dock, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let center = panel.frame.midX
        let mode = center < vf.midX ? "left" : "right"
        let targetX = mode == "left" ? vf.minX : vf.maxX - Self.size.width
        var target = panel.frame.origin
        target.x = targetX
        target.y = min(max(target.y, vf.minY), vf.maxY - Self.size.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(target)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.dock else { return }
                panel.setFrameOrigin(target)   // 兜底：动画失效也保证到位
                self.currentMode = mode
                UserDefaults.standard.set(Double(target.x), forKey: "dockX")
                UserDefaults.standard.set(Double(target.y), forKey: "dockY")
            }
        })
        currentMode = mode
    }

    private func initialOrigin(mode: String) -> (origin: NSPoint, mode: String) {
        guard let screen = NSScreen.main else { return (.zero, mode) }
        let vf = screen.visibleFrame
        let savedX = UserDefaults.standard.double(forKey: "dockX")
        let savedY = UserDefaults.standard.double(forKey: "dockY")
        var side = mode
        var y = vf.midY - Self.size.height / 2
        if UserDefaults.standard.object(forKey: "dockX") != nil {
            let savedCenter = savedX + Self.size.width / 2
            side = savedCenter < vf.midX ? "left" : "right"
            y = min(max(savedY, vf.minY), vf.maxY - Self.size.height)
        }
        let x = side == "left" ? vf.minX : vf.maxX - Self.size.width
        return (NSPoint(x: x, y: y), side)
    }

    private func defaultOrigin(mode: String) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let x = mode == "left" ? vf.minX : vf.maxX - Self.size.width
        return NSPoint(x: x, y: vf.midY - Self.size.height / 2)
    }

    private func clamped(_ origin: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return origin }
        let vf = screen.visibleFrame.insetBy(dx: -20, dy: 0)
        var o = origin
        o.x = min(max(o.x, vf.minX - 30), vf.maxX - Self.size.width + 30)
        o.y = min(max(o.y, vf.minY), vf.maxY - Self.size.height)
        return o
    }

    /// 双击回位：设置侧贴边垂直居中
    func resetPosition(mode: String) {
        guard let panel = dock else { return }
        panel.setFrameOrigin(defaultOrigin(mode: mode))
        currentMode = mode
        UserDefaults.standard.removeObject(forKey: "dockX")
        UserDefaults.standard.removeObject(forKey: "dockY")
    }

    func showDetail(model: AppModel) {
        if detail == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
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
                    .frame(width: 15, height: 15)
            }
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var content: some View {
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
        .padding(.vertical, 26)
        .padding(.horizontal, 4)
    }

    private var shaped: some View {
        content
            .frame(width: 64, height: 176)
            .background(DockShape(mode: controller.currentMode).fill(Color(white: 0.08).opacity(0.94)))
            .overlay(DockShape(mode: controller.currentMode).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    var body: some View {
        shaped
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
            .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
