import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if os(macOS)
import SQLite3
#endif

/// 会话活跃度检测：某 harness 的日志文件在最近 window 秒内被写入 ⇒ 视为「正在燃烧 token」。
/// 模型流式输出 / 工具调用都会持续刷新日志；等待用户输入时日志静止，超时后图标复原。
public enum ActivityDetector {
    public static let defaultWindow: TimeInterval = 60

    /// 各 harness 的桌面宿主 App（bundle id，已知的精确匹配）。
    public static let sourceBundleIDs: [String: String] = [
        "Codex": "com.openai.codex",
        "DSH": "com.deepseek.dsh",
        "WorkBuddy": "com.tencent.workbuddy.mac",
    ]

    /// 该数据源的「状态判定依据」——用于悬浮时告诉用户这个灯是「确定」还是「推断」
    public static func stateBasis(for source: String) -> String {
        switch source {
        case "WorkBuddy": return "依据：WorkBuddy 真实已读状态"
        case "Codex": return "依据：Codex 任务状态库"
        case "DSH": return "依据：DSH 会话锁 + 日志事件"
        default: return "依据：日志写入时间（推断）"
        }
    }

    /// 坞内空间小，给出极简依据标签
    public static func shortBasis(for source: String) -> String {
        switch source {
        case "WorkBuddy": return "真实已读"
        case "Codex": return "任务状态库"
        case "DSH": return "会话锁"
        default: return "日志时间"
        }
    }

    /// 名字关键词 → 数据源（前台 App 名称命中即认为该工具正在被查看）：当前台 App 的名字包含关键词时，认为是该工具的宿主 App。
    /// 覆盖面比硬编码 bundle id 广（Kiro / Qoder / ZCode / OpenCode 等装了桌面版就能识别）。
    /// 前台 App 名称关键词表：命中即视为「用户正在看该工具」
    public static let hostAppKeywords: [(String, [String])] = [
        // Claude Code 可能通过桌面客户端 / Obsidian 插件（Claudian）驱动
        ("Claude Code", ["claude", "claudian", "anthropic"]),
        ("Codex", ["codex"]),
        ("DSH", ["deepseek", "dsh"]),
        ("WorkBuddy", ["workbuddy"]),
        ("Kiro", ["kiro"]),
        ("Qoder", ["qoder"]),
        ("ZCode", ["zcode"]),
        ("Hermes", ["hermes"]),
        ("OpenCode", ["opencode"]),
        ("Droid", ["droid", "factory"]),
        ("MiniMax Code", ["minimax"]),
        ("Reasonix", ["reasonix"]),
        ("Copilot CLI", ["copilot"]),
    ]

    /// 该数据源是否有「可判断已读」的宿主 App 信号
    public static func hasHostAppSignal(for source: String) -> Bool {
        if sourceBundleIDs[source] != nil { return true }
        return hostAppKeywords.contains { $0.0 == source }
    }

    public static func sourceName(matching appName: String?, bundleID: String?) -> String? {
        let hay = [appName, bundleID].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !hay.isEmpty else { return nil }
        let keywords = hostAppKeywords
        for (source, words) in keywords where words.contains(where: hay.contains) {
            return source
        }
        return nil
    }

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
    /// 读取 Claude Code hooks 写入的状态（最精确的信号来源）。
    /// 返回 nil 表示没装 hook 或状态太旧，调用方回退到日志解析。
    public static func claudeHookState(now: Date = Date()) -> (running: Bool, at: Date, cwd: String)? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("claude-state.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let sessions = obj["sessions"] as? [String: Any], !sessions.isEmpty else { return nil }

        var anyRunning = false
        var newest: Date?
        var cwd = ""
        for (_, value) in sessions {
            guard let e = value as? [String: Any],
                  let at = (e["at"] as? Double) ?? (e["at"] as? NSNumber)?.doubleValue else { continue }
            let date = Date(timeIntervalSince1970: at)
            // 单会话超过 10 分钟没心跳视为已失效（避免崩溃/强退导致灯常亮）
            guard now.timeIntervalSince(date) < 600 else { continue }
            if (e["running"] as? Bool) == true { anyRunning = true }
            if newest == nil || date > newest! {
                newest = date
                cwd = (e["cwd"] as? String) ?? ""
            }
        }
        guard let last = newest else { return nil }
        return (anyRunning, last, cwd)
    }

