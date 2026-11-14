import Foundation

/// Codex CLI / Desktop：~/.codex/sessions/**/rollout-*.jsonl（含 archived_sessions）
/// event_msg.payload.type == "token_count" 的 info.last_token_usage 为单次调用增量
///
/// 模型名来源有三层，因为不同版本的写法不一样：
/// 1. `payload.model`（字符串）
/// 2. `payload.thread_settings.model` / `payload.turn_context.model`
/// 3. `payload.base_instructions.provenance.model`（旧版）
/// 4. 子智能体会话（`thread_source: subagent`）的 session_meta 里**没有**模型字段，
///    只能按 `parent_thread_id` 从父线程继承（映射持久化在 ScanCache.threadModels）
public struct CodexSource: UsageSource {
    public var id: String { "codex" }
    public var displayName: String { "Codex" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func logFiles() -> [String] {
        // 允许改目录：便于测试，也方便把 Codex 装在自定义位置
        let base = ProcessInfo.processInfo.environment["TOKENMETER_CODEX_DIR"] ?? "~/.codex"
        var files = SourcePaths.files(under: "\(base)/sessions", suffix: ".jsonl")
        files += SourcePaths.files(under: "\(base)/sessions", suffix: ".jsonl.zst")
        files += SourcePaths.files(under: "\(base)/archived_sessions", suffix: ".jsonl")
        files += SourcePaths.files(under: "\(base)/archived_sessions", suffix: ".jsonl.zst")
        return files
    }

    /// 一次解析的结果（含线程归属，供子会话继承模型）
    struct Parsed {
        var buckets: [UsageBucket]
        var model: String
        var threadID: String?
        var parentID: String?
    }

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = logFiles()
        let builder = BucketBuilder(tool: "Codex")
        var threadModels = cache.threadModels ?? [:]
        var toParse: [String] = []
        var toAppend: [(String, ScanCache.Entry, Int64)] = []

        // 并行取指纹（数千个 stat 串行是主要耗时）
        let prints = SourcePaths.parallelFingerprints(files)
        for (i, path) in files.enumerated() {
            guard let fp = prints[i] else { toParse.append(path); continue }
            if let cached = cache.cachedBuckets(path: path, size: fp.size, mtime: fp.mtime) {
                // 迁移：旧缓存里带 unknown 的文件重解析一次（子会话可继承父线程模型）
                if cached.contains(where: { $0.model == "unknown" && $0.counts.total > 0 }) {
                    toParse.append(path)
                    continue
                }
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

        /// 记录模型解析结果；未知且能定位父线程时先挂起，等父线程解析出来再回填
        var pending: [(path: String, buckets: [UsageBucket], parent: String, offset: Int64?)] = []

        func remap(_ buckets: [UsageBucket], to model: String) -> [UsageBucket] {
            buckets.map { b in
                guard b.model == "unknown" else { return b }
                var c = b
                c.model = model
                return c
            }
        }

        func commit(_ path: String, _ parsed: Parsed, offset: Int64?) {
            var buckets = parsed.buckets
            var model = parsed.model
            if let t = parsed.threadID, model != "unknown" {
                threadModels[t] = model
            }
            if model == "unknown", let parent = parsed.parentID {
                if let inherited = threadModels[parent] {
                    buckets = remap(buckets, to: inherited)
                    model = inherited
                } else {
                    pending.append((path, buckets, parent, offset))
                    return
                }
            }
            cache.store(path: path, buckets: buckets, offset: offset ?? (ScanCache.fingerprint(path: path)?.size ?? 0),
                        lastModel: model)
            builder.merge(buckets)
        }

        // ── 增量尾部解析：通常只有 1~3 个活跃文件，串行即可 ─────────────
        for (path, entry, boundary) in toAppend {
            guard let reader = LineReader(path: path, offset: UInt64(entry.offset),
                                          endOffset: UInt64(boundary)) else {
                toParse.append(path)
                continue
            }
            var seedModel = entry.lastModel
            var seedThread: String?
            var seedParent: String?
            if seedModel == nil || seedModel == "unknown" {
                let head = Self.headMeta(path: path)
                seedModel = head.model
                seedThread = head.threadID
                seedParent = head.parentID
            }
            let state = ParseState()
            state.model = seedModel ?? "unknown"
            state.threadID = seedThread
            state.parentID = seedParent
            state.builder.project = entry.buckets.first(where: { $0.project != "-" })?.project ?? "-"
            reader.forEachLine { state.consume($0) }
            var merged = entry.buckets
            merged.append(contentsOf: state.builder.buckets)
            let parsed = Parsed(buckets: merged, model: state.model,
                                threadID: state.threadID, parentID: state.parentID)
            commit(path, parsed, offset: boundary)
            ScanProgressReporter.current?.bump()
        }

        // ── 全量解析（分块，峰值内存只与块大小相关）────────────────────
        BoundedParallel.chunkedMap(toParse, chunkSize: 32, transform: { path in
            let parsed = parseFileDetailed(path: path)
            ScanProgressReporter.current?.bump()
            return parsed
        }, handle: { path, parsed in
            commit(path, parsed, offset: nil)
        })

        // ── 回填挂起项：父线程此刻应该已经解析出模型 ────────────────────
        for item in pending {
            let inherited = threadModels[item.parent] ?? "unknown"
            let buckets = inherited == "unknown" ? item.buckets : remap(item.buckets, to: inherited)
            cache.store(path: item.path, buckets: buckets,
                        offset: item.offset ?? (ScanCache.fingerprint(path: item.path)?.size ?? 0),
                        lastModel: inherited)
            builder.merge(buckets)
        }

        cache.threadModels = threadModels
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    /// 从文件首行（session_meta）取模型与线程归属；只读开头一段，成本可忽略
    static func headMeta(path: String) -> (model: String?, threadID: String?, parentID: String?) {
        guard let reader = LineReader(path: path, offset: 0, endOffset: 256 * 1024) else {
            return (nil, nil, nil)
        }
        var model: String?
        var threadID: String?
        var parentID: String?
        reader.forEachLine { line in
            guard model == nil, threadID == nil, parentID == nil, !line.isEmpty else { return }
            guard let o = JSONUtil.object(line), let payload = JSONUtil.dict(o, "payload") else { return }
            model = extractModel(line: line)
            threadID = JSONUtil.string(payload, "id") ?? JSONUtil.string(payload, "session_id")
            parentID = JSONUtil.string(payload, "parent_thread_id")
                ?? JSONUtil.dict(payload, "source")
                    .flatMap { JSONUtil.dict($0, "subagent") }
                    .flatMap { JSONUtil.dict($0, "thread_spawn") }
                    .flatMap { JSONUtil.string($0, "parent_thread_id") }
        }
        return (model, threadID, parentID)
    }

    /// 从 session_meta / thread_settings_applied / turn_context 事件里提取模型名。
    /// 续会话文件（文件名带双 uuid）的 session_meta 没有顶层 model，
    /// 模型藏在 thread_settings.model 或 base_instructions.provenance.model 里。
    private static func extractModel(line: String) -> String? {
        guard let o = JSONUtil.object(line), let payload = JSONUtil.dict(o, "payload") else { return nil }
        if let m = JSONUtil.string(payload, "model") { return m }
        if let ts = JSONUtil.dict(payload, "thread_settings"), let m = JSONUtil.string(ts, "model") { return m }
        if let tc = JSONUtil.dict(payload, "turn_context"), let m = JSONUtil.string(tc, "model") { return m }
        // 新版把 model 写成对象：{"model":"gpt-6.1-sol", ...}
        if let m = JSONUtil.dict(payload, "model"), let name = JSONUtil.string(m, "model") ?? JSONUtil.string(m, "id") {
            return name
        }
        if let bi = JSONUtil.dict(payload, "base_instructions"),
           let prov = JSONUtil.dict(bi, "provenance"),
           let m = JSONUtil.string(prov, "model") {
            return m
        }
        return nil
    }

    public func parseFile(path: String) -> [UsageBucket] {
        parseFileDetailed(path: path).buckets
    }

    func parseFileDetailed(path: String) -> Parsed {
        let state = ParseState()
        if path.hasSuffix(".zst") {
            // 经临时文件流式读：避免 GB 级解压结果整体驻留内存
            if !Zstd.forEachDecompressedLine(path: path, handler: { state.consume($0) }) {
                guard let data = Zstd.decompress(path: path) else {
                    return Parsed(buckets: [], model: "unknown", threadID: nil, parentID: nil)
                }
                for line in LineReader.split(data) { state.consume(line) }
            }
        } else {
            guard let reader = LineReader(path: path) else {
                return Parsed(buckets: [], model: "unknown", threadID: nil, parentID: nil)
            }
            reader.forEachLine { state.consume($0) }
        }
        return Parsed(buckets: state.builder.buckets, model: state.model,
                      threadID: state.threadID, parentID: state.parentID)
    }

    final class ParseState {
        let builder = BucketBuilder(tool: "Codex")
        var model = "unknown"
        var threadID: String?
        var parentID: String?
        private var metaSeen = false

        func consume(_ line: String) {
            if line.contains("\"session_meta\"") || line.contains("thread_settings_applied") || line.contains("\"turn_context\"") {
                if let m = CodexSource.extractModel(line: line) { model = m }
                if let o = JSONUtil.object(line), let payload = JSONUtil.dict(o, "payload") {
                    if !metaSeen {
                        metaSeen = true
                        threadID = JSONUtil.string(payload, "id") ?? JSONUtil.string(payload, "session_id")
                        parentID = JSONUtil.string(payload, "parent_thread_id")
                            ?? JSONUtil.dict(payload, "source")
                                .flatMap { JSONUtil.dict($0, "subagent") }
                                .flatMap { JSONUtil.dict($0, "thread_spawn") }
                                .flatMap { JSONUtil.string($0, "parent_thread_id") }
                    }
                    if builder.project == "-",
                       let cwd = JSONUtil.string(payload, "cwd"), !cwd.isEmpty {
                        builder.project = ProjectName.basename(cwd)
                    }
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
