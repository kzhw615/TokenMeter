import Foundation

/// 扫描进度：线程安全计数，供 App 显示真实进度条
public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var doneCount = 0
    private var totalCount = 0
    private var currentLabel = ""

    public init() {}

    public func start(total: Int) {
        lock.lock(); totalCount = total; doneCount = 0; lock.unlock()
    }
    public func bump(_ n: Int = 1) {
        lock.lock(); doneCount += n; lock.unlock()
    }
    public var done: Int { lock.lock(); defer { lock.unlock() }; return doneCount }
    /// 当前正在扫描的数据源（展示用，如 "Codex"）
    public func setLabel(_ l: String) { lock.lock(); currentLabel = l; lock.unlock() }
    public var label: String { lock.lock(); defer { lock.unlock() }; return currentLabel }
    public var total: Int { lock.lock(); defer { lock.unlock() }; return totalCount }
    public var fraction: Double {
        lock.lock(); defer { lock.unlock() }
        guard totalCount > 0 else { return 0 }
        return min(1, Double(doneCount) / Double(totalCount))
    }
}

/// 当前扫描的进度上报口（扫描期间由 Aggregator 设置，各数据源按文件 bump）
public enum ScanProgressReporter {
    public nonisolated(unsafe) static var current: ScanProgress?
}

public enum Aggregator {
    /// 内部噪音模型：不展示在「按模型」和图表里，但 token 仍计入总量。
    /// wb-lite = WorkBuddy 给会话自动起标题用的小模型（累计两千多 token）。
    public static let ignoredModels: Set<String> = ["wb-lite"]

    /// 诊断开关：扫描时把每个数据源耗时打到 stderr
    public nonisolated(unsafe) static var timingEnabled = false
    /// 由 day key + hour 还原本地时间（用于时段敏感计价）

    /// 归一化模型名：去掉工具自己加的 provider 前缀。
    /// 例：WorkBuddy 把本地 provider 写成 `custom-local:deepseek-flash`，
    /// 直接展示会出现 "custom-local" 这个多余前缀，也会让价格表匹配不到。
    /// 中转 API 的 `auto-` 别名归一。
    /// 中转把「自动路由」写成 auto-<模型id>，且版本号用连字符：auto-gpt-6-1-terra。
    /// 通用规则：去掉 auto-，再把 gpt-<主版本>-<次版本>-<名> 还原成 gpt-<主>.<次>-<名>。
    /// 之前只硬编码了 auto-gpt-6-1-sol，一到 terra/astra 就又冒出来了。
    static func normalizeAutoAlias(_ raw: String) -> String? {
        guard raw.lowercased().hasPrefix("auto-") else { return nil }
        var rest = String(raw.dropFirst("auto-".count))
        let parts = rest.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 4, parts[0].lowercased() == "gpt",
           Int(parts[1]) != nil, Int(parts[2]) != nil {
            rest = "gpt-\(parts[1]).\(parts[2])-" + parts[3...].joined(separator: "-")
        }
        return rest
    }

    /// 中转 API 的模型别名 → 官方模型名。
    /// 例：Claude Code 日志里写的是 `group/auto-gpt-6-1-sol`（中转的自动路由分组，
    /// 且用连字符写版本号），实际就是 gpt-6.1-sol，不映射会单独占一行而且价格对不上。
    static let modelAliases: [String: String] = [
        "auto-gpt-6-1-sol": "gpt-6.1-sol",
        "gpt-6-1-sol": "gpt-6.1-sol",
    ]

    public static func normalizedModel(_ raw: String) -> String {
        var name = raw
        for prefix in ["custom-local:", "custom-remote:"] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if let mapped = modelAliases[name.lowercased()] { return mapped }
        if let auto = normalizeAutoAlias(name) { name = auto }
        return strippingEffort(name)
    }

    /// 思维强度/档位后缀：同一模型的不同思考强度不该拆成多行。
    /// 例：gemini-4-hydrogen-tiered-high → gemini-4-hydrogen、claude-opus-5-5-medium → claude-opus-5-5
    /// 只从**尾部**剥离，且保留至少两段（避免把整个名字剥空）。
    static let effortTokens: Set<String> = [
        "xhigh", "x-high", "high", "medium", "low", "minimal", "tiered",
        "thinking", "reasoning", "none", "fast",
    ]

