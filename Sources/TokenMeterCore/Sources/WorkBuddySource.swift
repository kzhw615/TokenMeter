import Foundation

/// WorkBuddy：~/.workbuddy/traces/*/trace_*.jsonl
/// generation span 的 span_end.toolOutput 是原始 chat.completion 响应数组，
/// 每个响应带 usage{prompt_tokens, completion_tokens, prompt_tokens_details.cached_tokens}。
public struct WorkBuddySource: UsageSource {
    public var id: String { "workbuddy" }
    public var displayName: String { "WorkBuddy" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = SourcePaths.files(under: "~/.workbuddy/traces", suffix: ".jsonl")
        let builder = BucketBuilder(tool: "WorkBuddy")
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
        let builder = BucketBuilder(tool: "WorkBuddy")
        let debug = ProcessInfo.processInfo.environment["TM_DEBUG_WB"] != nil
        guard let reader = LineReader(path: path) else { return [] }
        var spans = 0
        reader.forEachLine { line in
            guard line.contains("\"generation\""), line.contains("span_end") else { return }
            guard let o = JSONUtil.object(line),
                  JSONUtil.string(o, "type") == "span_end",
                  let span = JSONUtil.dict(o, "span"),
                  JSONUtil.string(span, "type") == "generation",
                  let toolOutput = JSONUtil.string(span, "toolOutput") else { return }
            let date = JSONUtil.date(span, "endedAt") ?? JSONUtil.date(span, "startedAt") ?? Date()
            var got = 0
            if let data = toolOutput.data(using: .utf8),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                for el in arr {
                    guard let usage = JSONUtil.dict(el, "usage") else { continue }
                    add(builder: builder, date: date, model: JSONUtil.string(el, "model") ?? "unknown", usage: usage)
                    got += 1
                }
            } else {
                for (model, usage) in Self.fragments(in: toolOutput) {
                    add(builder: builder, date: date, model: model, usage: usage)
                    got += 1
                }
            }
            if got > 0 { spans += 1 }
            if debug && got > 0 {
                FileHandle.standardError.write("wb span usages=\(got)\n".data(using: .utf8)!)
            }
        }
        if debug {
            let tot = builder.buckets.reduce(Int64(0)) { $0 + $1.counts.total }
            FileHandle.standardError.write("wb file \(path.split(separator: "/").last.map(String.init) ?? "?") spans=\(spans) total=\(tot)\n".data(using: .utf8)!)
        }
        return builder.buckets
    }

    private func add(builder: BucketBuilder, date: Date, model: String, usage: [String: Any]) {
        let prompt = JSONUtil.int(usage, "prompt_tokens")
        let completion = JSONUtil.int(usage, "completion_tokens")
        var cached: Int64 = 0
        var cacheWrite: Int64 = 0
        if let details = JSONUtil.dict(usage, "prompt_tokens_details") {
            cached = JSONUtil.int(details, "cached_tokens")
            cacheWrite = JSONUtil.int(details, "cache_write_tokens")
        }
        let counts = TokenCounts(
            input: max(0, prompt - cached - cacheWrite),
            output: completion,
            cacheRead: cached,
            cacheWrite: cacheWrite
        )
        guard counts.total > 0 else { return }
        builder.add(date: date, model: model, counts: counts)
    }

    /// 在被截断的 toolOutput 字符串里扫出所有 ("model", usageDict) 片段
    static func fragments(in s: String) -> [(String, [String: Any])] {
        var out: [(String, [String: Any])] = []
        let chars = Array(s)
        var i = 0
        let marker: [Character] = Array("\"usage\":")
        while i < chars.count {
            // 找 "usage":
            guard let hit = findMarker(chars, from: i, marker: marker) else { break }
            var j = hit + marker.count
            while j < chars.count, chars[j] != "{" { j += 1 }
            guard j < chars.count else { break }
            // 平衡花括号提取（处理字符串转义）
            var depth = 0
            var inStr = false
            var esc = false
            var k = j
            while k < chars.count {
                let c = chars[k]
                if inStr {
                    if esc { esc = false }
                    else if c == "\\" { esc = true }
                    else if c == "\"" { inStr = false }
                } else {
                    if c == "\"" { inStr = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                k += 1
            }
            guard k < chars.count else { break }
            let fragment = "{\"u\":" + String(chars[j...k]) + "}"
            if let data = fragment.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let usage = JSONUtil.dict(obj, "u") {
                // 向前找最近的 "model":"..."
                let prefix = String(chars[0..<hit])
                let model = lastModel(before: prefix) ?? "unknown"
                out.append((model, usage))
            }
            i = k + 1
        }
        return out
    }

    private static func findMarker(_ chars: [Character], from start: Int, marker: [Character]) -> Int? {
        var i = start
        while i + marker.count <= chars.count {
            if chars[i] == marker[0] && Array(chars[i..<(i + marker.count)]) == marker { return i }
            i += 1
        }
        return nil
    }

    private static func lastModel(before prefix: String) -> String? {
        guard let r = prefix.range(of: "\"model\":\"", options: .backwards) else { return nil }
        let rest = prefix[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
