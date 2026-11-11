import Foundation
#if os(macOS)
import SQLite3
#endif

/// 会话活跃度检测：某 harness 的日志文件在最近 window 秒内被写入 ⇒ 视为「正在燃烧 token」。
/// 模型流式输出 / 工具调用都会持续刷新日志；等待用户输入时日志静止，超时后图标复原。
public enum ActivityDetector {
    public static let defaultWindow: TimeInterval = 60

    /// 每个源「顶层会话」的最后活动（排除子智能体；nil = 未安装）
    public static func topLevelActivity(now: Date = Date()) -> [(String, Date?)] {
        let farPast = now.addingTimeInterval(-1e9)
        return [
            ("Claude Code", latestMtime(under: "~/.claude/projects", suffixes: [".jsonl"], topLevelOnly: true)),
            ("Codex", latestCodexMtime(now: now, cutoff: farPast)),
            ("DSH", latestMtime(under: "~/.dsh/sessions", suffixes: [".zstd", ".jsonl"], topLevelOnly: true)),
            ("WorkBuddy", latestMtime(under: "~/.workbuddy/traces", suffixes: [".jsonl"], topLevelOnly: true)),
            ("OpenCode", fileMtime("~/.local/share/opencode/opencode.db")),
            ("Hermes", newer(fileMtime("~/.hermes/state.db"), latestMtime(under: "~/.hermes/profiles", suffixes: ["state.db"]))),
            ("ZCode", fileMtime("~/.zcode/cli/db/db.sqlite")),
        ]
    }

    /// 每个可识别 harness 的最后活动时间（nil = 本机无日志/未安装）；顺序即展示顺序
    public static func activeSources(now: Date = Date(), window: TimeInterval = defaultWindow) -> [String] {
        let cutoff = now.addingTimeInterval(-window)
        return lastActivity(now: now).compactMap { name, date in
            // WorkBuddy 以 sessions 表裁决：背景同步写日志不算燃烧
            if name == "WorkBuddy", let st = workBuddyState(now: now) {
                return st == 0 ? name : nil
            }
            if let date, date >= cutoff { return name }
            return nil
        }
    }

    public static func lastActivity(now: Date = Date()) -> [(String, Date?)] {
        let farPast = now.addingTimeInterval(-1e9)
        return [
            ("Claude Code", latestMtime(under: "~/.claude/projects", suffixes: [".jsonl"], topLevelOnly: true)),
            ("Codex", latestCodexMtime(now: now, cutoff: farPast)),
            ("DSH", latestMtime(under: "~/.dsh/sessions", suffixes: [".zstd", ".jsonl"], topLevelOnly: true)),
            ("WorkBuddy", latestMtime(under: "~/.workbuddy/traces", suffixes: [".jsonl"])),
            ("OpenCode", fileMtime("~/.local/share/opencode/opencode.db")),
            ("Hermes", newer(fileMtime("~/.hermes/state.db"), latestMtime(under: "~/.hermes/profiles", suffixes: ["state.db"]))),
            ("ZCode", fileMtime("~/.zcode/cli/db/db.sqlite")),
        ]
    }

    /// WorkBuddy 三态（macOS，基于 sessions 表真实状态；其他平台 nil 回退 mtime 启发式）：
    /// 0 运行中 = status working / active 且 60s 内活动；
    /// 1 待阅读 = 24h 内未读回执 / 最近 10min 内有 completed 会话；
    /// 2 空闲 = 其余（背景同步写日志不再误判）
    public static func workBuddyState(now: Date = Date()) -> Int? {
        #if os(macOS)
        let path = NSString(string: "~/.workbuddy/workbuddy.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        func scalar(_ sql: String) -> Int64? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(stmt, 0)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if let n = scalar("SELECT COUNT(*) FROM sessions WHERE (status='working' AND last_activity_at > \(nowMs - 120_000)) OR (status='active' AND last_activity_at > \(nowMs - 60_000))"), n > 0 {
            return 0
        }
        if let n = scalar("SELECT COUNT(*) FROM sessions WHERE unread = 1 AND last_activity_at > \(nowMs - 86_400_000)"), n > 0 {
            return 1
        }
        if let last = scalar("SELECT MAX(last_activity_at) FROM sessions WHERE status='completed'"),
           nowMs - last < 600_000 {
            return 1
        }
        return 2
        #else
        return nil
        #endif
    }

    /// WorkBuddy 真实已读态：sessions.unread=1 的会话数（macOS；其他平台 0）
    public static func workBuddyUnreadCount() -> Int {
        #if os(macOS)
        let path = NSString(string: "~/.workbuddy/workbuddy.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sessions WHERE unread = 1", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        #else
        return 0
        #endif
    }

    /// Codex 只扫今天/昨天的日期目录，避免遍历全部 6000+ 文件
    private static func latestCodexMtime(now: Date, cutoff: Date) -> Date? {
        let cal = Calendar.current
        var latest: Date?
        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "~/.codex/sessions/%04d/%02d/%02d", comps.year!, comps.month!, comps.day!)
            let d = latestMtime(under: dir, suffixes: [".jsonl", ".zst"], topLevelOnly: true)
            if let d, latest == nil || d > latest! { latest = d }
        }
        return latest
    }

    private static func latestMtime(under dir: String, suffixes: [String], topLevelOnly: Bool = false) -> Date? {
        let fm = FileManager.default
        let path = SourcePaths.expand(dir)
        guard fm.fileExists(atPath: path),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                             includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var latest: Date?
        for case let url as URL in enumerator {
            let p = url.path
            guard suffixes.contains(where: p.hasSuffix) else { continue }
            if topLevelOnly, isSubagentFile(p) { continue }
            if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if latest == nil || v > latest! { latest = v }
            }
        }
        return latest
    }

    /// 是否为子智能体（subagent）产生的会话文件 —— 这些不计入"任务是否结束"
    private static func isSubagentFile(_ path: String) -> Bool {
        // 路径级标记（Claude Code 的 subagents/ 子目录、DSH 的 subagent 分区）
        let lower = path.lowercased()
        if lower.contains("/subagent") || lower.contains("subagents/") || lower.contains("-sub-") { return true }
        // 内容级标记（Codex session_meta.thread_source == "subagent" 或含 parent_thread_id）
        // 只读文件头部 8KB，判断代价极低
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 65536), !head.isEmpty else { return false }
        let text = String(decoding: head, as: UTF8.self)
        return text.contains(#""thread_source":"subagent""#)
            || text.contains(#""source":{"subagent""#)
            || text.contains(#""type":"subagent""#)
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