    /// Claude Code 是否正被「Obsidian 插件（如 Claudian）」查看。
    /// 这类客户端跑在 Obsidian 里，前台 App 永远是 Obsidian，只能靠
    /// 「最新会话的工作目录是个装了 claudian 插件的 vault」来推断。
    public static func claudeViewedInObsidian(frontName: String?, frontBundle: String?) -> Bool {
        let front = [frontName ?? "", frontBundle ?? ""].joined(separator: " ").lowercased()
        guard front.contains("obsidian") else { return false }
        guard let vault = newestClaudeProjectPath() else { return false }
        return vaultHasClaudianPlugin(vault)
    }

    private static var claudeVaultCache: (at: Date, path: String?)?

    /// 从会话日志开头提取 cwd（只读前 256KB）
    static func cwdFromLog(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 256 * 1024) else { return nil }
        for line in LineReader.split(data) {
            guard line.contains("\"cwd\"") else { continue }
            if let o = JSONUtil.object(line), let cwd = JSONUtil.string(o, "cwd"), !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    /// 最新 Claude 会话所属项目路径（由 projects 目录名解码，缓存 30 秒）
    public static func newestClaudeProjectPath() -> String? {
        let now = Date()
        if let c = claudeVaultCache, now.timeIntervalSince(c.at) < 30 { return c.path }
        let base = SourcePaths.expand("~/.claude/projects")
        var newest: (dir: String, mtime: Date)?
        if let projects = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for project in projects {
                let dir = base + "/" + project
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for f in files where f.hasSuffix(".jsonl") {
                    guard let m = SourcePaths.mtime(dir + "/" + f) else { continue }
                    if newest == nil || m > newest!.mtime { newest = (dir, m) }
                }
            }
        }
        // 目录名编码有损（中文会变成 ----），直接读日志里的 cwd 更可靠
        var path: String?
        if let dir = newest?.dir,
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
           let newestFile = files.filter({ $0.hasSuffix(".jsonl") })
               .max(by: { (SourcePaths.mtime(dir + "/" + $0) ?? .distantPast) < (SourcePaths.mtime(dir + "/" + $1) ?? .distantPast) }) {
            path = Self.cwdFromLog(dir + "/" + newestFile)
        }
        claudeVaultCache = (now, path)
        return path
    }

    private static var claudianCache: [String: (at: Date, has: Bool)] = [:]

    /// 该目录是否装了 claudian 插件（缓存 60 秒）
    public static func vaultHasClaudianPlugin(_ path: String) -> Bool {
        let now = Date()
        if let c = claudianCache[path], now.timeIntervalSince(c.at) < 60 { return c.has }
        let plugins = path + "/.obsidian/plugins"
        var has = false
        if let names = try? FileManager.default.contentsOfDirectory(atPath: plugins) {
            has = names.contains { $0.lowercased().contains("claudian") }
        }
        claudianCache[path] = (now, has)
        return has
    }

    /// Claude Code 是否仍在推进：读最新会话日志尾部，看最后一条事件的语义。
    /// - assistant.stop_reason == tool_use ⇒ 在跑工具（运行中）
    /// - assistant.stop_reason == end_turn / max_tokens ⇒ 本轮已结束
    /// - user 里带 tool_result ⇒ 工具刚返回，agent 会继续
    /// 返回 nil 表示无法判断（回退到日志时间）。
    public static func claudeTaskRunning(now: Date = Date()) -> Bool? {
        #if os(macOS)
        let base = SourcePaths.expand("~/.claude/projects")
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        var newest: (path: String, mtime: Date)?
        for project in projects {
            let dir = base + "/" + project
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                guard let m = SourcePaths.mtime(p) else { continue }
                if newest == nil || m > newest!.mtime { newest = (p, m) }
            }
        }
        guard let target = newest else { return nil }
        // 超过 15 分钟没有任何写入，必然已结束
        if now.timeIntervalSince(target.mtime) > 900 { return false }

