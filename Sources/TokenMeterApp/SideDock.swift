#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 贴边吸附形状：边缘侧上下各一段凹弧外扩翼（CodeBurn 式融合），内侧圆角
struct DockShape: Shape {
    let mode: String   // "left" / "right"
    var wing: CGFloat = 15
    var radius: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let f = wing, r = radius
        if mode == "right" {
            p.move(to: CGPoint(x: w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w - f, y: f), control: CGPoint(x: w - f, y: 0))
            p.addLine(to: CGPoint(x: r, y: f))
            p.addQuadCurve(to: CGPoint(x: 0, y: f + r), control: CGPoint(x: 0, y: f))
            p.addLine(to: CGPoint(x: 0, y: h - f - r))
            p.addQuadCurve(to: CGPoint(x: r, y: h - f), control: CGPoint(x: 0, y: h - f))
            p.addLine(to: CGPoint(x: w - f, y: h - f))
            p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - f, y: h - f))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
            p.addLine(to: CGPoint(x: w - r, y: f))
            p.addQuadCurve(to: CGPoint(x: w, y: f + r), control: CGPoint(x: w, y: f))
            p.addLine(to: CGPoint(x: w, y: h - f - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h - f), control: CGPoint(x: w, y: h - f))
            p.addLine(to: CGPoint(x: f, y: h - f))
            p.addQuadCurve(to: CGPoint(x: 0, y: h), control: CGPoint(x: f, y: h - f))
            p.closeSubpath()
        }
        return p
    }
}

/// 侧边悬浮坞：CodeBurn 式贴边融合黑坞；可拖动（原生窗口拖拽）+ 位置记忆 + 双击回位；点击弹完整面板
@MainActor
final class SideDockController {
    static let size = NSSize(width: 62, height: 168)

    private var dock: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var clamping = false

    func apply(mode: String, model: AppModel) {
        dock?.orderOut(nil)
        dock = nil
        for obs in [screenObserver, moveObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(obs)
        }
        screenObserver = nil
        moveObserver = nil
        guard mode == "left" || mode == "right" else { return }

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
        panel.isMovableByWindowBackground = true   // 原生窗口拖拽
        panel.contentView = NSHostingView(rootView:
            SideDockView(
                mode: mode,
                onTap: { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.showDetail(model: model)
                },
                onReset: { [weak self] in
                    self?.resetPosition(mode: mode)
                })
            .environmentObject(model))
        panel.setFrameOrigin(initialOrigin(mode: mode))
        panel.orderFrontRegardless()
        dock = panel

        // 拖动后记忆位置 + 边界钳制
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.dock, !self.clamping else { return }
                    let o = panel.frame.origin
                    UserDefaults.standard.set(Double(o.x), forKey: "dockX")
                    UserDefaults.standard.set(Double(o.y), forKey: "dockY")
                    let c = self.clamped(o, mode: mode)
                    if abs(c.x - o.x) > 0.5 || abs(c.y - o.y) > 0.5 {
                        self.clamping = true
                        panel.setFrameOrigin(c)
                        self.clamping = false
                    }
                }
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let panel = self.dock else { return }
                    panel.setFrameOrigin(self.clamped(panel.frame.origin, mode: mode))
                }
            }
    }

    /// 记忆位置优先；否则贴边垂直居中
    private func initialOrigin(mode: String) -> NSPoint {
        let savedX = UserDefaults.standard.double(forKey: "dockX")
        let savedY = UserDefaults.standard.double(forKey: "dockY")
        if let screen = NSScreen.main,
           UserDefaults.standard.object(forKey: "dockX") != nil,
           screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(NSPoint(x: savedX, y: savedY)) {
            return NSPoint(x: savedX, y: savedY)
        }
        return defaultOrigin(mode: mode)
    }

    private func defaultOrigin(mode: String) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let x = mode == "left" ? vf.minX : vf.maxX - Self.size.width
        return NSPoint(x: x, y: vf.midY - Self.size.height / 2)
    }

    private func clamped(_ origin: NSPoint, mode: String) -> NSPoint {
        guard let screen = NSScreen.main else { return origin }
        let vf = screen.visibleFrame.insetBy(dx: -20, dy: 0)
        var o = origin
        o.x = min(max(o.x, vf.minX - 30), vf.maxX - Self.size.width + 30)
        o.y = min(max(o.y, vf.minY), vf.maxY - Self.size.height)
        return o
    }

    /// 双击回位：贴边垂直居中
    func resetPosition(mode: String) {
        guard let panel = dock else { return }
        panel.setFrameOrigin(defaultOrigin(mode: mode))
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
    @EnvironmentObject var model: AppModel
    let mode: String
    let onTap: () -> Void
    let onReset: () -> Void

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
        .padding(.vertical, 22)   // 上下留给外扩翼
        .padding(.horizontal, 4)
    }

    private var shaped: some View {
        content
            .frame(width: 62, height: 168)
            .background(DockShape(mode: mode).fill(Color(white: 0.08).opacity(0.94)))
            .overlay(DockShape(mode: mode).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    var body: some View {
        shaped
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onReset)
            .onTapGesture(perform: onTap)
    }
}
#endif
