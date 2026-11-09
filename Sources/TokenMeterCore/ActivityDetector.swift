import Foundation

/// 会话活跃度检测：某 harness 的日志文件在最近 window 秒内被写入 ⇒ 视为「正在燃烧 token」。
/// 模型流式输出 / 工具调用都会持续刷新日志；等待用户输入时日志静止，超时后图标复原。
public enum ActivityDetector {
    public static let defaultWindow: TimeInterval = 120

    public static func activeSources(now: Date = Date(), window: TimeInterval = defaultWindow) -> [String] {
        let cutoff = now.addingTimeInterval(-window)
        var out: [String] = []

        func hot(_ name: String, _ date: Date?) {
            if let date, date >= cutoff { out.append(name) }
        }

        hot("Claude Code", latestMtime(under: "~/.claude/projects", suffixes: [".jsonl"]))
        hot("Codex", latestCodexMtime(now: now, cutoff: cutoff))
        hot("DSH", latestMtime(under: "~/.dsh/sessions", suffixes: [".zstd", ".jsonl"]))
        hot("WorkBuddy", latestMtime(under: "~/.workbuddy/traces", suffixes: [".jsonl"]))
        hot("OpenCode", fileMtime("~/.local/share/opencode/opencode.db"))
        hot("Hermes", newer(fileMtime("~/.hermes/state.db"), latestMtime(under: "~/.hermes/profiles", suffixes: ["state.db"])))
        hot("ZCode", fileMtime("~/.zcode/cli/db/db.sqlite"))
        return out
    }

    /// Codex 只扫今天/昨天的日期目录，避免遍历全部 6000+ 文件
    private static func latestCodexMtime(now: Date, cutoff: Date) -> Date? {
        let cal = Calendar.current
        var latest: Date?
        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "~/.codex/sessions/%04d/%02d/%02d", comps.year!, comps.month!, comps.day!)
            let d = latestMtime(under: dir, suffixes: [".jsonl", ".zst"])
            if let d, latest == nil || d > latest! { latest = d }
        }
        return latest
    }

    private static func latestMtime(under dir: String, suffixes: [String]) -> Date? {
        let fm = FileManager.default
        let path = SourcePaths.expand(dir)
        guard fm.fileExists(atPath: path),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                             includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var latest: Date?
        for case let url as URL in enumerator {
            let p = url.path
            guard suffixes.contains(where: p.hasSuffix) else { continue }
            if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if latest == nil || v > latest! { latest = v }
            }
        }
        return latest
    }

    private static func fileMtime(_ path: String) -> Date? {
        let p = SourcePaths.expand(path)
        return try? URL(fileURLWithPath: p).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func newer(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return a > b ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}
