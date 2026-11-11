import Foundation

/// Codex CLI / Desktop：~/.codex/sessions/**/rollout-*.jsonl（含 archived_sessions）
/// event_msg.payload.type == "token_count" 的 info.last_token_usage 为单次调用增量
public struct CodexSource: UsageSource {
    public var id: String { "codex" }
    public var displayName: String { "Codex" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func logFiles() -> [String] {
        var files = SourcePaths.files(under: "~/.codex/sessions", suffix: ".jsonl")
        files += SourcePaths.files(under: "~/.codex/sessions", suffix: ".jsonl.zst")
        files += SourcePaths.files(under: "~/.codex/archived_sessions", suffix: ".jsonl")
        files += SourcePaths.files(under: "~/.codex/archived_sessions", suffix: ".jsonl.zst")
        return files
    }

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = logFiles()
        let builder = BucketBuilder(tool: "Codex")
        var toParse: [String] = []
        // 并行取指纹（数千个 stat 串行是主要耗时）
        let prints = SourcePaths.parallelFingerprints(files)
        for (i, path) in files.enumerated() {
            if let fp = prints[i], let cached = cache.cachedBuckets(path: path, size: fp.size, mtime: fp.mtime) {
                ScanProgressReporter.current?.bump()
                builder.merge(cached)
            } else {
                toParse.append(path)
            }
        }
        // 分块解析：每块解析完立刻入库并释放，峰值内存只与块大小相关
        BoundedParallel.chunkedMap(toParse, chunkSize: 32, transform: { path in
            let buckets = parseFile(path: path)
            ScanProgressReporter.current?.bump()
            return buckets
        }, handle: { path, buckets in
            cache.store(path: path, buckets: buckets)
            builder.merge(buckets)
        })
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    /// 从 session_meta / thread_settings_applied / turn_context 事件里提取模型名。
    /// 续会话文件（文件名带双 uuid）的 session_meta 没有顶层 model，
    /// 模型藏在 thread_settings.model 或 base_instructions.provenance.model 里。
    private static func extractModel(line: String) -> String? {
        guard let o = JSONUtil.object(line), let payload = JSONUtil.dict(o, "payload") else { return nil }
        if let m = JSONUtil.string(payload, "model") { return m }
        if let ts = JSONUtil.dict(payload, "thread_settings"), let m = JSONUtil.string(ts, "model") { return m }
        if let bi = JSONUtil.dict(payload, "base_instructions"),
           let prov = JSONUtil.dict(bi, "provenance"),
           let m = JSONUtil.string(prov, "model") { return m }
        return nil
    }

    public func parseFile(path: String) -> [UsageBucket] {
        let state = ParseState()
        if path.hasSuffix(".zst") {
            guard let data = Zstd.decompress(path: path) else { return [] }
            for line in LineReader.split(data) { state.consume(line) }
        } else {
            guard let reader = LineReader(path: path) else { return [] }
            reader.forEachLine { state.consume($0) }
        }
        return state.builder.buckets
    }

    private final class ParseState {
        let builder = BucketBuilder(tool: "Codex")
        var model = "unknown"

        func consume(_ line: String) {
            if line.contains("\"session_meta\"") || line.contains("thread_settings_applied") || line.contains("\"turn_context\"") {
                if let m = CodexSource.extractModel(line: line) { model = m }
                if builder.project == "-",
                   let o = JSONUtil.object(line), let payload = JSONUtil.dict(o, "payload"),
                   let cwd = JSONUtil.string(payload, "cwd"), !cwd.isEmpty {
                    builder.project = ProjectName.basename(cwd)
                }
                if !line.contains("\"token_count\"") { return }
            }
            guard line.contains("\"token_count\"") else { return }
            guard let o = JSONUtil.object(line),
                  JSONUtil.string(o, "type") == "event_msg",
                  let payload = JSONUtil.dict(o, "payload"),
                  JSONUtil.string(payload, "type") == "token_count",
                  let info = JSONUtil.dict(payload, "info"),
                  let u = JSONUtil.dict(info, "last_token_usage") else { return }
            let inputAll = JSONUtil.int(u, "input_tokens")
            let cached = JSONUtil.int(u, "cached_input_tokens")
            let cacheWrite = JSONUtil.int(u, "cache_write_input_tokens")
            // output_tokens 已含 reasoning_output_tokens（total=input+output 恒等式验证）
            let output = JSONUtil.int(u, "output_tokens")
            let counts = TokenCounts(
                input: max(0, inputAll - cached - cacheWrite),
                output: output,
                cacheRead: cached,
                cacheWrite: cacheWrite
            )
            guard counts.total > 0 else { return }
            let date = JSONUtil.date(o, "timestamp") ?? Date()
            builder.add(date: date, model: model, counts: counts)
        }
    }
}
