#if os(macOS)
import AppKit
import TokenMeterCore

/// 导出当前范围为 CSV：一行 = 某天某工具某模型的用量。
/// 目的很实在：用户对账时不需要问我「这个数怎么来的」，自己拉表格比就行。
enum CSVExport {

    @MainActor
    static func makeCSV(model: AppModel, range: RangeKind, now: Date = Date()) -> String {
        let start = range.startDayKey(now: now)
        let end = range.endDayKey(now: now)
        let buckets = model.lastBuckets.filter { b in
            if let start, b.day < start { return false }
            if let end, b.day > end { return false }
            return true
        }
        var lines = ["日期,工具,模型,项目,输入,输出,缓存读,缓存写,合计,费用(USD),请求数"]
        let pricing = model.lastPricing
        for b in buckets.sorted(by: { ($0.day, $0.tool, $0.model) < ($1.day, $1.tool, $1.model) }) {
            let model0 = Aggregator.normalizedModel(b.model)
            let cost = pricing.cost(for: b.counts, model: model0)
            lines.append([
                b.day,
                escape(b.tool),
                escape(model0),
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

    /// 弹保存面板并写文件；失败时把原因写回面板底部提示
    @MainActor
    static func present(model: AppModel, range: RangeKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TokenMeter-\(range.rawValue)-\(DayKey.key(for: Date())).csv"
        panel.canCreateDirectories = true
        panel.title = "导出用量明细"
        panel.message = "当前范围：\(range.label)（\(CSVExport.makeCSV(model: model, range: range).split(separator: "\n").count - 2) 行数据）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = makeCSV(model: model, range: range)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            model.settingsMessage = "已导出到 \(url.lastPathComponent)"
        } catch {
            model.settingsMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
#endif
