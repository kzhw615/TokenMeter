import Foundation

/// DSH harness：~/.dsh/sessions/*/*/session.v4.jsonl.zstd（zstd 压缩）
/// chunk.usage{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens} + 紧随的 finish chunk 带模型名
public struct DshSource: UsageSource {
    public var id: String { "dsh" }
    public var displayName: String { "DSH" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func logFiles() -> [String] {
        var files = SourcePaths.files(under: "~/.dsh/sessions", suffix: ".zstd")
        files += SourcePaths.files(under: "~/.dsh/sessions", suffix: ".jsonl")
        return files
    }

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = logFiles()
        if Zstd.zstdPath() == nil && files.contains(where: { $0.hasSuffix(".zstd") }) {
            // 有压缩文件但找不到 zstd：只解析未压缩的
            let note = "未找到 zstd 可执行文件，压缩会话日志已跳过"
            let plain = files.filter { !$0.hasSuffix(".zstd") }
            return ScanResult(buckets: scanPlain(plain, cache: &cache), files: files.count, note: note)
        }
        let builder = BucketBuilder(tool: "DSH")
        for path in files {
            // 压缩日志：按 zstd 帧边界增量解析，避免每次解压整个文件（活跃会话可达数 MB）
            // 活跃文件一直在增长：不能要求指纹完全一致，只要求「比上次更大」（append-only）
            if path.hasSuffix(".zstd"),
               let entry = cache.cachedEntry(path: path),
               entry.offset > 0,
               let cur = ScanCache.fingerprint(path: path),
               cur.size >= entry.size,
               let boundary = Zstd.lastFrameStart(path: path),
               boundary > entry.offset {
                let dbg = ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil
                if dbg { FileHandle.standardError.write(Data("    [dsh] incremental offset=\(entry.offset) boundary=\(boundary) gap=\(boundary-entry.offset)\n".utf8)) }
                if let tail = Zstd.decompressRange(path: path, from: entry.offset, to: boundary) {
                    let parsed = parseWithModel(data: tail, path: path, initialModel: entry.lastModel)
                    let merged = mergeBuckets(entry.buckets, parsed.buckets)
                    cache.update(path: path, buckets: merged, offset: boundary, lastModel: parsed.model)
                    builder.merge(merged)
                    ScanProgressReporter.current?.bump()
                    continue
                }
            }
            if let cached = cache.cachedBuckets(path: path) {
                ScanProgressReporter.current?.bump()
                builder.merge(cached)
                continue
            }
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                FileHandle.standardError.write(Data("    [dsh] FULL \(path.split(separator: "/").last ?? "")\n".utf8))
            }
            let local: [UsageBucket]
            var model: String?
            if path.hasSuffix(".zstd") {
                guard let data = Zstd.decompress(path: path) else { continue }
                let parsed = parseWithModel(data: data, path: path, initialModel: nil)
                local = parsed.buckets
                model = parsed.model
            } else {
                local = parseFile(path: path)
            }
            // 记录帧边界，供下次增量解析
            let offset = path.hasSuffix(".zstd") ? (Zstd.lastFrameStart(path: path) ?? 0) : 0
            cache.store(path: path, buckets: local, offset: offset, lastModel: model)
            builder.merge(local)
            ScanProgressReporter.current?.bump()
        }
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    private func scanPlain(_ files: [String], cache: inout ScanCache) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "DSH")
        for path in files {
            if let cached = cache.cachedBuckets(path: path) {
                ScanProgressReporter.current?.bump()
                builder.merge(cached); continue
            }
            let local = parseFile(path: path)
            ScanProgressReporter.current?.bump()
            cache.store(path: path, buckets: local)
            builder.merge(local)
        }
        return builder.buckets
    }

    /// 合并两组桶（增量解析：旧桶 + 新增桶）
    private func mergeBuckets(_ old: [UsageBucket], _ new: [UsageBucket]) -> [UsageBucket] {
        guard !old.isEmpty else { return new }
        guard !new.isEmpty else { return old }
        let builder = BucketBuilder(tool: "DSH")
        builder.merge(old)
        builder.merge(new)
        return builder.buckets
    }

    private func makeBuilder(path: String) -> BucketBuilder {
        let builder = BucketBuilder(tool: "DSH")
        let comps = path.split(separator: "/")
        if comps.count >= 3 {
            builder.project = ProjectName.decodeDsh(String(comps[comps.count - 3]))
        }
        return builder
    }

    public func parseFile(path: String) -> [UsageBucket] {
        let builder = makeBuilder(path: path)
        guard let reader = LineReader(path: path) else { return [] }
        let state = ParseState(builder: builder)
        state.currentModel = firstModel(path: path) ?? "unknown"
        reader.forEachLine { state.consume($0) }
        state.flush()
        return builder.buckets
    }

    private func parse(data: Data, path: String) -> [UsageBucket] {
        parseWithModel(data: data, path: path, initialModel: nil).buckets
    }

    /// 解析并返回结束时生效的模型（增量解析时作为下文初始模型沿用）
    private func parseWithModel(data: Data, path: String, initialModel: String?) -> (buckets: [UsageBucket], model: String?) {
        let builder = makeBuilder(path: path)
        let state = ParseState(builder: builder)
        if let initialModel { state.currentModel = initialModel }
        let lines = LineReader.split(data)
        if initialModel == nil {
            for line in lines where line.contains("\"model/selection\"") {
                if let m = Self.modelFromSelection(line) { state.currentModel = m }
                break
            }
        }
        for line in lines { state.consume(line) }
        state.flush()
        return (builder.buckets, state.currentModel)
    }

    private func firstModel(path: String) -> String? {
        guard let reader = LineReader(path: path) else { return nil }
        var found: String?
        reader.forEachLine { line in
            if found == nil, line.contains("\"model/selection\"") {
                found = Self.modelFromSelection(line)
            }
        }
        return found
    }

    private static func modelFromSelection(_ line: String) -> String? {
        guard let o = JSONUtil.object(line), let data = JSONUtil.dict(o, "data") else { return nil }
        return JSONUtil.string(data, "model")
    }

    private final class ParseState {
        let builder: BucketBuilder
        var currentModel = "unknown"

        init(builder: BucketBuilder) { self.builder = builder }

        func consume(_ line: String) {
            if line.contains("\"model/selection\"") {
                if let o = JSONUtil.object(line), let data = JSONUtil.dict(o, "data"),
                   let m = JSONUtil.string(data, "model") {
                    currentModel = m
                }
                return
            }
            guard line.contains("\"usage\"") else { return }
            guard let o = JSONUtil.object(line),
                  JSONUtil.string(o, "type") == "assistant/message",
                  let data = JSONUtil.dict(o, "data"),
                  let usage = JSONUtil.dict(data, "usage") else { return }
            let counts = TokenCounts(
                input: JSONUtil.int(usage, "inputTokens"),
                output: JSONUtil.int(usage, "outputTokens"),
                cacheRead: JSONUtil.int(usage, "cacheReadTokens"),
                cacheWrite: JSONUtil.int(usage, "cacheWriteTokens")
            )
            guard counts.total > 0 else { return }
            var model = currentModel
            if let stream = data["stream"] as? [[String: Any]] {
                for ch in stream {
                    // stream 元素形如 {"type":"chunk","chunk":{...}}，也可能直接是内层对象
                    let inner = (JSONUtil.string(ch, "type") == "chunk" && JSONUtil.dict(ch, "chunk") != nil)
                        ? JSONUtil.dict(ch, "chunk")!
                        : ch
                    if JSONUtil.string(inner, "type") == "finish",
                       let replay = JSONUtil.dict(inner, "replayState"),
                       let resp = JSONUtil.dict(replay, "response"),
                       let m = JSONUtil.string(resp, "model") {
                        model = m
                        break
                    }
                }
            }
            let date = JSONUtil.dateFromMillis(JSONUtil.int(o, "time"))
            builder.add(date: date, model: model, counts: counts)
        }

        func flush() {}
    }

    // MARK: 调试

    public func debugParse(path: String) {
        guard let data = Zstd.decompress(path: path) else {
            print("decompress failed: \(path)")
            return
        }
        print("bytes: \(data.count)")
        var lines = 0
        var containsUsage = 0
        var objOK = 0
        var typeChunk = 0
        var chunkTypeUsage = 0
        var firstUsageLine: String?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            var start = 0
            for i in 0..<buf.count {
                if buf[i] == 0x0A {
                    if i > start {
                        let line = String(decoding: buf[start..<i], as: UTF8.self)
                        lines += 1
                        if line.contains("\"usage\"") {
                            containsUsage += 1
                            if let o = JSONUtil.object(line) {
                                objOK += 1
                                if JSONUtil.string(o, "type") == "chunk" {
                                    typeChunk += 1
                                    if let chunk = JSONUtil.dict(o, "chunk"), JSONUtil.string(chunk, "type") == "usage" {
                                        chunkTypeUsage += 1
                                        if firstUsageLine == nil { firstUsageLine = line }
                                    }
                                }
                            }
                        }
                    }
                    start = i + 1
                }
            }
        }
        print("lines=\(lines) containsUsage=\(containsUsage) objOK=\(objOK) typeChunk=\(typeChunk) chunkTypeUsage=\(chunkTypeUsage)")
        if let l = firstUsageLine { print("sample: \(String(l.prefix(300)))") }
        let buckets = parse(data: data, path: path)
        print("buckets: \(buckets.count)")
        for b in buckets.prefix(5) { print("  \(b.day) \(b.model) total=\(b.counts.total)") }
    }
}
