import Foundation

public enum Aggregator {
    public static func allSources() -> [UsageSource] {
        [ClaudeCodeSource(), CodexSource(), DshSource(), OpenCodeSource(), WorkBuddySource(),
         HermesSource(), ZCodeSource(), CcSwitchSource()]
    }

    /// 扫描所有来源；enabled 为来源 id 集合（nil = 用默认）
    public static func scan(enabled: Set<String>? = nil,
                            cache: inout ScanCache) -> (buckets: [UsageBucket], statuses: [SourceStatus]) {
        var buckets: [UsageBucket] = []
        var statuses: [SourceStatus] = []
        for source in allSources() {
            let on = enabled?.contains(source.id) ?? source.enabledByDefault
            guard on else {
                statuses.append(SourceStatus(id: source.id, name: source.displayName, enabled: false, files: 0, note: "已禁用"))
                continue
            }
            let r = source.scan(cache: &cache)
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
        var dayMap: [String: (counts: TokenCounts, cost: Double)] = [:]
        var dayMapAll: [String: (counts: TokenCounts, cost: Double)] = [:]
        var unpriced = Set<String>()

        for b in buckets {
            let c = pricing.cost(for: b.counts, model: b.model)
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
            var d = dayMap[b.day] ?? (TokenCounts(), 0)
            d.counts += b.counts; d.cost += c
            dayMap[b.day] = d
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

        return Summary(range: range, generatedAt: now, counts: counts, cost: cost, requests: requests,
                       cacheHitRate: hit, tools: tools, models: models, days: days, trendDays: trend,
                       unpricedModels: Array(unpriced).sorted(), sourceStatuses: statuses)
    }
}
