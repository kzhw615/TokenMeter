#if os(macOS)
import Foundation
import SQLite3

/// ZCode：~/.zcode/cli/db/db.sqlite 的 model_usage 表
public struct ZCodeSource: UsageSource {
    public var id: String { "zcode" }
    public var displayName: String { "ZCode" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let dbPath = SourcePaths.expand("~/.zcode/cli/db/db.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath) else { return ScanResult() }
        if let cached = cache.cachedBuckets(path: dbPath) {
            return ScanResult(buckets: cached, files: 1)
        }
        let buckets = parse(dbPath: dbPath)
        cache.store(path: dbPath, buckets: buckets)
        return ScanResult(buckets: buckets, files: 1)
    }

    private func parse(dbPath: String) -> [UsageBucket] {
        var builders: [String: BucketBuilder] = [:]
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        // session.directory 是会话所在目录，用它归属项目；取不到时退回 "-"
        let sql = """
        SELECT m.model_id, m.started_at, m.input_tokens, m.output_tokens, m.reasoning_tokens,
               m.cache_creation_input_tokens, m.cache_read_input_tokens,
               coalesce(nullif(s.directory,''), nullif(s.path,''))
        FROM model_usage m
        LEFT JOIN session s ON s.id = m.session_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            let startedAt = sqlite3_column_int64(stmt, 1)
            let counts = TokenCounts(
                input: sqlite3_column_int64(stmt, 2),
                output: sqlite3_column_int64(stmt, 3) + sqlite3_column_int64(stmt, 4),
                cacheRead: sqlite3_column_int64(stmt, 6),
                cacheWrite: sqlite3_column_int64(stmt, 5)
            )
            guard counts.total > 0 else { continue }
            let date = startedAt > 0 ? JSONUtil.dateFromMillis(startedAt) : Date()
            let project = sqlite3_column_text(stmt, 7).map { ProjectName.basename(String(cString: $0)) } ?? "-"
            let builder = builders[project] ?? {
                let b = BucketBuilder(tool: "ZCode"); b.project = project; builders[project] = b; return b
            }()
            builder.add(date: date, model: model, counts: counts)
        }
        return builders.values.flatMap(\.buckets)
    }
}
#endif
