#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 贴边融合形态：舱体上下沿以凹曲线向屏边渐隐收尖（CodeBurn 式融合，无导轨、无直角切口）
struct FlareShape: Shape {
    let side: String       // "left" / "right"
    var wing: CGFloat = 18 // 喇叭口高度

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let f = wing
        let r: CGFloat = 16
        let oy = f            // 舱体顶
        let ob = h - f        // 舱体底
        if side == "right" {
            p.move(to: CGPoint(x: w, y: 0))
            p.addCurve(to: CGPoint(x: w - f, y: oy),
                       control1: CGPoint(x: w, y: oy * 0.45),
                       control2: CGPoint(x: w - f * 0.75, y: oy))
            p.addLine(to: CGPoint(x: r, y: oy))
            p.addQuadCurve(to: CGPoint(x: 0, y: oy + r), control: CGPoint(x: 0, y: oy))
            p.addLine(to: CGPoint(x: 0, y: ob - r))
            p.addQuadCurve(to: CGPoint(x: r, y: ob), control: CGPoint(x: 0, y: ob))
            p.addLine(to: CGPoint(x: w - f, y: ob))
            p.addCurve(to: CGPoint(x: w, y: h),
                       control1: CGPoint(x: w - f * 0.75, y: ob),
                       control2: CGPoint(x: w, y: ob + (h - ob) * 0.55))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addCurve(to: CGPoint(x: f, y: oy),
                       control1: CGPoint(x: 0, y: oy * 0.45),
                       control2: CGPoint(x: f * 0.75, y: oy))
            p.addLine(to: CGPoint(x: w - r, y: oy))
            p.addQuadCurve(to: CGPoint(x: w, y: oy + r), control: CGPoint(x: w, y: oy))
            p.addLine(to: CGPoint(x: w, y: ob - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: ob), control: CGPoint(x: w, y: ob))
            p.addLine(to: CGPoint(x: f, y: ob))
            p.addCurve(to: CGPoint(x: 0, y: h),
                       control1: CGPoint(x: f * 0.75, y: ob),
                       control2: CGPoint(x: 0, y: ob + (h - ob) * 0.55))
            p.closeSubpath()
        }
        return p
    }
}

/// 侧边悬浮坞：单窗口。拖动=独立圆角浮块；松手=滑向较近屏边并 cross-fade 成贴边融合形态；
/// 位置/侧别记忆；双击回位；单击弹面板。四角完全透明（无投影 haze）
@MainActor
final class SideDockController: ObservableObject {
    static let barSize = NSSize(width: 64, height: 168)   // 含上下 wing 18

    @Published var fuse: CGFloat = 1     // 0 = 浮块圆角矩形，1 = 贴边融合
    @Published var side: String = "right"

    private var panel: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var mouseUpLocal: Any?
    private var mouseUpGlobal: Any?
    private var snapping = false

    func apply(mode: String, model: AppModel) {
        teardown()
        guard mode == "left" || mode == "right" else { return }
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        side = UserDefaults.standard.string(forKey: "dockSide") ?? mode
        fuse = 1

        let panel = NSPanel(
            contentRect: NSRect(origin: originFor(side: side, vf: vf, saved: true), size: Self.barSize),
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
                    self.apply(mode: model.sideDock, model: model)
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

    /// 松手：按中心距离吸附到较近屏边；水平滑动 + 形态 cross-fade 融合
    func snap() {
        guard let panel, let screen = NSScreen.main else { return }
        snapping = true
        let vf = screen.visibleFrame
        let newSide = panel.frame.midX < vf.midX ? "left" : "right"
        let targetX = newSide == "left" ? vf.minX : vf.maxX - Self.barSize.width
        let targetY = min(max(panel.frame.origin.y, vf.minY), vf.maxY - Self.barSize.height)
        let target = NSPoint(x: targetX, y: targetY)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(target)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                panel.setFrameOrigin(target)
                self.snapping = false
                self.side = newSide
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.fuse = 1      // 圆角浮块淡入为贴边融合形态
                }
                self.save(side: newSide, originY: targetY)
            }
        })
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
                    .frame(width: 15, height: 15)
            }
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    var body: some View {
        let ink = Color(white: 0.08).opacity(0.94)
        return ZStack {
            // 浮块态：完整圆角矩形（上下留 wing 空间，与融合态同框）
            RoundedRectangle(cornerRadius: 16)
                .fill(ink)
                .padding(.vertical, 18)
                .opacity(Double(1 - controller.fuse))
            // 贴边态：喇叭口融合形态
            FlareShape(side: controller.side)
                .fill(ink)
                .opacity(Double(controller.fuse))
            VStack(spacing: 4) {
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
                Rectangle().fill(.white.opacity(0.15)).frame(width: 24, height: 1)
                Text(bottomText)
                    .font(.system(size: 8, weight: model.isBurning ? .semibold : .regular))
                    .foregroundStyle(model.isBurning ? Color.orange : Color.white.opacity(0.55))
            }
            .frame(width: 64, height: 132)
        }
        .frame(width: 64, height: 168)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
        .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
