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
            contentRect: NSRect(x: 0, y: 0, width: 76, height: 320),
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
            SideDockView(onTap: { [weak self, weak model] in
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
        let h: CGFloat = 320
        let x = mode == "left" ? vf.minX + 6 : vf.maxX - w - 6
        let y = vf.midY - h / 2
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    func showDetail(model: AppModel) {
        if detail == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
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
    let onTap: () -> Void

    var body: some View {
        let s = model.summariesByRange[.today]
        let tokens = s.map { model.includeCache ? $0.counts.total : $0.counts.input + $0.counts.output } ?? 0
        let week = (s?.trendDays.suffix(7) ?? [])
        let weekMax = max(1, week.map { model.includeCache ? $0.counts.total : $0.counts.input + $0.counts.output }.max() ?? 1)

        VStack(spacing: 6) {
            if model.isBurning {
                let frames = model.currentFlameFrames
                if !frames.isEmpty {
                    Image(nsImage: frames[model.flameFrame % frames.count])
                        .frame(width: 16, height: 16)
                }
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Text("今天").font(.system(size: 9)).foregroundStyle(.secondary)
            Text(Fmt.compactTokens(tokens))
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(Fmt.cost(s?.cost ?? 0))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 2)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, d in
                    let v = model.includeCache ? d.counts.total : d.counts.input + d.counts.output
                    Capsule()
                        .fill(model.theme.primary.opacity(0.35 + 0.65 * Double(v) / Double(weekMax)))
                        .frame(width: max(3, 48 * CGFloat(Double(v) / Double(weekMax))), height: 4)
                }
            }
            .frame(width: 48, alignment: .leading)
            Spacer(minLength: 2)

            if model.isBurning, let rate = model.burnRate, rate > 0 {
                Text("\(Fmt.compactTokens(rate))/s")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(Fmt.percent(s?.cacheHitRate ?? 0))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: 76, height: 320)
        .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: onTap)
    }
}
#endif
