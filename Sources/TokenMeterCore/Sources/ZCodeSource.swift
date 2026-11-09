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
        let builder = BucketBuilder(tool: "ZCode")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT model_id, started_at, input_tokens, output_tokens, reasoning_tokens,
               cache_creation_input_tokens, cache_read_input_tokens
        FROM model_usage
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
            builder.add(date: date, model: model, counts: counts)
        }
        return builder.buckets
    }
}
