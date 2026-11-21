import Foundation
#if os(macOS)
import SQLite3
#endif

/// 二线数据源：本机未必存在，存在即自动启用。
/// 日志格式参考各产品本地落盘结构。

enum Flex {
    static let inputKeys = ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens", "tokens_prompt", "input"]
    static let outputKeys = ["output_tokens", "outputTokens", "completion_tokens", "completionTokens", "tokens_generated", "generatedTokens", "output"]
    static let cacheReadKeys = ["cache_read_tokens", "cacheReadTokens", "cached_tokens", "cachedTokens", "cache_read_input_tokens", "cacheReadInputTokens", "tokens_cache_read", "cacheHitTokens"]
    static let cacheWriteKeys = ["cache_write_tokens", "cacheWriteTokens", "cache_creation_tokens", "cacheCreationTokens", "cache_write_input_tokens", "cacheCreationInputTokens", "tokens_cache_write", "cacheMissTokens"]
    static let modelKeys = ["model", "model_id", "modelId", "modelID", "generation_model", "model_name"]
    static let tsKeys = ["ts", "timestamp", "created_at", "createdAt", "gmt_create", "started_at", "time", "created"]

    static func first(_ d: [String: Any], _ keys: [String]) -> Int64? {
        for k in keys { if let v = JSONUtil.intOrNil(d, k) { return v } }
        return nil
    }

    static func counts(_ d: [String: Any]) -> TokenCounts? {
        guard let i = first(d, inputKeys), let o = first(d, outputKeys) else { return nil }
        return TokenCounts(input: i, output: o,
                           cacheRead: first(d, cacheReadKeys) ?? 0,
                           cacheWrite: first(d, cacheWriteKeys) ?? 0)
    }

    static func model(_ d: [String: Any]) -> String {
        for k in modelKeys { if let s = JSONUtil.string(d, k), !s.isEmpty { return s } }
        return "unknown"
    }

    /// 秒/毫秒自适应
    static func date(_ d: [String: Any]) -> Date {
        for k in tsKeys {
            if let v = JSONUtil.intOrNil(d, k), v > 0 {
                return v > 100_000_000_000 ? JSONUtil.dateFromMillis(v) : Date(timeIntervalSince1970: Double(v))
            }
        }
        return Date()
    }
}

#if os(macOS)
/// 通用 SQLite 用量源：SQL 固定返回 6 列 model, input, output, cacheRead, cacheWrite, ts
struct SqlUsageSource: UsageSource {
    let id: String
    let displayName: String
    let dbPaths: [String]
    let sql: String
    var enabledByDefault: Bool { true }

    func scan(cache: inout ScanCache) -> ScanResult {
        for raw in dbPaths {
            let dbPath = SourcePaths.expand(raw)
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            if let c = cache.cachedBuckets(path: dbPath) {
                return ScanResult(buckets: c, files: 1)
            }
            let buckets = parse(dbPath: dbPath)
            cache.store(path: dbPath, buckets: buckets)
            return ScanResult(buckets: buckets, files: 1)
        }
        return ScanResult()
    }

