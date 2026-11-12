#if os(macOS)
import SwiftUI
import Charts
import TokenMeterCore

struct SlidingTabs<Option: Hashable>: View {
    let options: [(option: Option, label: String)]
    @Binding var selection: Option
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let selected = selection == opt.option
                Button {
                    guard !selected else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)) {
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

/// 数字滚动：内容过渡 + 仅该文本参与的动画（避免整页重绘动画导致的抖动）
struct RollingNumber: ViewModifier {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: value)
    }
}

extension View {
    func rolling(_ value: String) -> some View { modifier(RollingNumber(value: value)) }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var actions: AppActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDay: String?
    @State private var hoveredHour: Int?
    @State private var hoveredRow: String?


    private var palette: [Color] { model.theme.palette }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
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
                    Group {
                    summaryCards(s)
                    deltaNotes(s)
                    toolsSection(s)
                    modelsSection(s)
                    projectsSection(s)
                    trendSection(s)
                    hoursSection(s)
                    footnotes(s)
                    }
                    .transition(.opacity)
                } else {
                    skeletonView
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            // 仅在「扫描中 ↔ 有数据」切换时淡入，不做整树动画
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.summary == nil)
        }
        .frame(width: 430, height: 560)
        .onExitCommand { actions.closePanel() }
        .onAppear { model.panelOpen = true }
        .onDisappear { model.panelOpen = false }
    }

    /// 扫描中的骨架屏：真实进度条 + 灰色占位块（减少「卡住」的错觉）
    private var skeletonView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计历史用量…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.scanTotal > 0 {
                        Text("\(model.scanDone) / \(model.scanTotal)")
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    } else if let t = model.scanStartedAt {
                        Text("已 \(Int(Date().timeIntervalSince(t))) 秒")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                ProgressView(value: model.scanFraction)
                    .progressViewStyle(.linear)
                    .tint(model.theme.primary)
                Text("首次运行或日志有大量变动时需要几分钟；已完成的文件会被缓存，之后是秒级增量。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 占位块
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
                .frame(height: 92)
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 60 + CGFloat(i * 12), height: 9)
                    ForEach(0..<3, id: \.self) { j in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 12)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.scanStartedAt == nil ? 0.5 : 1)
        .allowsHitTesting(false)
    }

    // MARK: - 区块

    private var header: some View {
        HStack(spacing: 8) {
            Text("TokenMeter").font(.title3.bold())
            if model.isBurning {
                HStack(spacing: 3) {
                    FlameIcon(ticker: model.flame, frames: model.currentFlameFrames, size: 12)
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
            Text("v\(UpdateKit.currentVersion())")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Button(action: { model.checkForUpdates(force: true) }) {
                if model.updateChecking {
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                        Text("检查中…").font(.caption2)
                    }
                } else {
                    Text("检查更新").font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(model.updateChecking)
            .help("立即检查是否有新版本")
            Button(action: { confirmQuit() }) {
                Text("退出").font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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
                    .rolling(value)
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

    /// 行悬停高亮（轻微的底色，提示可交互）
    @ViewBuilder
    private func rowBackground(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(hoveredRow == key ? 0.05 : 0))
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
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
                        .rolling(Fmt.tokens(disp(t.counts)))
                        .frame(width: 62, alignment: .trailing)
                    Text(Fmt.percent(dispShare(t.counts, total: totalDisp))).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                    Text(Fmt.cost(t.cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
                }
                .background(rowBackground("tool-\(t.tool)"))
                .onHover { hoveredRow = $0 ? "tool-\(t.tool)" : nil }
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
                            .rolling(Fmt.tokens(disp(m.counts)))
                        Text(Fmt.percent(dispShare(m.counts, total: totalDisp))).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                        Text(Fmt.cost(m.cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                    bar(share: dispShare(m.counts, total: totalDisp), color: palette[idx % palette.count])
                        .frame(height: 3)
                    Text(m.tools.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                }
                .background(rowBackground("model-\(m.model)"))
                .onHover { hoveredRow = $0 ? "model-\(m.model)" : nil }
            }
        }
    }

    private func projectsSection(_ s: Summary) -> some View {
        let totalDisp = s.projects.reduce(Int64(0)) { $0 + disp($1.counts) }
        let list = Array(s.projects.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("按项目")
            if list.isEmpty { emptyNote }
            ForEach(Array(list.enumerated()), id: \.element.project) { idx, p in
                HStack(spacing: 10) {
                    Text(p.project == "-" ? "未归属" : p.project).font(.callout).frame(width: 110, alignment: .leading)
                        .lineLimit(1).truncationMode(.middle)
                    bar(share: dispShare(p.counts, total: totalDisp), color: palette[idx % palette.count])
                    Text(Fmt.tokens(disp(p.counts))).font(.callout).monospacedDigit()
                        .rolling(Fmt.tokens(disp(p.counts))).frame(width: 62, alignment: .trailing)
                    Text(Fmt.percent(dispShare(p.counts, total: totalDisp))).font(.caption)
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 46, alignment: .trailing)
                    Text(Fmt.cost(p.cost)).font(.callout).monospacedDigit().frame(width: 58, alignment: .trailing)
                }
                .background(rowBackground("proj-\(p.project)"))
                .onHover { hoveredRow = $0 ? "proj-\(p.project)" : nil }
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

    /// 环比（上一个等长周期）与本月预测
    @ViewBuilder
    private func deltaNotes(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let prev = s.previousCounts, prev.total > 0 {
                // 「今天」场景下两者都已限定为「已过完的整点」，口径一致
                let currentRaw = s.comparableCounts.map { disp($0) } ?? disp(s.counts)
                let prevRaw = disp(prev)
                let tokenDiff = prevRaw > 0 ? Double(currentRaw - prevRaw) / Double(prevRaw) : 0
                let target = s.previousLabel ?? "上一周期"

                // ① 用量变化（token）
                HStack(spacing: 4) {
                    Image(systemName: tokenDiff >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text("用量比\(target)\(tokenDiff >= 0 ? "多" : "少") \(Fmt.percent(abs(tokenDiff)))")
                        .font(.caption)
                }
                .foregroundStyle(tokenDiff >= 0 ? Color.orange : Color.green)

                // ② 费用变化（与用量分开显示：模型不同会让两者方向相反）
                if let pc = s.previousCost, let cur = s.comparableCost {
                    let costDiff = pc > 0 ? (cur - pc) / pc : 0
                    HStack(spacing: 4) {
                        Image(systemName: costDiff >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text("费用比\(target)\(costDiff >= 0 ? "多" : "少") \(Fmt.percent(abs(costDiff)))")
                            .font(.caption)
                        Text("（\(Fmt.cost(pc)) → \(Fmt.cost(cur))）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(costDiff >= 0 ? Color.orange : Color.green)
                }
            }
            if let fc = s.forecastCost, fc > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.caption2)
                    Text("按当前速度预计本月 \(Fmt.cost(fc))").font(.caption)
                }
                .foregroundStyle(.secondary)
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

private var footer: some View {
        HStack(spacing: 10) {
            if let t = model.lastScan {
                Text("上次统计 \(timeFormatter.string(from: t))").font(.caption2).foregroundStyle(.secondary)
            }
            if let m = model.settingsMessage {
                Text(m).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") { model.refresh() }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
            Button("设置") { actions.openSettings() }
                .buttonStyle(.borderless)
        }
        .padding(.top, 4)
    }

/// 设置卡片：小标题 + 内容
    @ViewBuilder
/// 源开关胶囊
private func budgetRow(label: String, value: Binding<Double>, cost: Double?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 44, alignment: .leading)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
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
                    .frame(width: 80)
                    .tint(over ? Color.red : model.theme.primary)
            }
        }
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
        f.dateFormat = "HH:mm"
        return f
    }()
}
#endif
