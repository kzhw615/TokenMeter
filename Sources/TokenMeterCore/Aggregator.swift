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
                            recentOnlySince: Date? = nil) -> (buckets: [UsageBucket], statuses: [SourceStatus], sessions: SessionTotals) {
        SourcePaths.recentOnlyCutoff = recentOnlySince
        defer { SourcePaths.recentOnlyCutoff = nil }
        let sources = allSources()
        // 进度总数由调用方通过 progress.start(total:) 传入（上次扫描的文件数），
        // 避免为了拿总数而重复遍历一遍目录
        ScanProgressReporter.current = progress
        defer { ScanProgressReporter.current = nil }

        var buckets: [UsageBucket] = []
        var statuses: [SourceStatus] = []
        var sessionAgg = SessionAgg()
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
            sessionAgg.absorb(r.sessions)
            statuses.append(SourceStatus(id: source.id, name: source.displayName, enabled: true, files: r.files, note: r.note))
        }
        return (buckets, statuses, sessionAgg.totals)
    }

    public static func summarize(buckets: [UsageBucket],
                                 range: RangeKind,
                                 pricing: PricingTable,
                                 statuses: [SourceStatus],
                                 sessions: SessionTotals = [:],
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
        var sessionMap: [String: (tool: String, project: String, counts: TokenCounts, cost: Double, requests: Int, last: String)] = [:]
        let prevRange = range.previousDayRange(now: now)
        var prevCounts = TokenCounts()
        var prevCost = 0.0
        var unpriced = Set<String>()

        let cal0 = Calendar.current
        for b in buckets {
            let bucketDate = Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0)
            let c = pricing.cost(for: b.counts, model: b.model, at: bucketDate)
            if pricing.price(for: b.model) == nil { unpriced.insert(b.model) }
            var da = dayMapAll[b.day] ?? (TokenCounts(), 0)
            da.counts += b.counts; da.cost += c
            dayMapAll[b.day] = da
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

        // 会话维度来自独立通道（tool|project|session → day → counts）
        for (key, days) in sessions {
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let tool = String(parts[0]), project = String(parts[1])
            var counts = TokenCounts()
            var cost = 0.0
            let requests = 0
            var last = ""
            for (day, models) in days {
                if let startKey, day < startKey { continue }
                if let endKey, day > endKey { continue }
                let dt = Self.bucketDate(day: day, hour: 12, calendar: cal0)
                for (model, c) in models {
                    counts += c
                    cost += pricing.cost(for: c, model: model, at: dt)
                }
                if day > last { last = day }
            }
            guard counts.total > 0 else { continue }
            sessionMap[key] = (tool, project, counts, cost, requests, last.isEmpty ? "" : last + " 结束")
        }

        // 上一等长周期（环比）
        if let pr = prevRange {
            for b in buckets where b.day >= pr.start && b.day <= pr.end {
                let dt = Self.bucketDate(day: b.day, hour: b.hour, calendar: cal0)
                prevCounts += b.counts
                prevCost += pricing.cost(for: b.counts, model: b.model, at: dt)
            }
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

        let allSessions = sessionMap.map { (key, v) in
            SessionStat(session: String(key.split(separator: "|").last ?? "-"),
                        tool: v.tool, project: v.project, counts: v.counts, cost: v.cost,
                        requests: v.requests,
                        share: Double(v.counts.total) / Double(totalAll),
                        lastActive: v.last.isEmpty ? nil : v.last)
        }.sorted { $0.counts.total > $1.counts.total }
        // 只保留 Top 12，其余折叠为「其他会话」，避免面板过长
        var sessions: [SessionStat] = Array(allSessions.prefix(12))
        if allSessions.count > 12 {
            let rest = allSessions.dropFirst(12)
            var c = TokenCounts(); var cc = 0.0; var rq = 0
            for s0 in rest { c += s0.counts; cc += s0.cost; rq += s0.requests }
            sessions.append(SessionStat(session: "其他 \(rest.count) 个会话", tool: "-", project: "-",
                                        counts: c, cost: cc, requests: rq,
                                        share: Double(c.total) / Double(totalAll), lastActive: nil))
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
                       sessions: sessions,
                       unpricedModels: Array(unpriced).sorted(), sourceStatuses: statuses,
                       previousCounts: prevRange == nil ? nil : prevCounts,
                       previousCost: prevRange == nil ? nil : prevCost,
                       forecastCost: forecastCost, forecastCounts: forecastCounts)
    }

    /// 热扫描：只解析最近活跃的文件，返回今日含缓存总量（用于燃烧速率）
}