    private func parse(dbPath: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: displayName)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            let counts = TokenCounts(input: sqlite3_column_int64(stmt, 1),
                                     output: sqlite3_column_int64(stmt, 2),
                                     cacheRead: sqlite3_column_int64(stmt, 3),
                                     cacheWrite: sqlite3_column_int64(stmt, 4))
            guard counts.total > 0 else { continue }
            let t = sqlite3_column_int64(stmt, 5)
            let date = t > 100_000_000_000 ? JSONUtil.dateFromMillis(t) : (t > 0 ? Date(timeIntervalSince1970: Double(t)) : Date())
            builder.add(date: date, model: model.isEmpty ? "unknown" : model, counts: counts)
        }
        return builder.buckets
    }

    /// 新版（Electron/macOS）schema：chat_session_messages.payload_json + chat_sessions.cwd。
    /// 目前 Qoder 并不在本地记录 token 用量，这里按「有就取、没有就跳过」处理，
    /// 这样将来它一旦开始写 usage，我们无需再改代码就能统计到。
    private func parseElectron(db: OpaquePointer, builder: BucketBuilder) -> Bool {
        // 表不存在就直接返回 false，回退到老 schema
        var probe: OpaquePointer?
        let probeSQL = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_session_messages' LIMIT 1"
        guard sqlite3_prepare_v2(db, probeSQL, -1, &probe, nil) == SQLITE_OK, let probe else { return false }
        let exists = sqlite3_step(probe) == SQLITE_ROW
        sqlite3_finalize(probe)
        guard exists else { return false }

        let sql = """
        SELECT m.payload_json, m.created_at, coalesce(nullif(s.cwd,''),''), coalesce(nullif(s.model,''),'')
        FROM chat_session_messages m
        LEFT JOIN chat_sessions s ON s.session_id = m.session_id
        WHERE m.role = 'assistant'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let payload = String(cString: cstr)
            guard payload.contains("token") else { continue }
            guard let data = payload.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let counts = Self.electronUsage(root), counts.total > 0 else { continue }
            found = true
            let ts = sqlite3_column_int64(stmt, 1)
            let date = ts > 100_000_000_000 ? JSONUtil.dateFromMillis(ts)
                       : (ts > 0 ? Date(timeIntervalSince1970: Double(ts)) : Date())
            let cwd = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sessionModel = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let model = Self.electronModel(root) ?? (sessionModel.isEmpty ? "unknown" : sessionModel)
            if !cwd.isEmpty { builder.project = ProjectName.basename(cwd) }
            builder.add(date: date, model: model, counts: counts)
        }
        return found
    }

    /// 在 payload 里找形如 usage 的字段（不同版本命名不一，尽量兼容）
    static func electronUsage(_ root: [String: Any]) -> TokenCounts? {
        func ints(_ d: [String: Any]) -> TokenCounts? {
            func pick(_ keys: [String]) -> Int64 {
                for k in keys { if let v = d[k] as? NSNumber { return v.int64Value }
                    if let v = d[k] as? Int64 { return v } }
                return 0
            }
            let c = TokenCounts(
                input: pick(["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"]),
                output: pick(["output_tokens", "outputTokens", "completion_tokens", "completionTokens"]),
                cacheRead: pick(["cache_read_input_tokens", "cacheReadInputTokens", "cacheRead", "cached_tokens"]),
                cacheWrite: pick(["cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWrite"])
            )
            return c.total > 0 ? c : nil
        }
        for key in ["usage", "tokenUsage", "token_usage", "usageInfo"] {
            if let d = root[key] as? [String: Any], let c = ints(d) { return c }
        }
        if let meta = root["metadata"] as? [String: Any],
           let d = meta["usage"] as? [String: Any], let c = ints(d) { return c }
        // parts 里也可能挂 usage
        if let parts = root["parts"] as? [[String: Any]] {
            for p in parts {
                if let d = p["usage"] as? [String: Any], let c = ints(d) { return c }
            }
        }
        return nil
    }

    static func electronModel(_ root: [String: Any]) -> String? {
        for key in ["model", "modelId", "model_id", "modelName"] {
            if let s = root[key] as? String, !s.isEmpty { return s }
        }
        if let m = root["model"] as? [String: Any], let s = m["id"] as? String { return s }
        if let meta = root["metadata"] as? [String: Any], let s = meta["model"] as? String { return s }
        return nil
    }
}

#endif

/// 通用 JSONL 用量源：每行找 tokenUsage / usage 子对象（或行本身）
struct JsonlUsageSource: UsageSource {
    let id: String
    let displayName: String
    let dirs: [String]
    let suffixes: [String]
    var enabledByDefault: Bool { true }

    func scan(cache: inout ScanCache) -> ScanResult {
        var files: [String] = []
        for d in dirs {
            for s in suffixes { files += SourcePaths.files(under: d, suffix: s) }
        }
        let builder = BucketBuilder(tool: displayName)
        for path in files {
            if let c = cache.cachedBuckets(path: path) { builder.merge(c); continue }
            let local = parse(path: path)
            cache.store(path: path, buckets: local)
            builder.merge(local)
        }
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    private func parse(path: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: displayName)
        guard let reader = LineReader(path: path) else { return [] }
        reader.forEachLine { line in
            guard line.contains("okens") else { return }
            guard let o = JSONUtil.object(line) else { return }
            let holder: [String: Any]
            if let u = JSONUtil.dict(o, "tokenUsage") { holder = u }
            else if let u = JSONUtil.dict(o, "usage") { holder = u }
            else if let u = JSONUtil.dict(o, "data"), let uu = JSONUtil.dict(u, "usage") { holder = uu }
            else { holder = o }
            guard let counts = Flex.counts(holder), counts.total > 0 else { return }
            let model = Flex.model(o) == "unknown" ? Flex.model(holder) : Flex.model(o)
            builder.add(date: Flex.date(o), model: model, counts: counts)
        }
        return builder.buckets
    }
}

#if os(macOS)
/// Qoder：chat_message 表的 token_info / model_info 为 JSON 字符串
struct QoderSource: UsageSource {
    public var id: String { "qoder" }
    public var displayName: String { "Qoder" }
    public var enabledByDefault: Bool { true }

    private var dbPaths: [String] {
        var out = ["~/.qoder/db.sqlite", "~/.qoder-cn/db.sqlite",
                   "~/Library/Application Support/Qoder/db.sqlite",
                   "~/Library/Application Support/QoderCN/db.sqlite",
                   // macOS 版 Qoder 是 Electron 应用：聊天记录落在 main.sqlite 里，
                   // 表结构也换成了 chat_session_messages(payload_json) + chat_sessions(cwd)
                   "~/Library/Application Support/com.qodercn.app.stable/main.sqlite",
                   "~/Library/Application Support/com.qoder.app.stable/main.sqlite"]
        if let env = ProcessInfo.processInfo.environment["QODER_BASE_PATH"] {
            out.append(env + "/db.sqlite")
        }
        return out
    }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        for raw in dbPaths {
            let dbPath = SourcePaths.expand(raw)
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            if let c = cache.cachedBuckets(path: dbPath) {
                let note: String? = (dbPath.hasSuffix("main.sqlite") && c.isEmpty)
                    ? "该版本 Qoder 未在本地记录 token 用量" : nil
                return ScanResult(buckets: c, files: 1, note: note)
            }
            // Electron 版主库是 400MB+ 的活跃库，指纹几乎每次刷新都变；
            // 而当前 Qoder 根本不写 token 用量，解析一次要 2.3 秒纯属浪费。
            // 用一个 6 小时的探测标记：库里确实没有 usage 就短期内不再全量解析。
            let probeKey = "__probe:qoder-electron:\(dbPath)"
            if dbPath.hasSuffix("main.sqlite"),
               let stamp = cache.threadModels?[probeKey],
               let at = Double(stamp), Date().timeIntervalSince1970 - at < 6 * 3600 {
                return ScanResult(files: 1, note: "该版本 Qoder 未在本地记录 token 用量")
            }
            let buckets = parse(dbPath: dbPath)
            cache.store(path: dbPath, buckets: buckets)
            return ScanResult(buckets: buckets, files: 1)
        }
        return ScanResult()
    }

    /// 供单元测试直接喂构造好的数据库
    public func parseForTest(dbPath: String) -> [UsageBucket] { parse(dbPath: dbPath) }

    private func parse(dbPath: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "Qoder")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        if parseElectron(db: db, builder: builder) { return builder.buckets }
        let sql = "SELECT COALESCE(model_info,''), COALESCE(token_info,''), gmt_create FROM chat_message WHERE token_info IS NOT NULL AND token_info != ''"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let modelInfo = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let tokenInfo = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let ts = sqlite3_column_int64(stmt, 2)
            guard let tData = tokenInfo.data(using: .utf8),
                  let usage = (try? JSONSerialization.jsonObject(with: tData)) as? [String: Any],
                  let counts = Flex.counts(usage), counts.total > 0 else { continue }
            var model = "unknown"
            if let mData = modelInfo.data(using: .utf8),
               let mi = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] {
                model = Flex.model(mi)
            }
            let date = ts > 100_000_000_000 ? JSONUtil.dateFromMillis(ts) : (ts > 0 ? Date(timeIntervalSince1970: Double(ts)) : Date())
            builder.add(date: date, model: model, counts: counts)
        }
        return builder.buckets
    }

    /// 新版（Electron/macOS）schema：chat_session_messages.payload_json + chat_sessions.cwd。
    /// 目前 Qoder 并不在本地记录 token 用量，这里按「有就取、没有就跳过」处理，
    /// 这样将来它一旦开始写 usage，我们无需再改代码就能统计到。
    private func parseElectron(db: OpaquePointer, builder: BucketBuilder) -> Bool {
        // 表不存在就直接返回 false，回退到老 schema
        var probe: OpaquePointer?
        let probeSQL = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_session_messages' LIMIT 1"
        guard sqlite3_prepare_v2(db, probeSQL, -1, &probe, nil) == SQLITE_OK, let probe else { return false }
        let exists = sqlite3_step(probe) == SQLITE_ROW
        sqlite3_finalize(probe)
        guard exists else { return false }

        let sql = """
        SELECT m.payload_json, m.created_at, coalesce(nullif(s.cwd,''),''), coalesce(nullif(s.model,''),'')
        FROM chat_session_messages m
        LEFT JOIN chat_sessions s ON s.session_id = m.session_id
        WHERE m.role = 'assistant'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let payload = String(cString: cstr)
            guard payload.contains("token") else { continue }
            guard let data = payload.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let counts = Self.electronUsage(root), counts.total > 0 else { continue }
            found = true
            let ts = sqlite3_column_int64(stmt, 1)
            let date = ts > 100_000_000_000 ? JSONUtil.dateFromMillis(ts)
                       : (ts > 0 ? Date(timeIntervalSince1970: Double(ts)) : Date())
            let cwd = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sessionModel = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let model = Self.electronModel(root) ?? (sessionModel.isEmpty ? "unknown" : sessionModel)
            if !cwd.isEmpty { builder.project = ProjectName.basename(cwd) }
            builder.add(date: date, model: model, counts: counts)
        }
        return found
    }

    /// 在 payload 里找形如 usage 的字段（不同版本命名不一，尽量兼容）
    static func electronUsage(_ root: [String: Any]) -> TokenCounts? {
        func ints(_ d: [String: Any]) -> TokenCounts? {
            func pick(_ keys: [String]) -> Int64 {
                for k in keys { if let v = d[k] as? NSNumber { return v.int64Value }
                    if let v = d[k] as? Int64 { return v } }
                return 0
            }
            let c = TokenCounts(
                input: pick(["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"]),
                output: pick(["output_tokens", "outputTokens", "completion_tokens", "completionTokens"]),
                cacheRead: pick(["cache_read_input_tokens", "cacheReadInputTokens", "cacheRead", "cached_tokens"]),
                cacheWrite: pick(["cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWrite"])
            )
            return c.total > 0 ? c : nil
        }
        for key in ["usage", "tokenUsage", "token_usage", "usageInfo"] {
            if let d = root[key] as? [String: Any], let c = ints(d) { return c }
        }
        if let meta = root["metadata"] as? [String: Any],
           let d = meta["usage"] as? [String: Any], let c = ints(d) { return c }
        // parts 里也可能挂 usage
        if let parts = root["parts"] as? [[String: Any]] {
            for p in parts {
                if let d = p["usage"] as? [String: Any], let c = ints(d) { return c }
            }
        }
        return nil
    }

    static func electronModel(_ root: [String: Any]) -> String? {
        for key in ["model", "modelId", "model_id", "modelName"] {
            if let s = root[key] as? String, !s.isEmpty { return s }
        }
        if let m = root["model"] as? [String: Any], let s = m["id"] as? String { return s }
        if let meta = root["metadata"] as? [String: Any], let s = meta["model"] as? String { return s }
        return nil
    }
}

