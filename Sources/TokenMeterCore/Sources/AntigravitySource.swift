#if os(macOS)
import Foundation
import SQLite3

/// Antigravity（Google 的 agentic IDE）用量。
///
/// 数据在 `~/.gemini/<antigravity|antigravity-ide|antigravity-cli>/brain/<会话 id>/
/// .system_generated/logs/transcript_full.jsonl`：
///
///     {"type":"PLANNER_RESPONSE","model":"gemini-4-neon-xhigh","created_at":"2026-11-21T18:01:48Z",
///      "input_tokens":23720,"cache_read_tokens":0,"output_tokens":319, ...}
///
/// 注意 logs/chunks/ 下是同样内容的切片，扫了会重复计量，只读 transcript*.jsonl。
public struct AntigravitySource: UsageSource {
    public var id: String { "antigravity" }
    public var displayName: String { "Antigravity" }
    public var enabledByDefault: Bool { true }

    private static var bases: [String] {
        ["~/.gemini/antigravity", "~/.gemini/antigravity-ide", "~/.gemini/antigravity-cli"]
    }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let builder = BucketBuilder(tool: "Antigravity")
        var files = 0
        for rawBase in Self.bases {
            let base = SourcePaths.expand(rawBase)
            guard FileManager.default.fileExists(atPath: base) else { continue }
            let projects = Self.projectMap(base: base)
            for path in Self.transcriptFiles(base: base) {
                files += 1
                if let cached = cache.cachedBuckets(path: path) {
                    builder.merge(cached)
                    continue
                }
                let buckets = parse(path: path, projects: projects)
                cache.store(path: path, buckets: buckets)
                builder.merge(buckets)
            }
        }
        return ScanResult(buckets: builder.buckets, files: files)
    }

    /// brain/<会话 id>/.system_generated/logs/ 下的完整转录（不含 chunks/ 切片）
    static func transcriptFiles(base: String) -> [String] {
        let fm = FileManager.default
        let brain = base + "/brain"
        guard let sessions = try? fm.contentsOfDirectory(atPath: brain) else { return [] }
        var out: [String] = []
        for s in sessions {
            let logs = "\(brain)/\(s)/.system_generated/logs"
            for name in ["transcript_full.jsonl", "transcript.jsonl"] {
                let p = "\(logs)/\(name)"
                if fm.fileExists(atPath: p) { out.append(p); break }
            }
        }
        return out
    }

    /// 会话 id → 项目名：conversation_summaries.workspace_uris 是 file:// 数组
    static func projectMap(base: String) -> [String: String] {
        let dbPath = base + "/conversation_summaries.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }
        var out: [String: String] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT conversation_id, workspace_uris FROM conversation_summaries"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            guard let uriC = sqlite3_column_text(stmt, 1) else { continue }
            let raw = String(cString: uriC)
            guard let data = raw.data(using: .utf8),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [String],
                  let first = list.first else { continue }
            let path = first.hasPrefix("file://") ? String(first.dropFirst(7)) : first
            let name = ProjectName.basename(path.removingPercentEncoding ?? path)
            if !name.isEmpty && name != "-" { out[id] = name }
        }
        return out
    }

    public func parseForTest(path: String, projects: [String: String] = [:]) -> [UsageBucket] {
        parse(path: path, projects: projects)
    }

    private func parse(path: String, projects: [String: String]) -> [UsageBucket] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // 会话 id 在路径里：.../brain/<id>/.system_generated/logs/xxx.jsonl
        var conversation = ""
        let parts = path.components(separatedBy: "/brain/")
        if parts.count == 2 {
            conversation = parts[1].components(separatedBy: "/").first ?? ""
        }
        let project = projects[conversation]

        let builder = BucketBuilder(tool: "Antigravity")
        if let project { builder.project = project }
        for lineData in data.split(separator: 0x0A) {
            // 先做便宜的字节级过滤：只有带用量的行才值得解析 JSON
            guard lineData.count > 40,
                  let s = String(data: Data(lineData), encoding: .utf8),
                  s.contains("\"input_tokens\""),
                  s.contains("PLANNER_RESPONSE") else { continue }
            guard let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let input = (o["input_tokens"] as? NSNumber)?.int64Value ?? 0
            let output = (o["output_tokens"] as? NSNumber)?.int64Value ?? 0
            let cacheRead = (o["cache_read_tokens"] as? NSNumber)?.int64Value ?? 0
            let cacheWrite = (o["cache_creation_tokens"] as? NSNumber)?.int64Value
                ?? (o["cache_write_tokens"] as? NSNumber)?.int64Value ?? 0
            let counts = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            guard counts.total > 0 else { continue }
            let model = (o["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let date = (o["created_at"] as? String).flatMap(Self.parseISO) ?? Date()
            builder.add(date: date, model: model, counts: counts)
        }
        return builder.buckets
    }

    /// created_at 形如 2026-11-21T18:01:48Z（UTC）
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
#endif
