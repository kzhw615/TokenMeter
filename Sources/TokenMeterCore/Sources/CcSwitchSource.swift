#if os(macOS)
import Foundation
import SQLite3

/// CC Switch（~/.cc-switch/cc-switch.db）：代理层镜像日志 proxy_request_logs。
/// 注意：这些请求通常同时也记录在 Claude Code / Codex 自己的日志里，
/// 默认关闭以避免重复计数；仅当你想单独看代理口径时启用。
public struct CcSwitchSource: UsageSource {
    public var id: String { "cc-switch" }
    public var displayName: String { "CC Switch" }
    public var enabledByDefault: Bool { false }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let dbPath = SourcePaths.expand("~/.cc-switch/cc-switch.db")
        guard FileManager.default.fileExists(atPath: dbPath) else { return ScanResult() }
        if let cached = cache.cachedBuckets(path: dbPath) {
            return ScanResult(buckets: cached, files: 1, note: "代理镜像日志，可能与 Claude/Codex 自身日志重复")
        }
        let buckets = parse(dbPath: dbPath)
        cache.store(path: dbPath, buckets: buckets)
        return ScanResult(buckets: buckets, files: 1, note: "代理镜像日志，可能与 Claude/Codex 自身日志重复")
    }

    private func parse(dbPath: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "CC Switch")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT app_type, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, created_at
        FROM proxy_request_logs WHERE data_source = 'proxy'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
            let input = sqlite3_column_int64(stmt, 2)
            let output = sqlite3_column_int64(stmt, 3)
            let cacheRead = sqlite3_column_int64(stmt, 4)
            let cacheWrite = sqlite3_column_int64(stmt, 5)
            let created = sqlite3_column_int64(stmt, 6)
            let counts = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            guard counts.total > 0 else { continue }
            let date = Date(timeIntervalSince1970: Double(created))
            builder.add(date: date, model: "[\(app)] \(model)", counts: counts)
        }
        return builder.buckets
    }
}
#endif
