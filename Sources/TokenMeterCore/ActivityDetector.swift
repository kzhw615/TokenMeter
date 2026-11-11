import Foundation
#if os(macOS)
import SQLite3
#endif

/// 会话活跃度检测：某 harness 的日志文件在最近 window 秒内被写入 ⇒ 视为「正在燃烧 token」。
/// 模型流式输出 / 工具调用都会持续刷新日志；等待用户输入时日志静止，超时后图标复原。
public enum ActivityDetector {
    public static let defaultWindow: TimeInterval = 60

    public struct SourceActivity {
        public let name: String
        /// 任意日志文件的最后写入（用于「是否在跑」）
        public let lastActive: Date?
        /// 顶层会话（排除子智能体）的最后写入（用于「主任务是否完成」）
        public let topLevel: Date?
    }

    /// 一次遍历拿到全部源的活动信息（避免重复扫目录造成高 CPU）。
    /// 只有最近 window 内被写入的文件才会读头部判断子智能体，开销极小。
    /// 各源耗时诊断（毫秒），用于排查活动探测的性能问题
    public static func timingBreakdown() -> [(String, Double)] {
        func ms(_ block: () -> Void) -> Double {
            let t0 = Date()
            block()
            return Date().timeIntervalSince(t0) * 1000
        }
        var out: [(String, Double)] = []
        out.append(("claude", ms { _ = latestMtime(under: "~/.claude/projects", suffixes: [".jsonl"]) }))
        out.append(("codex", ms { _ = codexMtime(now: Date(), topLevelOnly: false, recentCutoff: Date().addingTimeInterval(-600)) }))
        out.append(("codex-top", ms { _ = codexMtime(now: Date(), topLevelOnly: true, recentCutoff: Date().addingTimeInterval(-600)) }))
        out.append(("dsh", ms { _ = latestMtime(under: "~/.dsh/sessions", suffixes: [".zstd", ".jsonl"]) }))
        out.append(("workbuddy", ms { _ = latestMtime(under: "~/.workbuddy/traces", suffixes: [".jsonl"]) }))
        out.append(("hermes", ms { _ = hermesMtime() }))
        out.append(("wb-state", ms { _ = workBuddyState(now: Date()) }))
        return out
    }

    public static func activitySnapshot(now: Date = Date()) -> [SourceActivity] {
        let recentCutoff = now.addingTimeInterval(-600)
        return [
            SourceActivity(name: "Claude Code",
                           lastActive: latestMtime(under: "~/.claude/projects", suffixes: [".jsonl"]),
                           topLevel: latestTopLevelMtime(under: "~/.claude/projects", suffixes: [".jsonl"], recentCutoff: recentCutoff)),
            SourceActivity(name: "Codex",
                           lastActive: newer(codexMtime(now: now, topLevelOnly: false, recentCutoff: recentCutoff),
                                             codexTurnState(now: now)?.lastActive),
                           topLevel: newer(codexMtime(now: now, topLevelOnly: true, recentCutoff: recentCutoff),
                                           codexTurnState(now: now)?.lastCompleted)),
            SourceActivity(name: "DSH",
                           lastActive: latestMtime(under: "~/.dsh/sessions", suffixes: [".zstd", ".jsonl"]),
                           topLevel: latestTopLevelMtime(under: "~/.dsh/sessions", suffixes: [".zstd", ".jsonl"], recentCutoff: recentCutoff)),
            SourceActivity(name: "WorkBuddy",
                           lastActive: latestMtime(under: "~/.workbuddy/traces", suffixes: [".jsonl"]),
                           topLevel: latestMtime(under: "~/.workbuddy/traces", suffixes: [".jsonl"])),
            SourceActivity(name: "OpenCode",
                           lastActive: fileMtime("~/.local/share/opencode/opencode.db"),
                           topLevel: fileMtime("~/.local/share/opencode/opencode.db")),
            SourceActivity(name: "Hermes",
                           lastActive: hermesMtime(),
                           topLevel: hermesMtime()),
            SourceActivity(name: "ZCode",
                           lastActive: fileMtime("~/.zcode/cli/db/db.sqlite"),
                           topLevel: fileMtime("~/.zcode/cli/db/db.sqlite")),
            SourceActivity(name: "Reasonix",
                           lastActive: latestMtime(under: "~/.reasonix", suffixes: ["usage.jsonl"]),
                           topLevel: latestMtime(under: "~/.reasonix", suffixes: ["usage.jsonl"])),
            SourceActivity(name: "Droid",
                           lastActive: latestMtime(under: "~/.factory/sessions", suffixes: [".jsonl", ".json"]),
                           topLevel: latestMtime(under: "~/.factory/sessions", suffixes: [".jsonl", ".json"])),
            SourceActivity(name: "Kiro",
                           lastActive: fileMtime("~/Library/Application Support/KiroUser/globalStorage/kiro.kiroagent/dev_data/devdata.sqlite"),
                           topLevel: fileMtime("~/Library/Application Support/KiroUser/globalStorage/kiro.kiroagent/dev_data/devdata.sqlite")),
            SourceActivity(name: "Copilot CLI",
                           lastActive: newer(fileMtime("~/.copilot/cli/state.db"), fileMtime("~/.copilot/state.db")),
                           topLevel: newer(fileMtime("~/.copilot/cli/state.db"), fileMtime("~/.copilot/state.db"))),
            SourceActivity(name: "MiniMax Code",
                           lastActive: fileMtime("~/.minimax/runtime-state.sqlite"),
                           topLevel: fileMtime("~/.minimax/runtime-state.sqlite")),
            SourceActivity(name: "Qoder",
                           lastActive: newer(newer(fileMtime("~/.qoder/db.sqlite"), fileMtime("~/.qoder-cn/db.sqlite")),
                                             newer(fileMtime("~/Library/Application Support/Qoder/db.sqlite"),
                                                   fileMtime("~/Library/Application Support/QoderCN/db.sqlite"))),
                           topLevel: newer(newer(fileMtime("~/.qoder/db.sqlite"), fileMtime("~/.qoder-cn/db.sqlite")),
                                           newer(fileMtime("~/Library/Application Support/Qoder/db.sqlite"),
                                                 fileMtime("~/Library/Application Support/QoderCN/db.sqlite")))),
        ]
    }

