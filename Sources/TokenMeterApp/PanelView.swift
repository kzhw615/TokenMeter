#if os(macOS)
import SwiftUI
import Charts
import TokenMeterCore

struct SlidingTabs<Option: Hashable>: View {
    let options: [(option: Option, label: String)]
    @Binding var selection: Option
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let selected = selection == opt.option
                Button {
                    guard !selected else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        selection = opt.option
                    }
                } label: {
                    Text(opt.label)
                        .font(.callout)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.16))
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var hoveredDay: String?
    @State private var hoveredHour: Int?

    private var palette: [Color] { model.theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.updateVisible, let v = model.latestVersion {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("新版本 v\(v) 可用").font(.caption)
                            switch model.updatePhase {
                            case .downloading:
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在下载更新…").font(.caption2).foregroundStyle(.secondary)
                                }
                            case .verifying:
                                Text("正在校验 sha256…").font(.caption2).foregroundStyle(.secondary)
                            case .installing:
                                Text("正在替换应用…").font(.caption2).foregroundStyle(.secondary)
                            case .restarting:
                                Text("即将重启…").font(.caption2).foregroundStyle(.secondary)
                            case .failed(let m):
                                Text(m).font(.caption2).foregroundStyle(.red)
                            case .idle:
                                EmptyView()
                            }
                        }
                        Spacer()
                        if model.canAutoUpdate {
                            Button(model.updateButtonTitle) { model.startUpdate() }
                                .buttonStyle(.borderless).font(.caption)
                                .disabled(model.updatePhase.busy)
                        }
                        Button("下载页") {
                            if let u = model.releaseURL { NSWorkspace.shared.open(u) }
                        }
                        .buttonStyle(.borderless).font(.caption)
                        Button(action: { model.dismissUpdate() }) {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
                if let s = model.summary {
                    summaryCards(s)
                    toolsSection(s)
                    modelsSection(s)
                    projectsSection(s)
                    trendSection(s)
                    hoursSection(s)
                    footnotes(s)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                themeRow
                footer
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.3), value: model.summary?.counts.total)
            .animation(.easeInOut(duration: 0.3), value: model.includeCache)
        }
        .frame(width: 430, height: 560)
    }

    // MARK: - 区块

    private var header: some View {
        HStack(spacing: 8) {
            Text("TokenMeter").font(.title3.bold())
            if model.isBurning {
                HStack(spacing: 3) {
                    let frames = model.currentFlameFrames
                    if !frames.isEmpty {
                        Image(nsImage: frames[model.flameFrame % frames.count])
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "flame.fill").foregroundStyle(.orange).font(.caption)
                    }
                    Text("燃烧中 \(model.burningSources.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
            }
            if model.updateVisible, let v = model.latestVersion {
                Button(action: {
                    if model.canAutoUpdate {
                        model.startUpdate()
                    } else if let u = model.releaseURL {
                        NSWorkspace.shared.open(u)
                    }
                }) {
                    Image(systemName: "arrow.down.circle.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("新版本 v\(v) 可用，点击一键更新")
            }
            Button(action: { confirmQuit() }) {
                Image(systemName: "power")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("退出 TokenMeter")
        }
    }

    /// 退出前弹窗确认，避免误点直接退出
    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "退出 TokenMeter？"
        alert.informativeText = "退出后菜单栏的用量显示与燃烧状态会停止更新；重新打开 App 即可恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    private func summaryCards(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SlidingTabs(
                options: RangeKind.allCases.map { (option: $0, label: $0.label) },
                selection: Binding(get: { model.range }, set: { model.setRange($0) })
            )

            SlidingTabs(
                options: [(option: true, label: "含缓存"), (option: false, label: "不含缓存")],
                selection: Binding(get: { model.includeCache }, set: { model.includeCache = $0 })
            )

            HStack(spacing: 0) {
                card(title: model.includeCache ? "用量（含缓存）" : "用量（不含缓存）",
                     value: Fmt.tokens(disp(s.counts)), unit: "tokens",
                     sub: "输入 \(Fmt.tokens(s.counts.input))\n输出 \(Fmt.tokens(s.counts.output))")
                Divider()
                card(title: "预估费用", value: Fmt.cost(s.cost), unit: "",
                     sub: "缓存读 \(Fmt.tokens(s.counts.cacheRead))\n缓存写 \(Fmt.tokens(s.counts.cacheWrite))")
                Divider()
                card(title: "缓存命中率", value: Fmt.percent(s.cacheHitRate), unit: "",
                     sub: "\(s.requests) 次调用")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(model.theme.cardTint))
            .animation(.easeInOut(duration: 0.3), value: model.summary?.counts.total)
        }
    }

    private func card(title: String, value: String, unit: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.bold()).monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(sub).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func toolsSection(_ s: Summary) -> some View {
        let totalDisp = s.tools.reduce(Int64(0)) { $0 + disp($1.counts) }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("按工具")
            if s.tools.isEmpty { emptyNote }
            ForEach(Array(s.tools.enumerated()), id: \.element.tool) { idx, t in
                HStack(spacing: 10) {
                    Text(t.tool).font(.callout).frame(width: 88, alignment: .leading).lineLimit(1)
                    bar(share: dispShare(t.counts, total: totalDisp), color: palette[idx % palette.count])
                    Text(Fmt.tokens(disp(t.counts))).font(.callout).monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 62, alignment: .trailing)
                    Text(Fmt.percent(dispShare(t.counts, total: totalDisp))).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                    Text(Fmt.cost(t.cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private func modelsSection(_ s: Summary) -> some View {
        let totalDisp = s.models.reduce(Int64(0)) { $0 + disp($1.counts) }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("按模型")
            if s.models.isEmpty { emptyNote }
            ForEach(Array(s.models.prefix(10).enumerated()), id: \.element.model) { idx, m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(m.model).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.tokens(disp(m.counts))).font(.callout).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(Fmt.percent(dispShare(m.counts, total: totalDisp))).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                        Text(Fmt.cost(m.cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                    bar(share: dispShare(m.counts, total: totalDisp), color: palette[idx % palette.count])
                        .frame(height: 3)
                    Text(m.tools.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func projectsSection(_ s: Summary) -> some View {
        let totalDisp = s.projects.reduce(Int64(0)) { $0 + disp($1.counts) }
        let list = Array(s.projects.filter { $0.project != "-" }.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("按项目")
            if list.isEmpty { emptyNote }
            ForEach(Array(list.enumerated()), id: \.element.project) { idx, p in
                HStack(spacing: 10) {
                    Text(p.project).font(.callout).frame(width: 110, alignment: .leading)
                        .lineLimit(1).truncationMode(.middle)
                    bar(share: dispShare(p.counts, total: totalDisp), color: palette[idx % palette.count])
                    Text(Fmt.tokens(disp(p.counts))).font(.callout).monospacedDigit()
                        .contentTransition(.numericText()).frame(width: 62, alignment: .trailing)
                    Text(Fmt.percent(dispShare(p.counts, total: totalDisp))).font(.caption)
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                    Text(Fmt.cost(p.cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private func hoursSection(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("逐小时用量 · \(s.hoursMode)")
            Chart(s.hours, id: \.hour) { h in
                BarMark(
                    x: .value("小时", h.hour),
                    y: .value("Tokens", Double(disp(h.counts)))
                )
                .foregroundStyle(model.theme.primary.gradient)
                .cornerRadius(2)
                .opacity(hoveredHour == nil || hoveredHour == h.hour ? 1 : 0.4)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self) { Text("\(h)时").font(.caption2) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Fmt.compactTokens(Int64(v))).font(.caption2)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    guard let plotAnchor = proxy.plotFrame else { hoveredHour = nil; return }
                                    let frame = geo[plotAnchor]
                                    if let hour: Int = proxy.value(atX: loc.x - frame.origin.x) {
                                        hoveredHour = (0...23).contains(hour) ? hour : nil
                                    } else {
                                        hoveredHour = nil
                                    }
                                case .ended:
                                    hoveredHour = nil
                                }
                            }
                        if let hh = hoveredHour,
                           let stat = s.hours.first(where: { $0.hour == hh }),
                           let plotAnchor = proxy.plotFrame,
                           let xPos = proxy.position(forX: hh) {
                            let frame = geo[plotAnchor]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "%02d:00 – %02d:59", hh, hh)).font(.caption2).foregroundStyle(.secondary)
                                Text("\(Fmt.tokens(disp(stat.counts))) tokens")
                                    .font(.caption).bold().monospacedDigit()
                                Text(Fmt.cost(stat.cost))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                            .position(x: min(max(xPos + frame.origin.x, 70), geo.size.width - 70), y: 24)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: 80)
        }
    }

    private func trendSection(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("每日用量（近 30 天）")
            let days = s.trendDays
            if days.isEmpty {
                emptyNote
            } else {
                // 只标 5 个刻度，避免日期重叠
                let labelDays = [0, 7, 14, 21, 29].compactMap { days.indices.contains($0) ? days[$0].day : nil }
                Chart(days, id: \.day) { d in
                    BarMark(
                        x: .value("日期", d.day),
                        y: .value("Tokens", Double(disp(d.counts)))
                    )
                    .foregroundStyle(model.theme.primary.gradient)
                    .cornerRadius(2)
                    .opacity(hoveredDay == nil || hoveredDay == d.day ? 1 : 0.4)
                }
                .chartXAxis {
                    AxisMarks(values: labelDays) { value in
                        AxisValueLabel {
                            if let str = value.as(String.self) {
                                Text(String(str.dropFirst(5))).font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Fmt.compactTokens(Int64(v))).font(.caption2)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let loc):
                                        guard let plotAnchor = proxy.plotFrame else { hoveredDay = nil; return }
                                        let frame = geo[plotAnchor]
                                        if let day: String = proxy.value(atX: loc.x - frame.origin.x) {
                                            hoveredDay = day
                                        } else {
                                            hoveredDay = nil
                                        }
                                    case .ended:
                                        hoveredDay = nil
                                    }
                                }
                            if let hd = hoveredDay,
                               let stat = days.first(where: { $0.day == hd }),
                               let plotAnchor = proxy.plotFrame,
                               let xPos = proxy.position(forX: hd) {
                                let frame = geo[plotAnchor]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stat.day).font(.caption2).foregroundStyle(.secondary)
                                    Text("\(Fmt.tokens(disp(stat.counts))) tokens")
                                        .font(.caption).bold().monospacedDigit()
                                    Text("\(Fmt.cost(stat.cost)) · \(stat.counts.total > 0 ? Fmt.percent(Double(stat.counts.cacheRead) / Double(max(1, stat.counts.input + stat.counts.cacheRead))) : "-") 缓存命中")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                                .position(x: min(max(xPos + frame.origin.x, 70), geo.size.width - 70), y: 26)
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
    }

    private func footnotes(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !s.unpricedModels.isEmpty {
                Text("未定价模型（费用记 0）：\(s.unpricedModels.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var themeRow: some View {
        HStack(spacing: 9) {
            Text("主题色").font(.caption2).foregroundStyle(.secondary)
            ForEach(AppTheme.all) { t in
                Button {
                    model.themeID = t.id
                } label: {
                    Circle()
                        .fill(t.primary)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle().strokeBorder(model.themeID == t.id ? Color.primary.opacity(0.75) : .clear,
                                                    lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Picker("菜单栏", selection: Binding(get: { model.menuBarStyle }, set: { model.menuBarStyle = $0 })) {
                Text("量+费").tag("both")
                Text("仅量").tag("tokens")
                Text("仅费").tag("cost")
                Text("仅图标").tag("icon")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            Toggle("开机自启", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption2)
                .fixedSize()
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let t = model.lastScan {
                Text("更新 \(timeFormatter.string(from: t))").font(.caption2).foregroundStyle(.secondary)
            }
            if let m = model.settingsMessage {
                Text(m).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") { model.refresh() }
                .buttonStyle(.borderless)
            Button("价格表") {
                PricingTable.writeTemplateIfMissing()
                NSWorkspace.shared.open(PricingTable.overrideURL)
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 4)
    }

    // MARK: - 小组件

    /// 当前口径下的展示总量
    private func disp(_ c: TokenCounts) -> Int64 {
        model.includeCache ? c.total : c.input + c.output
    }

    private func dispShare(_ c: TokenCounts, total: Int64) -> Double {
        total > 0 ? Double(disp(c)) / Double(total) : 0
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.headline).padding(.top, 2)
    }

    private var emptyNote: some View {
        Text("该范围内暂无数据").font(.caption).foregroundStyle(.secondary)
    }

    private func bar(share: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(2, geo.size.width * share))
            }
        }
        .frame(height: 6)
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
#endif
