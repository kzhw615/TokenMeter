import Foundation

/// Claude Code：~/.claude/projects/**/*.jsonl
/// assistant 消息的 message.usage{input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens}
public struct ClaudeCodeSource: UsageSource {
    public var id: String { "claude-code" }
    public var displayName: String { "Claude Code" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = SourcePaths.files(under: "~/.claude/projects", suffix: ".jsonl")
        let builder = BucketBuilder(tool: "Claude Code")
        var toParse: [String] = []
        for path in files {
            if let cached = cache.cachedBuckets(path: path) {
                builder.merge(cached)
            } else {
                toParse.append(path)
            }
        }
        let lock = NSLock()
        var pairs: [(String, [UsageBucket])] = []
        DispatchQueue.concurrentPerform(iterations: toParse.count) { i in
            let b = parse(path: toParse[i])
            lock.lock()
            pairs.append((toParse[i], b))
            lock.unlock()
        }
        for (path, b) in pairs {
            cache.store(path: path, buckets: b)
            builder.merge(b)
        }
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    private func parse(path: String) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "Claude Code")
        var seenMessageIDs = Set<String>()
        guard let reader = LineReader(path: path) else { return [] }
        reader.forEachLine { line in
            guard line.contains("\"usage\"") else { return }
            guard let o = JSONUtil.object(line),
                  JSONUtil.string(o, "type") == "assistant",
                  let message = JSONUtil.dict(o, "message"),
                  let usage = JSONUtil.dict(message, "usage") else { return }
            if let mid = JSONUtil.string(message, "id") {
                if seenMessageIDs.contains(mid) { return }
                seenMessageIDs.insert(mid)
            }
            let counts = TokenCounts(
                input: JSONUtil.int(usage, "input_tokens"),
                output: JSONUtil.int(usage, "output_tokens"),
                cacheRead: JSONUtil.int(usage, "cache_read_input_tokens"),
                cacheWrite: JSONUtil.int(usage, "cache_creation_input_tokens")
            )
            guard counts.total > 0 else { return }
            let model = JSONUtil.string(message, "model") ?? "unknown"
            let date = JSONUtil.date(o, "timestamp") ?? Date()
            builder.add(date: date, model: model, counts: counts)
        }
        return builder.buckets
    }
}
