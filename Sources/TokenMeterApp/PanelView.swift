import SwiftUI
import Charts
import TokenMeterCore

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var hoveredDay: String?

    private var palette: [Color] { model.theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.updateVisible, let v = model.latestVersion {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                        Text("新版本 v\(v) 可用").font(.caption)
                        Spacer()
                        Button("下载") {
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
                    trendSection(s)
                    footnotes(s)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                themeRow
                footer
            }
            .padding(16)
        }
        .frame(width: 430, height: 560)
    }

    // MARK: - 区块

    private var header: some View {
        HStack {
            Text("TokenMeter").font(.title3.bold())
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func summaryCards(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("范围", selection: Binding(get: { model.range }, set: { model.setRange($0) })) {
                ForEach(RangeKind.allCases, id: \.self) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("口径", selection: Binding(get: { model.includeCache }, set: { model.includeCache = $0 })) {
                Text("含缓存").tag(true)
                Text("不含缓存").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
        }
    }

    private func card(title: String, value: String, unit: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.bold()).monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
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
                    Text(Fmt.tokens(disp(t.counts))).font(.callout).monospacedDigit().frame(width: 62, alignment: .trailing)
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
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let t = model.lastScan {
                Text("更新 \(timeFormatter.string(from: t))").font(.caption2).foregroundStyle(.secondary)
            }
            if let m = model.updateMessage {
                Text(m).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") { model.refresh() }
                .buttonStyle(.borderless)
            Button("检查更新") { model.manualCheck() }
                .buttonStyle(.borderless)
            Button("价格表") {
                PricingTable.writeTemplateIfMissing()
                NSWorkspace.shared.open(PricingTable.overrideURL)
            }
            .buttonStyle(.borderless)
            Button("退出") { NSApplication.shared.terminate(nil) }
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
