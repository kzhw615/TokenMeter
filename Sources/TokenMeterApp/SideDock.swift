#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 贴边吸附形状：边缘侧上下各一段凹弧外扩翼（CodeBurn 式融合），内侧圆角
struct DockShape: Shape {
    let mode: String   // "left" / "right"
    var wing: CGFloat = 22
    var radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let f = wing, r = radius
        if mode == "right" {
            // 贴右边：翼在右侧上下外扩
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
            // 贴左边：镜像
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

/// 侧边悬浮坞：贴边吸附竖条 glance；可拖动、位置记忆；点击弹完整面板窗口
@MainActor
final class SideDockController {
    static let size = NSSize(width: 76, height: 220)

    private var dock: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var dragStart: NSPoint?

    func apply(mode: String, model: AppModel) {
        dock?.orderOut(nil)
        dock = nil
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
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
        panel.contentView = NSHostingView(rootView:
            SideDockView(
                mode: mode,
                onTap: { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.showDetail(model: model)
                },
                onDrag: { [weak self] translation in
                    self?.dragPanel(translation: translation)
                },
                onDragEnd: { [weak self] in
                    self?.endDrag()
                },
                onReset: { [weak self] in
                    self?.resetPosition(mode: mode)
                })
            .environmentObject(model))
        panel.setFrameOrigin(initialOrigin(mode: mode))
        panel.orderFrontRegardless()
        dock = panel

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
        if let screen = NSScreen.main, savedX.isFinite, savedY.isFinite,
           UserDefaults.standard.object(forKey: "dockX") != nil {
            let pt = NSPoint(x: savedX, y: savedY)
            if screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(pt) { return pt }
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

    func dragPanel(translation: CGSize) {
        guard let panel = dock else { return }
        if dragStart == nil { dragStart = panel.frame.origin }
        guard let start = dragStart else { return }
        // SwiftUI translation y 向下为正，AppKit y 向上为正
        let target = NSPoint(x: start.x + translation.width, y: start.y - translation.height)
        panel.setFrameOrigin(clamped(target, mode: panel.frame.origin.x < (NSScreen.main?.visibleFrame.midX ?? 0) ? "left" : "right"))
    }

    func endDrag() {
        guard let panel = dock else { return }
        dragStart = nil
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: "dockX")
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: "dockY")
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
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void
    let onReset: () -> Void

    var body: some View {
        let s = model.summariesByRange[.today]
        let tokens = s.map { model.includeCache ? $0.counts.total : $0.counts.input + $0.counts.output } ?? 0
        let shape = DockShape(mode: mode)

        VStack(spacing: 7) {
            if model.isBurning {
                let frames = model.currentFlameFrames
                if !frames.isEmpty {
                    Image(nsImage: frames[model.flameFrame % frames.count])
                        .frame(width: 18, height: 18)
                }
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text("今天").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            Text(Fmt.compactTokens(tokens))
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(Fmt.cost(s?.cost ?? 0))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            Rectangle().fill(.white.opacity(0.15)).frame(width: 32, height: 1)
            if model.isBurning, let rate = model.burnRate, rate > 0 {
                Text("\(Fmt.compactTokens(rate))/s")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(Fmt.percent(s?.cacheHitRate ?? 0))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.vertical, 30)   // 上下留给外扩翼
        .padding(.horizontal, 6)
        .frame(width: 76, height: 220)
        .background(shape.fill(Color(white: 0.08).opacity(0.94)))
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDragEnd() }
        )
        .onTapGesture(count: 2, perform: onReset)
        .onTapGesture(perform: onTap)
    }
}
#endif
