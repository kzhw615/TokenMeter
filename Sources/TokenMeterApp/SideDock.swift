#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 舱体形状：内侧两角恒圆角；外侧（贴屏边）两角半径可动画——
/// 浮块态 16（完整圆角矩形），贴边态 0（方角融进屏边）
struct BarShape: Shape {
    let side: String          // "left" / "right"：哪侧贴屏边
    var outerR: CGFloat       // 贴边侧圆角半径（0 = 融合）
    var innerR: CGFloat = 16

    var animatableData: CGFloat {
        get { outerR }
        set { outerR = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let tl = side == "left" ? outerR : innerR
        let tr = side == "right" ? outerR : innerR
        let bl = side == "left" ? outerR : innerR
        let br = side == "right" ? outerR : innerR
        var p = Path()
        p.move(to: CGPoint(x: tl, y: 0))
        p.addLine(to: CGPoint(x: w - tr, y: 0))
        if tr > 0 { p.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) } else { p.addLine(to: CGPoint(x: w, y: 0)) }
        p.addLine(to: CGPoint(x: w, y: h - br))
        if br > 0 { p.addArc(center: CGPoint(x: w - br, y: h - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) } else { p.addLine(to: CGPoint(x: w, y: h)) }
        p.addLine(to: CGPoint(x: bl, y: h))
        if bl > 0 { p.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) } else { p.addLine(to: CGPoint(x: 0, y: h)) }
        p.addLine(to: CGPoint(x: 0, y: tl))
        if tl > 0 { p.addArc(center: CGPoint(x: tl, y: tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) } else { p.addLine(to: CGPoint(x: 0, y: 0)) }
        p.closeSubpath()
        return p
    }
}

/// 侧边悬浮坞：单窗口。拖动=独立圆角浮块（带投影）；松手=滑向较近屏边，
/// 外侧圆角 16→0 形变"融入"屏边；位置/侧别记忆；双击回位；单击弹面板
@MainActor
final class SideDockController: ObservableObject {
    static let barSize = NSSize(width: 64, height: 132)

    @Published var attached: Bool = true
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
        attached = true

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

        // 拖动开始（窗口移动）→ 脱离贴边态
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.snapping, self.attached else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        self.attached = false
                    }
                }
            }

        // 松手（本 App 内或别的 App 上）→ 吸附
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.attached, !self.snapping else { return }
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

    /// 松手：按中心距离吸附到较近屏边；水平滑动 + 外角 16→0 形变融合
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
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.side = newSide
                    self.attached = true     // 外角 16→0：融入屏边
                }
                self.save(side: newSide, originY: targetY)
            }
        })
    }

    func resetPosition(mode: String) {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let o = originFor(side: mode, vf: vf, saved: false)
        panel.setFrameOrigin(o)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.side = mode
            self.attached = true
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

    private var shape: BarShape {
        BarShape(side: controller.side, outerR: controller.attached ? 0 : 16)
    }

    var body: some View {
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
        .background(shape.fill(Color(white: 0.08).opacity(0.94)))
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(controller.attached ? 0 : 0.35), radius: 12, x: 0, y: 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.resetPosition(mode: model.sideDock == "left" ? "left" : "right") }
        .onTapGesture { controller.showDetail(model: model) }
    }
}
#endif
