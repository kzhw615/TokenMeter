#if os(macOS)
import Foundation
import SQLite3

/// OpenCode：~/.local/share/opencode/opencode.db
/// 兼容两套表结构：
/// - 旧：message + session，data: {modelID, tokens:{...}, time:{created}}
/// - 新：session_message + session_v2，data: {model:{id}, tokens:{...}, time:{created}}
///   （OpenChamber 这类客户端自带新版 opencode CLI，写的正是新表）
public struct OpenCodeSource: UsageSource {
    public var id: String { "opencode" }
    public var displayName: String { "OpenCode" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let dbPath = SourcePaths.expand("~/.local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ScanResult(note: nil)
        }
        // sqlite 文件指纹用 db 文件本身
        if let cached = cache.cachedBuckets(path: dbPath) {
            return ScanResult(buckets: cached, files: 1)
        }
        let buckets = parse(dbPath: dbPath)
        cache.store(path: dbPath, buckets: buckets)
        return ScanResult(buckets: buckets, files: 1)
    }

    private func parse(dbPath: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "OpenCode")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        /// 统一从一行 `data` JSON 里取用量并累加。
        /// - 新 schema：tokens 在顶层，模型在 model.id
        /// - 旧 schema：tokens 在顶层，模型在 modelID
        func consume(dataJSON: String, directory: String?, modelKey: String) {
            guard let o = JSONUtil.object(dataJSON),
                  let tokens = JSONUtil.dict(o, "tokens") else { return }
            let input = JSONUtil.int(tokens, "input")
            // reasoning 单独计数但不含在 output 里，需要相加
            let output = JSONUtil.int(tokens, "output") + JSONUtil.int(tokens, "reasoning")
            var cacheRead: Int64 = 0
            var cacheWrite: Int64 = 0
            if let cache = JSONUtil.dict(tokens, "cache") {
                cacheRead = JSONUtil.int(cache, "read")
                cacheWrite = JSONUtil.int(cache, "write")
            }
            let counts = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            guard counts.total > 0 else { return }
            var model = "unknown"
            if modelKey == "model.id", let m = JSONUtil.dict(o, "model") {
                model = JSONUtil.string(m, "id") ?? "unknown"
            } else {
                model = JSONUtil.string(o, modelKey) ?? "unknown"
            }
            if let dir = directory, !dir.isEmpty {
                builder.project = ProjectName.basename(dir)
            }
            var date = Date()
            if let time = JSONUtil.dict(o, "time"), let created = JSONUtil.intOrNil(time, "created") {
                date = JSONUtil.dateFromMillis(created)
            }
            builder.add(date: date, model: model, counts: counts)
        }

        func run(_ sql: String, modelKey: String) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                let json = String(cString: cstr)
                let dir = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                consume(dataJSON: json, directory: dir, modelKey: modelKey)
            }
        }

        // ① 新 schema（opencode ≥ 新版本 / OpenChamber 自带 CLI）：
        //    session_v2 + session_message，assistant 消息的 data 里带 tokens 与 model.id
        run("""
            select sm.data, v.directory from session_message sm
            left join session_v2 v on v.id = sm.session_id
            where sm.type = 'assistant' and sm.data like '%"tokens"%'
            """, modelKey: "model.id")

        // ② 旧 schema：message + session。
        //    已迁移到新表的会话不再读，避免同一会话被算两次。
        run("""
            select m.data, s.directory from message m
            left join session s on s.id = m.session_id
            where m.data like '%"tokens"%'
              and m.session_id not in (select session_id from session_message)
            """, modelKey: "modelID")

        return builder.buckets
    }
}
#endif
