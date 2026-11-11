#if os(macOS)
import SwiftUI
import AppKit
import TokenMeterCore

/// 独立设置窗口内容（从状态栏面板拆出）
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                appearanceCard
                dockCard
                budgetCard
                dockSourcesCard
                pricingCard
                aboutCard
            }
            .padding(18)
        }
        .frame(width: 460, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 外观

    private var appearanceCard: some View {
        card("外观") {
            HStack(spacing: 9) {
                Text("主题色").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                ForEach(AppTheme.all) { t in
                    Button { model.themeID = t.id } label: {
                        Circle()
                            .fill(t.primary)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(model.themeID == t.id ? Color.primary.opacity(0.75) : .clear,
                                                      lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(t.name)
                }
                Spacer()
            }
            HStack(spacing: 9) {
                Text("菜单栏显示").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                Picker("菜单栏显示", selection: Binding(get: { model.menuBarStyle }, set: { model.menuBarStyle = $0 })) {
                    Text("用量 + 费用").tag("both")
                    Text("仅用量").tag("tokens")
                    Text("仅费用").tag("cost")
                    Text("仅图标").tag("icon")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
            }
            Toggle("登录时自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
        }
    }

    // MARK: - 悬浮坞

    private var dockCard: some View {
        card("侧边悬浮坞") {
            HStack(spacing: 9) {
                Text("位置").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                Picker("位置", selection: Binding(get: { model.sideDock }, set: { model.sideDock = $0 })) {
                    Text("关闭").tag("off")
                    Text("左侧").tag("left")
                    Text("右侧").tag("right")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
            }
            Text("开启后可从屏幕边缘拖出，松手自动吸附；双击回到默认位置，单击展开面板。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 预算

    private var budgetCard: some View {
        card("预算提醒") {
            budgetRow(label: "每日", value: Binding(get: { model.dailyBudget }, set: { model.dailyBudget = $0 }),
                      cost: model.summariesByRange[.today]?.cost)
            budgetRow(label: "每月", value: Binding(get: { model.monthlyBudget }, set: { model.monthlyBudget = $0 }),
                      cost: model.summariesByRange[.thisMonth]?.cost)
            Text("达到 80% 和 100% 时发送系统通知；填 0 表示不提醒。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func budgetRow(label: String, value: Binding<Double>, cost: Double?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 32, alignment: .leading)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .font(.caption)
            Text("USD").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let cost, value.wrappedValue > 0 {
                let over = cost >= value.wrappedValue
                Text("\(Fmt.cost(cost)) / \(Fmt.cost(value.wrappedValue))")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(over ? Color.red : Color.secondary)
                ProgressView(value: min(1, cost / value.wrappedValue))
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .tint(over ? Color.red : model.theme.primary)
            } else {
                Text("今日 \(Fmt.cost(cost ?? 0))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 坞内展示源

    private var dockSourcesCard: some View {
        card("悬浮坞显示的工具") {
            Toggle("显示工具状态", isOn: Binding(get: { model.dockShowHarness }, set: { model.dockShowHarness = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
            if model.dockShowHarness {
                Text("点名称可隐藏，灰色为当前不显示。")
                    .font(.caption2).foregroundStyle(.tertiary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                    ForEach(model.sourceStates, id: \.0) { name, _ in
                        sourceChip(name)
                    }
                }
            }
        }
    }

    private func sourceChip(_ name: String) -> some View {
        let hidden = model.hiddenDockSources.contains(name)
        return Button {
            if hidden { model.hiddenDockSources.remove(name) }
            else { model.hiddenDockSources.insert(name) }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(hidden ? Color.secondary.opacity(0.35) : model.theme.primary)
                    .frame(width: 5, height: 5)
                Text(name).font(.caption2).lineLimit(1)
                    .foregroundStyle(hidden ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hidden ? Color.primary.opacity(0.04) : model.theme.primary.opacity(0.12))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(hidden ? "点击显示" : "点击隐藏")
    }

    // MARK: - 价格

    private var pricingCard: some View {
        card("模型价格") {
            PriceEditorView()
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        card("关于") {
            HStack(spacing: 8) {
                Text("TokenMeter v\(UpdateKit.currentVersion())").font(.caption)
                Spacer()
                Button("检查更新") { model.checkForUpdates(force: true) }
                    .font(.caption)
                Button("打开数据目录") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ScanCache.cacheDir.path)
                }
                .font(.caption)
            }
            Text("所有数据均来自本机日志，不会上传到任何服务器。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 卡片容器

    @ViewBuilder
    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

/// 独立设置窗口
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func close() { window?.close() }

    func show(model: AppModel) {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            win.title = "TokenMeter 设置"
            win.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
