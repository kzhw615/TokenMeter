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
        var toAppend: [(String, ScanCache.Entry, Int64)] = []
        // 并行取指纹（数千个 stat 串行是主要耗时）
        let prints = SourcePaths.parallelFingerprints(files)
        for (i, path) in files.enumerated() {
            guard let fp = prints[i] else { toParse.append(path); continue }
            if let cached = cache.cachedBuckets(path: path, size: fp.size, mtime: fp.mtime) {
                ScanProgressReporter.current?.bump()
                builder.merge(cached)
                continue
            }
            // 追加型 .jsonl：只解析上次之后新增的尾部。
            // 否则一个 1.4GB 的活跃会话文件每次刷新都要全量重解析（实测单次 60-90 秒）。
            if !path.hasSuffix(".zst"),
               let entry = cache.entries[path],
               entry.offset > 0,
               fp.size > entry.offset,
               fp.size >= entry.size,
               let boundary = LineReader.lastCompleteLineBoundary(path: path),
               boundary > entry.offset {
                toAppend.append((path, entry, boundary))
            } else {
                toParse.append(path)
            }
        }
        // 增量尾部解析：通常只有 1~3 个活跃文件，串行即可
        for (path, entry, boundary) in toAppend {
            guard let reader = LineReader(path: path, offset: UInt64(entry.offset),
                                          endOffset: UInt64(boundary)) else {
                toParse.append(path)
                continue
            }
            let state = ParseState()
            state.model = entry.lastModel ?? "unknown"
            state.builder.project = entry.buckets.first(where: { $0.project != "-" })?.project ?? "-"
            reader.forEachLine { state.consume($0) }
            var merged = entry.buckets
            merged.append(contentsOf: state.builder.buckets)
            // 只消费到最后一个完整行：末尾半行留到下次
            cache.store(path: path, buckets: merged, offset: boundary, lastModel: state.model)
            builder.merge(state.builder.buckets)
            ScanProgressReporter.current?.bump()
        }
        // 分块解析：每块解析完立刻入库并释放，峰值内存只与块大小相关
        BoundedParallel.chunkedMap(toParse, chunkSize: 32, transform: { path in
            let buckets = parseFile(path: path)
            ScanProgressReporter.current?.bump()
            return buckets
        }, handle: { path, buckets in
            cache.store(path: path, buckets: buckets,
                        offset: ScanCache.fingerprint(path: path)?.size ?? 0)
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
            // 经临时文件流式读：避免 GB 级解压结果整体驻留内存
            if !Zstd.forEachDecompressedLine(path: path, handler: { state.consume($0) }) {
                guard let data = Zstd.decompress(path: path) else { return [] }
                for line in LineReader.split(data) { state.consume(line) }
            }
        } else {
            guard let reader = LineReader(path: path) else { return [] }
            reader.forEachLine { state.consume($0) }
        }
        return state.builder.buckets
    }

    final class ParseState {
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
