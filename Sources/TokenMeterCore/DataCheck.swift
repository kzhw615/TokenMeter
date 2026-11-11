import Foundation

/// 数据体检：检查「界面看起来正常、但数字其实错了」的隐患。
///
/// 为什么需要它：本项目历史上出现过的两次严重偏差（Codex output 重复计量、空桶缓存污染导致
/// 某天少算 6 倍）在界面上都毫无异常，只能靠人工对账才发现。体检把这些检查自动化。
public struct DataIssue: Sendable {
    public enum Level: String, Sendable { case error = "错误", warning = "警告", info = "提示" }
    public var level: Level
    public var title: String
    public var detail: String

    public init(level: Level, title: String, detail: String) {
        self.level = level; self.title = title; self.detail = detail
    }
}

public enum DataCheck {

    public static func run(buckets: [UsageBucket],
                           statuses: [SourceStatus],
                           now: Date = Date()) -> [DataIssue] {
        var issues: [DataIssue] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let oldest = cal.date(byAdding: .year, value: -5, to: today)!

        // ── 1. 日期合法性（时钟错乱 / 解析错位会污染日、小时分桶）────────────────
        var badDays = Set<String>()
        var futureDays = Set<String>()
        var badHours = 0
        for b in buckets {
            if b.hour < 0 || b.hour > 23 { badHours += 1 }
            guard let d = DayKey.date(from: b.day, calendar: cal) else { badDays.insert(b.day); continue }
            if d > today.addingTimeInterval(86400) { futureDays.insert(b.day) }
            if d < oldest { badDays.insert(b.day) }
        }
        if !badDays.isEmpty {
            issues.append(.init(level: .error, title: "存在非法日期分桶",
                                detail: "\(badDays.count) 个日期无法解析或超出合理范围（如 \(badDays.prefix(3).joined(separator: "、"))），这些用量会被计入错误的日子"))
        }
        if !futureDays.isEmpty {
            issues.append(.init(level: .warning, title: "存在未来日期的数据",
                                detail: "\(futureDays.count) 个日期晚于今天（如 \(futureDays.sorted().prefix(3).joined(separator: "、"))），可能是系统时钟异常或日志时间戳错误"))
        }
        if badHours > 0 {
            issues.append(.init(level: .warning, title: "存在非法小时值",
                                detail: "\(badHours) 条分桶的小时不在 0–23，逐小时图会失真"))
        }

        // ── 2. 异常大的单条分桶（解析错位时常见）──────────────────────────────
        let huge = buckets.filter { $0.counts.total > 5_000_000_000 }
        if !huge.isEmpty {
            let sample = huge.prefix(3).map { "\($0.tool)/\($0.day) \(format(huge.first!.counts.total))" }.joined(separator: "、")
            issues.append(.init(level: .warning, title: "单条分桶用量异常大",
                                detail: "\(huge.count) 条分桶单小时超过 50 亿 tokens（如 \(sample)），可能存在重复累积或解析错位"))
        }

        // ── 3. 缓存读写比例异常（口径理解错误的信号）────────────────────────────
        var byTool: [String: (input: Int64, cacheRead: Int64, output: Int64)] = [:]
        for b in buckets {
            var e = byTool[b.tool] ?? (0, 0, 0)
            e.input += b.counts.input; e.cacheRead += b.counts.cacheRead; e.output += b.counts.output
            byTool[b.tool] = e
        }
        for (tool, e) in byTool.sorted(by: { $0.key < $1.key }) {
            let total = e.input + e.cacheRead
            guard total > 10_000_000 else { continue }
            let rate = Double(e.cacheRead) / Double(total)
            if rate > 0.995 {
                issues.append(.init(level: .warning, title: "\(tool) 缓存命中率异常高",
                                    detail: String(format: "缓存读占 %.1f%%，几乎全部请求都命中缓存，可能是缓存字段被重复累加", rate * 100)))
            }
        }

        // ── 4. 扫描完整性（有数据源报了文件但没产出用量）────────────────────────
        for st in statuses where st.enabled && st.files > 0 {
            let has = buckets.contains { $0.tool == st.name }
            if !has {
                issues.append(.init(level: .warning, title: "\(st.name) 有日志但没有用量",
                                    detail: "扫描了 \(st.files) 个文件，但解析出的用量为 0。可能是日志格式变更，或缓存条目异常（删除 ~/Library/Caches/TokenMeter/scan-v1.json 可强制重建）"))
            }
        }

        return issues
    }

    /// 价格覆盖检查（需要 PricingTable，单独一步，避免和分桶检查耦合）
    public static func pricingIssues(buckets: [UsageBucket], pricing: PricingTable) -> [DataIssue] {
        var missing: [String: Int64] = [:]
        for b in buckets where pricing.price(for: b.model) == nil && b.counts.total > 0 {
            missing[b.model, default: 0] += b.counts.total
        }
        guard !missing.isEmpty else { return [] }
        let top = missing.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key)（\(format($0.value))）" }.joined(separator: "、")
        return [.init(level: .warning, title: "\(missing.count) 个模型没有价格",
                      detail: "这些模型的费用被记为 0，会让预估费用偏低：\(top)。可在设置里补价格，或等待价格表更新")]
    }

    static func format(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.2f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }
}
