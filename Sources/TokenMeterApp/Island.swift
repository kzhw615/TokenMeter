#if os(macOS)
import SwiftUI
import AppKit
import Combine
import TokenMeterCore

// MARK: - 液态玻璃外观

/// 液态玻璃底：半透明材质 + 顶部高光 + 虹彩描边 + 外投影。
/// macOS 14 没有系统级 Liquid Glass API，这里用材质叠层近似同一观感。
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .clear
    var opacity: Double = 1

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.30), .white.opacity(0.05), .white.opacity(0.14)],
                        startPoint: .top, endPoint: .bottom)
                )
                .blendMode(.plusLighter)
                .opacity(0.55)
            )
            .overlay(
                shape.fill(
                    LinearGradient(colors: [tint.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                )
            )
            // 虹彩边缘：模拟玻璃折射出的彩色细线
            .overlay(
                shape.strokeBorder(
                    AngularGradient(
                        colors: [.white.opacity(0.55), .cyan.opacity(0.35), .white.opacity(0.18),
                                 .purple.opacity(0.30), .white.opacity(0.50)],
                        center: .center),
                    lineWidth: 0.8)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
            .shadow(color: tint.opacity(0.25), radius: 20)
            .opacity(opacity)
    }
}

extension View {
    /// 面板/卡片的玻璃底
    func glassBackground(cornerRadius: CGFloat = 18, tint: Color = .clear) -> some View {
        background(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                tint: tint))
    }
}

// MARK: - 顶部灵动岛

@MainActor
final class IslandController: NSObject {
    private let model: AppModel
    private let actions: AppActions
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var anchorProvider: () -> NSRect

    static let size = NSSize(width: 262, height: 42)

    init(model: AppModel, actions: AppActions, anchor: @escaping () -> NSRect) {
        self.model = model
        self.actions = actions
        self.anchorProvider = anchor
        super.init()
    }

    func setEnabled(_ on: Bool) {
        if on { apply() } else { teardown() }
    }

    /// 面板展开时先把岛藏起来，避免盖在面板上方
    func setHidden(_ hidden: Bool) {
        guard let panel else { return }
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func apply() {
        guard panel == nil else { reposition(); return }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.contentView = NSHostingView(rootView:
            IslandView(onOpen: { [weak self] in
                self?.actions.togglePanel()
            })
            .environmentObject(model))
        p.orderFrontRegardless()
        panel = p
        reposition()

        // 数据变化时重排（宽度固定，主要是为了不遮挡状态项）
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reposition() }
            .store(in: &cancellables)
    }

    private func teardown() {
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    /// 贴在菜单栏下方，与状态项水平居中对齐（不越出屏幕）
    func reposition() {
        guard let panel else { return }
        let anchor = anchorProvider()
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        guard let screen else { return }
        let vf = screen.visibleFrame
        let size = Self.size
        var x = anchor.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let y = vf.maxY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func showMenu() {
        guard let panel, let view = panel.contentView else { return }
        AppActions.shared.buildMenu(model: model).popUp(positioning: nil, at: .zero, in: view)
    }
}

/// 岛内容：火苗 + 速率 + 今日用量 + 预估费用
struct IslandView: View {
    @EnvironmentObject var model: AppModel
    let onOpen: () -> Void

    private var today: Summary? { model.summary }

    private var tokensText: String {
        guard let s = today else { return "—" }
        return Fmt.tokens(model.includeCache ? s.counts.total : s.counts.input + s.counts.output)
    }

    private var costText: String {
        guard let s = today else { return "" }
        return Fmt.cost(s.cost)
    }

    private var hitText: String {
        guard let s = today else { return "—" }
        return Fmt.percent(s.cacheHitRate)
    }

    private var rateText: String {
        guard model.isBurning else { return "空闲" }
        return Fmt.compactTokens(model.burnRate ?? 0) + "/s"
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if model.isBurning {
                    FlameIcon(ticker: model.flame, frames: model.currentFlameFrames, size: 22)
                } else {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rateText)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(model.isBurning ? AnyShapeStyle(model.theme.primary) : AnyShapeStyle(.secondary))
                    if model.isBurning {
                        Circle().fill(model.theme.primary).frame(width: 4, height: 4)
                            .opacity(0.9)
                    }
                }
                Text("今日")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // 中间补一个缓存命中率，避免胶囊中段大片留白
            VStack(spacing: 1) {
                Text(hitText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("缓存")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(tokensText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text(costText)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassSurface(shape: Capsule(style: .continuous), tint: model.theme.primary))
        .contentShape(Capsule())
        .onTapGesture(perform: onOpen)
        .contextMenu { menuItems }
        .help("点击打开 TokenMeter 面板")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("打开面板") { onOpen() }
        Button("刷新") { model.refresh() }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}
#endif
