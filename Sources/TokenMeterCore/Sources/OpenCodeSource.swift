#if os(macOS)
import Foundation
import SQLite3

/// OpenCode：~/.local/share/opencode/opencode.db 的 message 表
/// data json: {role, modelID, providerID, tokens:{input,output,reasoning,cache:{read,write}}, time:{created}}
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
        let sql = "select m.data, s.directory from message m left join session s on s.id = m.session_id where m.data like '%\"tokens\"%'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let line = String(cString: cstr)
            guard let o = JSONUtil.object(line),
                  let tokens = JSONUtil.dict(o, "tokens") else { continue }
            let input = JSONUtil.int(tokens, "input")
            let output = JSONUtil.int(tokens, "output") + JSONUtil.int(tokens, "reasoning")
            var cacheRead: Int64 = 0
            var cacheWrite: Int64 = 0
            if let cache = JSONUtil.dict(tokens, "cache") {
                cacheRead = JSONUtil.int(cache, "read")
                cacheWrite = JSONUtil.int(cache, "write")
            }
            let counts = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            guard counts.total > 0 else { continue }
            let model = JSONUtil.string(o, "modelID") ?? "unknown"
            if let dir = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }), !dir.isEmpty {
                builder.project = ProjectName.basename(dir)
            }
            var date = Date()
            if let time = JSONUtil.dict(o, "time"), let created = JSONUtil.intOrNil(time, "created") {
                date = JSONUtil.dateFromMillis(created)
            }
            builder.add(date: date, model: model, counts: counts)
        }
        return builder.buckets
    }
}
#endif