    /// 兼容旧接口：是否正在燃烧
    public static func activeSources(now: Date = Date(), window: TimeInterval = defaultWindow) -> [String] {
        activitySnapshot(now: now).compactMap { item in
            if item.name == "WorkBuddy", let st = workBuddyState(now: now) {
                return st == 0 ? item.name : nil
            }
            if let d = item.lastActive, now.timeIntervalSince(d) <= window { return item.name }
            return nil
        }
    }

    /// Codex 精确 turn 状态：新版 Codex（CLI/Desktop）把每轮对话记在 thread_history sqlite 里，
    /// status = inProgress / completed。比「日志 mtime」可靠得多——
    /// 被继续的会话会写回旧日期目录（如 sessions/2026/11/05/），只扫今天/昨天会完全看不到。
    public static func codexTurnState(now: Date = Date()) -> (running: Bool, lastActive: Date?, lastCompleted: Date?)? {
        #if os(macOS)
        let path = NSString(string: "~/.codex/thread_history_1.sqlite").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        func scalar(_ sql: String) -> Int64? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
        }
        let nowSec = Int64(now.timeIntervalSince1970)
        let running = (scalar("SELECT COUNT(*) FROM thread_turns WHERE status='inProgress' AND started_at > \(nowSec - 7200)") ?? 0) > 0
        let lastActive = scalar("SELECT MAX(COALESCE(completed_at, started_at)) FROM thread_turns").map { Date(timeIntervalSince1970: Double($0)) }
        let lastCompleted = scalar("SELECT MAX(completed_at) FROM thread_turns WHERE status='completed'").map { Date(timeIntervalSince1970: Double($0)) }
        return (running, lastActive, lastCompleted)
        #else
        return nil
        #endif
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
        // WorkBuddy 有真实已读回执（sessions.unread），不再用「最近 10 分钟完成过」的时间启发式：
        // 用户读掉之后必须立刻变灰，否则会一直绿着。
        if let n = scalar("SELECT COUNT(*) FROM sessions WHERE unread = 1 AND last_activity_at > \(nowMs - 86_400_000)"), n > 0 {
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

    /// Hermes 只看根库与 profiles/*/state.db（不递归 ~/.hermes，那里有十万级无关文件）
    private static func hermesMtime() -> Date? {
        var latest: Date?
        for path in HermesSource.stateDBPaths() {
            latest = newer(latest, fileMtime(path))
        }
        return latest
    }

    /// Codex 只扫今天/昨天的日期目录，避免遍历全部 6000+ 文件
    private static func codexMtime(now: Date, topLevelOnly: Bool, recentCutoff: Date) -> Date? {
        let cal = Calendar.current
        var latest: Date?
        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "~/.codex/sessions/%04d/%02d/%02d", comps.year!, comps.month!, comps.day!)
            let d = topLevelOnly
                ? latestTopLevelMtime(under: dir, suffixes: [".jsonl", ".zst"], recentCutoff: recentCutoff)
                : latestMtime(under: dir, suffixes: [".jsonl", ".zst"])
            if let d, latest == nil || d > latest! { latest = d }
        }
        return latest
    }

    /// 顶层会话的最后写入时间：只对「近期被写入」的文件读头部判子智能体，
    /// 更早的文件直接按 mtime 计入（不可能是最大值来源，省掉全部文件 IO）
    private static func latestTopLevelMtime(under dir: String, suffixes: [String], recentCutoff: Date) -> Date? {
        let fm = FileManager.default
        let path = SourcePaths.expand(dir)
        guard fm.fileExists(atPath: path),
              let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                             includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var recent: [(String, Date)] = []
        var olderMax: Date?
        for case let url as URL in enumerator {
            let p = url.path
            guard suffixes.contains(where: p.hasSuffix) else { continue }
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if v >= recentCutoff { recent.append((p, v)) }
            else if olderMax == nil || v > olderMax! { olderMax = v }
        }
        var latest = olderMax
        for (p, v) in recent.sorted(by: { $0.1 > $1.1 }) {
            if isSubagentFile(p) { continue }
            if latest == nil || v > latest! { latest = v }
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