    public static func strippingEffort(_ name: String) -> String {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2 else { return name }
        var kept = parts
        // 从尾部连续剥离档位词（tiered-high 这种要剥两次）
        while kept.count > 2, let last = kept.last, effortTokens.contains(last.lowercased()) {
            kept.removeLast()
        }
        guard kept.count != parts.count else { return name }
        return kept.joined(separator: "-")
    }

    static func bucketDate(day: String, hour: Int, calendar: Calendar) -> Date? {
        guard let base = DayKey.date(for: day) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)
    }

    public static func allSources() -> [UsageSource] {
        var list: [UsageSource] = [ClaudeCodeSource(), CodexSource(), DshSource(), WorkBuddySource()]
        #if os(macOS)
        list += [OpenCodeSource(), HermesSource(), ZCodeSource(), OpenMausBotSource()]
        #endif
        return list + ExtraSources.all()
    }

    /// 扫描所有来源；enabled 为来源 id 集合（nil = 用默认）
    public static func scan(enabled: Set<String>? = nil,
                            cache: inout ScanCache,
                            progress: ScanProgress? = nil,
                            recentOnlySince: Date? = nil) -> (buckets: [UsageBucket], statuses: [SourceStatus]) {
        SourcePaths.recentOnlyCutoff = recentOnlySince
        defer { SourcePaths.recentOnlyCutoff = nil }
        let sources = allSources()
        // 进度总数由调用方通过 progress.start(total:) 传入（上次扫描的文件数），
        // 避免为了拿总数而重复遍历一遍目录
        ScanProgressReporter.current = progress
        defer { ScanProgressReporter.current = nil }

        var buckets: [UsageBucket] = []
        var statuses: [SourceStatus] = []
        for source in sources {
            let on = enabled?.contains(source.id) ?? source.enabledByDefault
            guard on else {
                statuses.append(SourceStatus(id: source.id, name: source.displayName, enabled: false, files: 0, note: "已禁用"))
                continue
            }
            let t0 = Date()
            ScanProgressReporter.current?.setLabel(source.displayName)
            let r = source.scan(cache: &cache)
            if Self.timingEnabled {
                let ms = Date().timeIntervalSince(t0) * 1000
                FileHandle.standardError.write(Data(String(format: "    %-14s %7.1f ms  files=%d\n",
                    (source.id as NSString).utf8String!, ms, r.files).utf8))
            }
            buckets.append(contentsOf: r.buckets)
            statuses.append(SourceStatus(id: source.id, name: source.displayName, enabled: true, files: r.files, note: r.note))
        }
        return (buckets, statuses)
    }

    public static func summarize(buckets: [UsageBucket],
                                 range: RangeKind,
                                 pricing: PricingTable,
                                 statuses: [SourceStatus],
                                 now: Date = Date()) -> Summary {
        let startKey = range.startDayKey(now: now)
        let endKey = range.endDayKey(now: now)
        var counts = TokenCounts()
        var cost = 0.0
        var requests = 0
        var toolMap: [String: (counts: TokenCounts, cost: Double, requests: Int)] = [:]
        var modelMap: [String: (counts: TokenCounts, cost: Double, requests: Int, tools: Set<String>)] = [:]
        var projectMap: [String: (counts: TokenCounts, cost: Double, tools: Set<String>)] = [:]
        var hourMap: [Int: (counts: TokenCounts, cost: Double)] = [:]
        var hourModelMap: [Int: [String: (TokenCounts, Double)]] = [:]
        var dayMap: [String: (counts: TokenCounts, cost: Double)] = [:]
        var dayMapAll: [String: (counts: TokenCounts, cost: Double)] = [:]
        // 每日按工具/模型拆分（堆叠柱状图用）
        var dayToolMap: [String: [String: (TokenCounts, Double)]] = [:]
        var dayModelMap: [String: [String: (TokenCounts, Double)]] = [:]
        let prevRange = range.previousDayRange(now: now)
        var prevCounts = TokenCounts()
        var prevCost = 0.0
        var unpriced = Set<String>()

        let cal0 = Calendar.current
        // 「今天」与昨天比时只算已过完的整点：半天 vs 整天必然显示大幅下降，不公平。
        // 注意凌晨 0 点这一小时也要比「同期」：nowHour == 0 时取 1，
        // 否则会退化成「今天头 1 小时 vs 昨天一整天」，出现 −95% 这种吓人的数字。
        let nowHour = cal0.component(.hour, from: now)
        let sameTimeCutoff: Int? = (range == .today) ? max(1, nowHour) : nil
        let todayKey = DayKey.key(for: cal0.startOfDay(for: now), calendar: cal0)
        // 逐桶缓存：归档里有上万个 bucket，但只有几十个模型、几百天。
        // 之前每个 bucket 都要：①DayKey 的 DateFormatter 解析（还要抢锁）
        // ②价格表全表匹配（~100 条 pattern 的 contains，每桶两次）——实测占 summarize 的大头。
        var habitGrid = [Int64](repeating: 0, count: 168)
        var dayDateForHabit: [String: Date?] = [:]
        var projectModelMap: [String: [String: (TokenCounts, Double)]] = [:]
        var toolModelMap: [String: [String: (TokenCounts, Double)]] = [:]
        var modelCache: [String: String] = [:]
        var priceCache: [String: ModelPrice?] = [:]
        func priceOf(_ m: String) -> ModelPrice? {
            if let hit = priceCache[m] { return hit }
            let v = pricing.price(for: m)
            priceCache[m] = v
            return v
        }
        func costOf(_ c: TokenCounts, _ m: String) -> Double {
            guard let p = priceOf(m) else { return 0 }
            var v = Double(c.input) / 1e6 * p.input
            v += Double(c.output) / 1e6 * p.output
            v += Double(c.cacheRead) / 1e6 * (p.cacheRead ?? p.input * 0.1)
            v += Double(c.cacheWrite) / 1e6 * (p.cacheWrite ?? p.input * 1.25)
            return v
        }
        for b in buckets {
            let model: String
            if let hit = modelCache[b.model] {
                model = hit
            } else {
                let m = Self.normalizedModel(b.model)
                modelCache[b.model] = m
                model = m
            }
            let c = costOf(b.counts, model)
            if priceOf(model) == nil { unpriced.insert(model) }
            var da = dayMapAll[b.day] ?? (TokenCounts(), 0)
            da.counts += b.counts; da.cost += c
            dayMapAll[b.day] = da
            var dt = dayToolMap[b.day]?[b.tool] ?? (TokenCounts(), 0)
            dt.0 += b.counts; dt.1 += c
            dayToolMap[b.day, default: [:]][b.tool] = dt
            var dm = dayModelMap[b.day]?[model] ?? (TokenCounts(), 0)
            dm.0 += b.counts; dm.1 += c
            dayModelMap[b.day, default: [:]][model] = dm
            // 使用习惯矩阵：周几 × 小时（周几 0=周日）
            if let date = dayDateForHabit[b.day] ?? {
                let v = DayKey.date(for: b.day)
                dayDateForHabit[b.day] = v
                return v
            }() {
                let wd = (cal0.component(.weekday, from: date) - 1 + 7) % 7
                habitGrid[wd * 24 + b.hour] += b.counts.total
            }
            if let startKey, b.day < startKey { continue }
            if let endKey, b.day > endKey { continue }
            counts += b.counts
            cost += c
            requests += b.requests
            var t = toolMap[b.tool] ?? (TokenCounts(), 0, 0)
            t.counts += b.counts; t.cost += c; t.requests += b.requests
            toolMap[b.tool] = t
            var m = modelMap[model] ?? (TokenCounts(), 0, 0, [])
            m.counts += b.counts; m.cost += c; m.requests += b.requests; m.tools.insert(b.tool)
            modelMap[model] = m
            var pj = projectMap[b.project] ?? (TokenCounts(), 0, [])
            pj.counts += b.counts; pj.cost += c; pj.tools.insert(b.tool)
            projectMap[b.project] = pj
            // 工具 × 模型（点开工具看明细用）
            var tm = toolModelMap[b.tool]?[model] ?? (TokenCounts(), 0)
            tm.0 += b.counts; tm.1 += c
            toolModelMap[b.tool, default: [:]][model] = tm
            // 项目 × 模型
            var pm = projectModelMap[b.project]?[model] ?? (TokenCounts(), 0)
            pm.0 += b.counts; pm.1 += c
            projectModelMap[b.project, default: [:]][model] = pm
            var h = hourMap[b.hour] ?? (TokenCounts(), 0)
            h.counts += b.counts; h.cost += c
            hourMap[b.hour] = h
            var hm = hourModelMap[b.hour]?[model] ?? (TokenCounts(), 0)
            hm.0 += b.counts; hm.1 += c
            hourModelMap[b.hour, default: [:]][model] = hm
            var d = dayMap[b.day] ?? (TokenCounts(), 0)
            d.counts += b.counts; d.cost += c
            dayMap[b.day] = d

            // 会话聚合（Top N 用）
        }

        // 上一等长周期（环比）：同时给出对象名称与具体日期，避免「上一周期」含糊
        var previousLabel: String?
        if let pr = prevRange {
            func md(_ key: String) -> String {
                let parts = key.split(separator: "-")
                guard parts.count == 3 else { return key }
                return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
            }
            let cutoffText = String(format: "%02d", sameTimeCutoff ?? 0)
            if let _ = sameTimeCutoff {
                previousLabel = Fmt.english
                    ? "yesterday, same hours (0:00–\(cutoffText):00)"
                    : "昨天同期（0:00–\(cutoffText):00）"
            } else {
                let name = range.previousPeriodName(now: now, calendar: cal0) ?? (Fmt.english ? "previous period" : "上一周期")
                let span = pr.start == pr.end ? md(pr.start) : "\(md(pr.start))–\(md(pr.end))"
                previousLabel = Fmt.english ? "\(name) (\(span))" : "\(name)（\(span)）"
            }
        }
        if let pr = prevRange {
            for b in buckets where b.day >= pr.start && b.day <= pr.end {
                if let cut = sameTimeCutoff, b.hour >= cut { continue }
                let dt = Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0)
                prevCounts += b.counts
                prevCost += pricing.cost(for: b.counts, model: Self.normalizedModel(b.model), at: dt)
            }
        }
        // 同口径的「本期」值（今天只算已过完的整点），保证百分比可比较
        var comparableCounts: TokenCounts?
        var comparableCost: Double?
        if let cut = sameTimeCutoff {
            var cc = TokenCounts(); var ccost = 0.0
            for b in buckets where b.day == todayKey && b.hour < cut {
                cc += b.counts
                ccost += pricing.cost(for: b.counts, model: Self.normalizedModel(b.model),
                                      at: Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0))
            }
            comparableCounts = cc
            comparableCost = ccost
        }

        let totalAll = max(1, counts.total)
        let tools = toolMap.map { ToolStat(tool: $0.key, counts: $0.value.counts, cost: $0.value.cost, requests: $0.value.requests, share: Double($0.value.counts.total) / Double(totalAll)) }
            .sorted { $0.counts.total > $1.counts.total }
        let models = modelMap.filter { !Self.ignoredModels.contains($0.key.lowercased()) }.map { ModelStat(model: $0.key, counts: $0.value.counts, cost: $0.value.cost, requests: $0.value.requests, share: Double($0.value.counts.total) / Double(totalAll), tools: Array($0.value.tools).sorted()) }
            .sorted { $0.counts.total > $1.counts.total }
        let days = dayMap.map { DayStat(day: $0.key, counts: $0.value.counts, cost: $0.value.cost) }
            .sorted { $0.day < $1.day }
        // 两套独立窗口：
        // - 柱状「趋势」固定最近 30 天（与所选范围无关，纯看近期走势）
        // - 日历热力图展示全部历史（铺满面板宽度，看得出长期密度）
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        func dayKeys(from start: Date, to end: Date) -> [String] {
            var out: [String] = []
            var d = cal.startOfDay(for: start)
            let last = cal.startOfDay(for: end)
            while d <= last {
                out.append(DayKey.key(for: d, calendar: cal))
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
            return out
        }
        let barsKeys = dayKeys(from: cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday,
                               to: startOfToday)
        let calendarKeys: [String] = {
            guard let earliest = dayMapAll.keys.min(), let d = DayKey.date(for: earliest) else { return barsKeys }
            let capped = max(d, cal.date(byAdding: .day, value: -729, to: startOfToday) ?? d)
            let keys = dayKeys(from: capped, to: startOfToday)
            return keys.count > 1 ? keys : barsKeys
        }()
        func stack(_ m: [String: [String: (TokenCounts, Double)]], day key: String) -> DayStack {
            let parts = (m[key] ?? [:])
                .filter { !ignoredModels.contains($0.key.lowercased()) }
                .map { StackPart(name: $0.key, counts: $0.value.0, cost: $0.value.1) }
                .sorted { $0.counts.total > $1.counts.total }
            return DayStack(day: key, parts: parts)
        }
        func dayStats(_ keys: [String]) -> [DayStat] {
            keys.map { key in
                let e = dayMapAll[key]
                return DayStat(day: key, counts: e?.counts ?? TokenCounts(), cost: e?.cost ?? 0)
            }
        }
        let trend = dayStats(barsKeys)
        let trendByTool = trend.map { stack(dayToolMap, day: $0.day) }
        let trendByModel = trend.map { stack(dayModelMap, day: $0.day) }
        let calendarDays = dayStats(calendarKeys)
        let calendarByTool = calendarDays.map { stack(dayToolMap, day: $0.day) }
        let calendarByModel = calendarDays.map { stack(dayModelMap, day: $0.day) }
        let projectModels: [ProjectModels] = projectMap.keys.map { key in
            let parts = (projectModelMap[key] ?? [:])
                .map { StackPart(name: $0.key, counts: $0.value.0, cost: $0.value.1) }
                .sorted { $0.counts.total > $1.counts.total }
            return ProjectModels(project: key, parts: Array(parts.prefix(8)))
        }
        let toolModels: [ToolModels] = toolMap.keys.map { key in
            let parts = (toolModelMap[key] ?? [:])
                .map { StackPart(name: $0.key, counts: $0.value.0, cost: $0.value.1) }
                .sorted { $0.counts.total > $1.counts.total }
            return ToolModels(tool: key, parts: Array(parts.prefix(8)))
        }
        let denom = Double(counts.input + counts.cacheRead)
        let hit = denom > 0 ? Double(counts.cacheRead) / denom : 0
        let projects = projectMap.map { ProjectStat(project: $0.key, counts: $0.value.counts, cost: $0.value.cost, share: Double($0.value.counts.total) / Double(totalAll), tools: Array($0.value.tools).sorted()) }
            .sorted { $0.counts.total > $1.counts.total }
        let singleDay: Bool = (range == .today || range == .yesterday)
        let hours = (0..<24).map { h -> HourStat in
            let e = hourMap[h]
            return HourStat(hour: h, counts: e?.counts ?? TokenCounts(), cost: e?.cost ?? 0)
        }
        let hoursMode: String = {
            if Fmt.english {
                return singleDay ? (range == .today ? "Today, hourly" : "Yesterday, hourly")
                                 : "By hour of day (range total)"
            }
            return singleDay ? (range == .today ? "今日逐小时" : "昨日逐小时") : "按钟点分布（范围内汇总）"
        }()
        let hoursByModel = (0..<24).map { h -> HourStack in
            let parts = (hourModelMap[h] ?? [:])
                .filter { !ignoredModels.contains($0.key.lowercased()) }
                .map { StackPart(name: $0.key, counts: $0.value.0, cost: $0.value.1) }
                .sorted { $0.counts.total > $1.counts.total }
            return HourStack(hour: h, parts: parts)
        }

        // 本月预测：按「本月至今日均」外推到整月
        var forecastCost: Double? = nil
        var forecastCounts: TokenCounts? = nil
        if range == .thisMonth {
            let cal2 = Calendar.current
            let dayOfMonth = cal2.component(.day, from: now)
            if let dayRange = cal2.range(of: .day, in: .month, for: now), dayOfMonth > 0 {
                let totalDays = dayRange.count
                if totalDays > dayOfMonth {
                    let factor = Double(totalDays) / Double(dayOfMonth)
                    forecastCost = cost * factor
                    var fc = TokenCounts()
                    fc.input = Int64(Double(counts.input) * factor)
                    fc.output = Int64(Double(counts.output) * factor)
                    fc.cacheRead = Int64(Double(counts.cacheRead) * factor)
                    fc.cacheWrite = Int64(Double(counts.cacheWrite) * factor)
                    forecastCounts = fc
                }
            }
        }

        return Summary(range: range, generatedAt: now, counts: counts, cost: cost, requests: requests,
                       cacheHitRate: hit, tools: tools, models: models, days: days, trendDays: trend,
                       projects: projects, hours: hours, hoursMode: hoursMode,
                       unpricedModels: Array(unpriced).sorted(), sourceStatuses: statuses,
                       previousCounts: prevRange == nil ? nil : prevCounts,
                       previousCost: prevRange == nil ? nil : prevCost,
                       previousLabel: previousLabel,
                       comparableCounts: comparableCounts,
                       comparableCost: comparableCost,
                       hoursByModel: hoursByModel,
                       trendByTool: trendByTool, trendByModel: trendByModel,
                       forecastCost: forecastCost, forecastCounts: forecastCounts,
                       calendarDays: calendarDays,
                       calendarByTool: calendarByTool,
                       calendarByModel: calendarByModel,
                       habitGrid: habitGrid,
                       projectModels: projectModels,
                       toolModels: toolModels)
    }

    /// 热扫描：只解析最近活跃的文件，返回今日含缓存总量（用于燃烧速率）
}
