import Foundation

/// 把某范围的用量明细导出成 CSV（一行 = 某天 × 工具 × 模型 × 项目）。
/// App 与 CLI 共用：对账时表格比界面上看更可靠。
public enum UsageCSV {
    public static func make(buckets: [UsageBucket],
                            range: RangeKind,
                            pricing: PricingTable,
                            includeCache: Bool = true,
                            now: Date = Date()) -> String {
        let start = range.startDayKey(now: now)
        let end = range.endDayKey(now: now)
        let rows = buckets.filter { b in
            if let start, b.day < start { return false }
            if let end, b.day > end { return false }
            return true
        }
        var lines = ["日期,工具,模型,项目,输入,输出,缓存读,缓存写,合计,费用(USD),请求数"]
        for b in rows.sorted(by: { ($0.day, $0.tool, $0.model) < ($1.day, $1.tool, $1.model) }) {
            let model = Aggregator.normalizedModel(b.model)
            let cost = pricing.cost(for: b.counts, model: model)
            lines.append([
                b.day,
                escape(b.tool),
                escape(model),
                escape(b.project == "-" ? "" : b.project),
                String(b.counts.input),
                String(b.counts.output),
                String(b.counts.cacheRead),
                String(b.counts.cacheWrite),
                String(b.counts.total),
                String(format: "%.4f", cost),
                String(b.requests),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
