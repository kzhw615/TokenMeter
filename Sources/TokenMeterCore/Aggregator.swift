import Foundation

/// 扫描进度：线程安全计数，供 App 显示真实进度条
public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var doneCount = 0
    private var totalCount = 0

    public init() {}

    public func start(total: Int) {
        lock.lock(); totalCount = total; doneCount = 0; lock.unlock()
    }
    public func bump(_ n: Int = 1) {
        lock.lock(); doneCount += n; lock.unlock()
    }
    public var done: Int { lock.lock(); defer { lock.unlock() }; return doneCount }
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
    /// 诊断开关：扫描时把每个数据源耗时打到 stderr
    public nonisolated(unsafe) static var timingEnabled = false
    /// 由 day key + hour 还原本地时间（用于时段敏感计价）
    static func bucketDate(day: String, hour: Int, calendar: Calendar) -> Date? {
        guard let base = DayKey.date(for: day) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)
    }

    public static func allSources() -> [UsageSource] {
        var list: [UsageSource] = [ClaudeCodeSource(), CodexSource(), DshSource(), WorkBuddySource()]
        #if os(macOS)
        list += [OpenCodeSource(), HermesSource(), ZCodeSource()]
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
        let nowHour = cal0.component(.hour, from: now)
        let sameTimeCutoff: Int? = (range == .today && nowHour > 0) ? nowHour : nil
        let todayKey = DayKey.key(for: cal0.startOfDay(for: now), calendar: cal0)
        for b in buckets {
            let bucketDate = Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0)
            let c = pricing.cost(for: b.counts, model: b.model, at: bucketDate)
            if pricing.price(for: b.model) == nil { unpriced.insert(b.model) }
            var da = dayMapAll[b.day] ?? (TokenCounts(), 0)
            da.counts += b.counts; da.cost += c
            dayMapAll[b.day] = da
            var dt = dayToolMap[b.day]?[b.tool] ?? (TokenCounts(), 0)
            dt.0 += b.counts; dt.1 += c
            dayToolMap[b.day, default: [:]][b.tool] = dt
            var dm = dayModelMap[b.day]?[b.model] ?? (TokenCounts(), 0)
            dm.0 += b.counts; dm.1 += c
            dayModelMap[b.day, default: [:]][b.model] = dm
            if let startKey, b.day < startKey { continue }
            if let endKey, b.day > endKey { continue }
            counts += b.counts
            cost += c
            requests += b.requests
            var t = toolMap[b.tool] ?? (TokenCounts(), 0, 0)
            t.counts += b.counts; t.cost += c; t.requests += b.requests
            toolMap[b.tool] = t
            var m = modelMap[b.model] ?? (TokenCounts(), 0, 0, [])
            m.counts += b.counts; m.cost += c; m.requests += b.requests; m.tools.insert(b.tool)
            modelMap[b.model] = m
            var pj = projectMap[b.project] ?? (TokenCounts(), 0, [])
            pj.counts += b.counts; pj.cost += c; pj.tools.insert(b.tool)
            projectMap[b.project] = pj
            var h = hourMap[b.hour] ?? (TokenCounts(), 0)
            h.counts += b.counts; h.cost += c
            hourMap[b.hour] = h
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
            if let cut = sameTimeCutoff {
                previousLabel = "昨天同期（0:00–\(String(format: "%02d", cut)):00）"
            } else {
                let name = range.previousPeriodName(now: now, calendar: cal0) ?? "上一周期"
                let span = pr.start == pr.end ? md(pr.start) : "\(md(pr.start))–\(md(pr.end))"
                previousLabel = "\(name)（\(span)）"
            }
        }
        if let pr = prevRange {
            for b in buckets where b.day >= pr.start && b.day <= pr.end {
                if let cut = sameTimeCutoff, b.hour >= cut { continue }
                let dt = Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0)
                prevCounts += b.counts
                prevCost += pricing.cost(for: b.counts, model: b.model, at: dt)
            }
        }
        // 同口径的「本期」值（今天只算已过完的整点），保证百分比可比较
        var comparableCounts: TokenCounts?
        var comparableCost: Double?
        if let cut = sameTimeCutoff {
            var cc = TokenCounts(); var ccost = 0.0
            for b in buckets where b.day == todayKey && b.hour < cut {
                cc += b.counts
                ccost += pricing.cost(for: b.counts, model: b.model,
                                      at: Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0))
            }
            comparableCounts = cc
            comparableCost = ccost
        }

        let totalAll = max(1, counts.total)
        let tools = toolMap.map { ToolStat(tool: $0.key, counts: $0.value.counts, cost: $0.value.cost, requests: $0.value.requests, share: Double($0.value.counts.total) / Double(totalAll)) }
            .sorted { $0.counts.total > $1.counts.total }
        let models = modelMap.map { ModelStat(model: $0.key, counts: $0.value.counts, cost: $0.value.cost, requests: $0.value.requests, share: Double($0.value.counts.total) / Double(totalAll), tools: Array($0.value.tools).sorted()) }
            .sorted { $0.counts.total > $1.counts.total }
        let days = dayMap.map { DayStat(day: $0.key, counts: $0.value.counts, cost: $0.value.cost) }
            .sorted { $0.day < $1.day }
        // 近 30 天趋势（与所选范围无关，缺失日补零）
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        var trend: [DayStat] = []
        for i in stride(from: 29, through: 0, by: -1) {
            let date = cal.date(byAdding: .day, value: -i, to: startOfToday)!
            let key = DayKey.key(for: date, calendar: cal)
            let e = dayMapAll[key]
            trend.append(DayStat(day: key, counts: e?.counts ?? TokenCounts(), cost: e?.cost ?? 0))
        }
        func stack(_ m: [String: [String: (TokenCounts, Double)]], day key: String) -> DayStack {
            let parts = (m[key] ?? [:])
                .map { StackPart(name: $0.key, counts: $0.value.0, cost: $0.value.1) }
                .sorted { $0.counts.total > $1.counts.total }
            return DayStack(day: key, parts: parts)
        }
        let trendByTool = trend.map { stack(dayToolMap, day: $0.day) }
        let trendByModel = trend.map { stack(dayModelMap, day: $0.day) }
        let denom = Double(counts.input + counts.cacheRead)
        let hit = denom > 0 ? Double(counts.cacheRead) / denom : 0
        let projects = projectMap.map { ProjectStat(project: $0.key, counts: $0.value.counts, cost: $0.value.cost, share: Double($0.value.counts.total) / Double(totalAll), tools: Array($0.value.tools).sorted()) }
            .sorted { $0.counts.total > $1.counts.total }
        let singleDay: Bool = (range == .today || range == .yesterday)
        let hours = (0..<24).map { h -> HourStat in
            let e = hourMap[h]
            return HourStat(hour: h, counts: e?.counts ?? TokenCounts(), cost: e?.cost ?? 0)
        }
        let hoursMode = singleDay ? (range == .today ? "今日逐小时" : "昨日逐小时") : "按钟点分布（范围内汇总）"

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
                       trendByTool: trendByTool, trendByModel: trendByModel,
                       forecastCost: forecastCost, forecastCounts: forecastCounts)
    }

    /// 热扫描：只解析最近活跃的文件，返回今日含缓存总量（用于燃烧速率）
}
