#if os(macOS)
import Foundation
import SQLite3

/// Hermes：~/.hermes/state.db 与 ~/.hermes/profiles/*/state.db 的 session_model_usage 表
public struct HermesSource: UsageSource {
    public var id: String { "hermes" }
    public var displayName: String { "Hermes" }
    public var enabledByDefault: Bool { true }

    public init() {}

    /// Hermes 的用量库：只认根库 + profiles/*/state.db。
    /// 不做全目录递归：~/.hermes 下有 installs/cache/tools 共十万级文件，
    /// 而且 state-snapshots/*/state.db 是备份，递归进去会重复计数。
    public static func stateDBPaths() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let root = SourcePaths.expand("~/.hermes/state.db")
        if fm.fileExists(atPath: root) { out.append(root) }
        let profilesDir = SourcePaths.expand("~/.hermes/profiles")
        if let names = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for name in names {
                let p = profilesDir + "/" + name + "/state.db"
                if fm.fileExists(atPath: p) { out.append(p) }
            }
        }
        return out
    }

    public func scan(cache: inout ScanCache) -> ScanResult {
        let dbs = Self.stateDBPaths()
        let builder = BucketBuilder(tool: "Hermes")
        var files = 0
        for dbPath in dbs {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            files += 1
            if let cached = cache.cachedBuckets(path: dbPath) {
                builder.merge(cached)
                continue
            }
            let buckets = parse(dbPath: dbPath)
            cache.store(path: dbPath, buckets: buckets)
            builder.merge(buckets)
        }
        return ScanResult(buckets: builder.buckets, files: files)
    }

    private func parse(dbPath: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "Hermes")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen
        FROM session_model_usage
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            let counts = TokenCounts(
                input: sqlite3_column_int64(stmt, 1),
                output: sqlite3_column_int64(stmt, 2),
                cacheRead: sqlite3_column_int64(stmt, 3),
                cacheWrite: sqlite3_column_int64(stmt, 4)
            )
            guard counts.total > 0 else { continue }
            let ts = sqlite3_column_double(stmt, 5)
            let date = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
            builder.add(date: date, model: model, counts: counts)
        }
        return builder.buckets
    }
}
#endif