#endif

enum ExtraSources {
    static func all() -> [UsageSource] {
        var out: [UsageSource] = [
            JsonlUsageSource(id: "reasonix", displayName: "Reasonix",
                             dirs: ["~/.reasonix"], suffixes: ["usage.jsonl"]),
            JsonlUsageSource(id: "droid", displayName: "Droid",
                             dirs: ["~/.factory/sessions"], suffixes: [".jsonl", ".json"]),
        ]
        #if os(macOS)
        out += [
            SqlUsageSource(id: "kiro", displayName: "Kiro",
                           dbPaths: ["~/Library/Application Support/KiroUser/globalStorage/kiro.kiroagent/dev_data/devdata.sqlite"],
                           sql: "SELECT COALESCE(model,'unknown'), tokens_prompt, tokens_generated, 0, 0, timestamp FROM tokens_generated"),
            SqlUsageSource(id: "copilot-cli", displayName: "Copilot CLI",
                           dbPaths: ["~/.copilot/cli/state.db", "~/.copilot/state.db"],
                           sql: "SELECT COALESCE(model,'unknown'), input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, ts FROM local_runtime_token_usage"),
            SqlUsageSource(id: "minimax", displayName: "MiniMax Code",
                           dbPaths: ["~/.minimax/runtime-state.sqlite"],
                           sql: "SELECT COALESCE(model,'unknown'), input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, create_time FROM token_usage"),
            QoderSource(),
            AntigravitySource(),
        ]
        #endif
        return out
    }
}
