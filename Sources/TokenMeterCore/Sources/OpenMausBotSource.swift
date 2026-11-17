#if os(macOS)
import Foundation

/// OpenMausBot：~/.openmausbot/usage/YYYY-MM.jsonl，每行一次回合的用量
/// 字段：model / input / output / cachedInput / startedAt / botId / botName / usageStatus
public struct OpenMausBotSource: UsageSource {
    public var id: String { "openmausbot" }
    public var displayName: String { "OpenMausBot" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = SourcePaths.files(under: "~/.openmausbot/usage", suffix: ".jsonl")
        guard !files.isEmpty else { return ScanResult() }
        let botProjects = Self.botProjectMap()
        var builders: [String: BucketBuilder] = [:]
        for path in files {
            var cached = cache.cachedBuckets(path: path)
            // 迁移：早期版本没去掉 [1m] 后缀，缓存里还是旧名字，重解析一次
            if let c = cached, c.contains(where: { $0.model.contains("[") }) { cached = nil }
            let buckets = cached ?? {
                let parsed = parse(path: path, botProjects: botProjects)
                cache.store(path: path, buckets: parsed)
                return parsed
            }()
            for b in buckets {
                let builder = builders[b.project] ?? {
                    let x = BucketBuilder(tool: displayName); x.project = b.project; builders[b.project] = x; return x
                }()
                builder.add(day: b.day, hour: b.hour, model: b.model, counts: b.counts)
            }
        }
        return ScanResult(buckets: builders.values.flatMap(\.buckets), files: files.count)
    }

    /// bots.json 里 botId → 分组名（section），没有分组时用 bot 名称
    static func botProjectMap() -> [String: String] {
        let path = SourcePaths.expand("~/.openmausbot/bots.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for bot in list {
            guard let id = bot["id"] as? String else { continue }
            let section = (bot["section"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = (bot["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let p = section ?? name { out[id] = p }
        }
        return out
    }

    /// 模型名归一：
    /// - 去掉驱动前缀：chatgpt-http::gpt-6.1-sol / auto/gpt-6.1-sol → gpt-6.1-sol
    /// - 去掉上下文变体后缀：deepseek-flash[1m] → deepseek-flash
    ///   （[1m] 是 OpenMausBot 标注的百万上下文版本，同一个模型，不拆成两行）
    static func normalizeModel(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "::", options: .backwards) { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "/", options: .backwards) { s = String(s[r.upperBound...]) }
        if s.hasSuffix("]"), let r = s.range(of: "[", options: .backwards) {
            s = String(s[..<r.lowerBound])
        }
        return s.isEmpty ? "unknown" : s
    }

    private func parse(path: String, botProjects: [String: String]) -> [UsageBucket] {
        var builders: [String: BucketBuilder] = [:]
        guard let reader = LineReader(path: path) else { return [] }
        reader.forEachLine { line in
            guard line.contains("\"model\""), let o = JSONUtil.object(line) else { return }
            let input = JSONUtil.intOrNil(o, "input") ?? 0
            let output = JSONUtil.intOrNil(o, "output") ?? 0
            guard input + output > 0 else { return }   // usageStatus=unavailable 的行为 0，跳过
            let counts = TokenCounts(input: input, output: output,
                                     cacheRead: JSONUtil.intOrNil(o, "cachedInput") ?? 0,
                                     cacheWrite: 0)
            let model = Self.normalizeModel(JSONUtil.string(o, "model") ?? "unknown")
            let project = (JSONUtil.string(o, "botId").flatMap { botProjects[$0] })
                ?? JSONUtil.string(o, "botName") ?? "-"
            guard let date = Self.date(from: o) else { return }
            let builder = builders[project] ?? {
                let b = BucketBuilder(tool: displayName); b.project = project; builders[project] = b; return b
            }()
            builder.add(date: date, model: model, counts: counts)
        }
        return builders.values.flatMap(\.buckets)
    }

    /// startedAt 是 ISO8601 带毫秒（"2026-11-16T15:33:42.890Z"），退回 endedAt / at
    static func date(from o: [String: Any]) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmt2 = ISO8601DateFormatter()
        for key in ["startedAt", "endedAt", "at"] {
            guard let s = JSONUtil.string(o, key), !s.isEmpty else { continue }
            if let d = fmt.date(from: s) ?? fmt2.date(from: s) { return d }
        }
        return nil
    }
}
#endif
