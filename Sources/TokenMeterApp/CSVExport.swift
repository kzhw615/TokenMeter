#if os(macOS)
import AppKit
import TokenMeterCore

/// 导出当前范围为 CSV：一行 = 某天某工具某模型的用量。
/// 目的很实在：用户对账时不需要问我「这个数怎么来的」，自己拉表格比就行。
enum CSVExport {

    @MainActor
    static func makeCSV(model: AppModel, range: RangeKind, now: Date = Date()) -> String {
        UsageCSV.make(buckets: model.lastBuckets, range: range, pricing: model.lastPricing,
                      includeCache: model.includeCache, now: now)
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
