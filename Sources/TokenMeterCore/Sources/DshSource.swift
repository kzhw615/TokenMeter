import Foundation

/// DSH harness：~/.dsh/sessions/*/*/session.v4.jsonl.zstd（zstd 压缩）
/// chunk.usage{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens} + 紧随的 finish chunk 带模型名
public struct DshSource: UsageSource {
    public var id: String { "dsh" }
    public var displayName: String { "DSH" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        var files = SourcePaths.files(under: "~/.dsh/sessions", suffix: ".zstd")
        files += SourcePaths.files(under: "~/.dsh/sessions", suffix: ".jsonl")
        if Zstd.zstdPath() == nil && files.contains(where: { $0.hasSuffix(".zstd") }) {
            // 有压缩文件但找不到 zstd：只解析未压缩的
            let note = "未找到 zstd 可执行文件，压缩会话日志已跳过"
            let plain = files.filter { !$0.hasSuffix(".zstd") }
            return ScanResult(buckets: scanPlain(plain, cache: &cache), files: files.count, note: note)
        }
        let builder = BucketBuilder(tool: "DSH")
        for path in files {
            if let cached = cache.cachedBuckets(path: path) {
                builder.merge(cached)
                continue
            }
            let local: [UsageBucket]
            if path.hasSuffix(".zstd") {
                guard let data = Zstd.decompress(path: path) else { continue }
                local = parse(data: data)
            } else {
                local = parseFile(path: path)
            }
            cache.store(path: path, buckets: local)
            builder.merge(local)
        }
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    private func scanPlain(_ files: [String], cache: inout ScanCache) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "DSH")
        for path in files {
            if let cached = cache.cachedBuckets(path: path) { builder.merge(cached); continue }
            let local = parseFile(path: path)
            cache.store(path: path, buckets: local)
            builder.merge(local)
        }
        return builder.buckets
    }

    private func parseFile(path: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "DSH")
        guard let reader = LineReader(path: path) else { return [] }
        let state = ParseState(builder: builder)
        state.currentModel = firstModel(path: path) ?? "unknown"
        reader.forEachLine { state.consume($0) }
        state.flush()
        return builder.buckets
    }

    private func parse(data: Data) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "DSH")
        let state = ParseState(builder: builder)
        let lines = LineReader.split(data)
        for line in lines {
            if line.contains("\"model/selection\"") {
                state.currentModel = Self.modelFromSelection(line) ?? state.currentModel
                break
            }
        }
        for line in lines { state.consume(line) }
        state.flush()
        return builder.buckets
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
        let buckets = parse(data: data)
        print("buckets: \(buckets.count)")
        for b in buckets.prefix(5) { print("  \(b.day) \(b.model) total=\(b.counts.total)") }
    }
}