        guard let fh = FileHandle(forReadingAtPath: target.path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let window: UInt64 = 256 * 1024
        let start: UInt64 = size > window ? size - window : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }

        var lines = LineReader.split(data)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // 首行可能被截断
        for line in lines.reversed() {
            guard let o = JSONUtil.object(line), let type = JSONUtil.string(o, "type") else { continue }
            switch type {
            case "assistant":
                guard let msg = JSONUtil.dict(o, "message") else { continue }
                let stop = JSONUtil.string(msg, "stop_reason") ?? ""
                if stop.contains("tool") { return true }       // 正在等工具结果
                return false                                   // end_turn / max_tokens 等
            case "user":
                // 工具返回后 agent 会继续；真实用户提问同理
                return true
            case "result", "last-prompt":
                return false
            default:
                continue
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// WorkBuddy 三态。
    /// 注意：DB 的 last_activity_at 只在若干事件点更新（实测可落后 3 分钟以上），
    /// 单靠它会把正在跑的长任务判成空闲；真正的活跃信号是 traces 目录里持续追加的日志。
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
        let freshWindow: Int64 = 180_000   // 3 分钟：容住 DB 活动时间的滞后

        // ① 运行中：DB 里存在 working 会话，且「trace 正在写」或「DB 活动时间够新」
        let workingLast = scalar("SELECT MAX(last_activity_at) FROM sessions WHERE status='working'")
        if let last = workingLast, last > 0 {
            if nowMs - last <= freshWindow { return 0 }
            if workBuddyTracesActive(now: now) { return 0 }
        }
        if let n = scalar("SELECT COUNT(*) FROM sessions WHERE status='active' AND last_activity_at > \(nowMs - 60_000)"), n > 0 {
            return 0
        }
        // ② 待阅读：有未读会话
        if let n = scalar("SELECT COUNT(*) FROM sessions WHERE unread = 1 AND last_activity_at > \(nowMs - 86_400_000)"), n > 0 {
            return 1
        }
        return 2
        #else
        return nil
        #endif
    }

    /// traces 目录里是否还有近期写入（缓存 10 秒，避免每轮都 stat 数百个文件）
    private static var tracesCache: (at: Date, active: Bool)?
    public static func workBuddyTracesActive(now: Date = Date(), window: TimeInterval = 120) -> Bool {
        if let c = tracesCache, now.timeIntervalSince(c.at) < 10 { return c.active }
        let fm = FileManager.default
        let base = SourcePaths.expand("~/.workbuddy/traces")
        var newest: Date?
        if let names = try? fm.contentsOfDirectory(atPath: base) {
            for name in names {
                let dir = base + "/" + name
                guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for f in files where f.hasSuffix(".jsonl") {
                    let p = dir + "/" + f
                    if let m = try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date,
                       m > (newest ?? .distantPast) { newest = m }
                }
            }
        }
        let active = newest.map { now.timeIntervalSince($0) <= window } ?? false
        tracesCache = (now, active)
        return active
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
    /// Hermes 只看根库与 profiles/*/state.db。
    /// 路径逻辑在此内联（不依赖 HermesSource）：后者依赖 SQLite3，仅 macOS 编译，
    /// 早期直接调用会让 Linux/Windows 编译失败。
    private static func hermesMtime() -> Date? {
        let fm = FileManager.default
        var paths = [SourcePaths.expand("~/.hermes/state.db")]
        let profiles = SourcePaths.expand("~/.hermes/profiles")
        if let names = try? fm.contentsOfDirectory(atPath: profiles) {
            paths += names.map { profiles + "/" + $0 + "/state.db" }
        }
        var latest: Date?
        for path in paths where fm.fileExists(atPath: path) {
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
