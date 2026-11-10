#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 侧边悬浮坞：停靠屏幕左/右边缘的竖条 glance 视图；点击弹出完整面板窗口。
/// 解决菜单栏空间被其他 App 挤压的问题。
@MainActor
final class SideDockController {
    private var dock: NSPanel?
    private var detail: NSWindow?
    private var screenObserver: NSObjectProtocol?

    func apply(mode: String, model: AppModel) {
        dock?.orderOut(nil)
        dock = nil
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
        guard mode == "left" || mode == "right" else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 76, height: 176),
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
            SideDockView(mode: mode, onTap: { [weak self, weak model] in
                guard let self, let model else { return }
                self.showDetail(model: model)
            })
            .environmentObject(model))
        place(panel, mode)
        panel.orderFrontRegardless()
        dock = panel

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak panel] _ in
                guard let panel else { return }
                Task { @MainActor in
                    Self.placeStatic(panel, mode)
                }
            }
    }

    private func place(_ panel: NSPanel, _ mode: String) {
        Self.placeStatic(panel, mode)
    }

    @MainActor
    private static func placeStatic(_ panel: NSPanel, _ mode: String) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let w: CGFloat = 76
        let h: CGFloat = 176
        // 贴边吸附：不留间隙
        let x = mode == "left" ? vf.minX : vf.maxX - w
        let y = vf.midY - h / 2
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
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

    /// 贴边圆角：靠右屏边时圆左侧两角，反之圆右侧两角
    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = 18
        return mode == "left"
            ? UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r)
            : UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0)
    }

    var body: some View {
        let s = model.summariesByRange[.today]
        let tokens = s.map { model.includeCache ? $0.counts.total : $0.counts.input + $0.counts.output } ?? 0

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
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(width: 76, height: 176)
        .background(shape.fill(Color(white: 0.08).opacity(0.94)))
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .contentShape(shape)
        .onTapGesture(perform: onTap)
    }
}
#endif
