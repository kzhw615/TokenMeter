import Foundation

public protocol UsageSource {
    var id: String { get }
    var displayName: String { get }
    /// 是否参与统计
    var enabledByDefault: Bool { get }
    /// 扫描并返回聚合桶；利用 cache 跳过未变化文件
    func scan(cache: inout ScanCache) -> ScanResult
}

public struct ScanResult {
    public var buckets: [UsageBucket]
    public var files: Int
    public var note: String?
    public init(buckets: [UsageBucket] = [], files: Int = 0, note: String? = nil) {
        self.buckets = buckets
        self.files = files
        self.note = note
    }
}

/// 把 (day, model) 粒度的累加器转成 UsageBucket 列表
public final class BucketBuilder {
    private var map: [String: UsageBucket] = [:]
    private let tool: String

    public init(tool: String) { self.tool = tool }

    public func add(date: Date, model: String, counts: TokenCounts, calendar: Calendar = .current) {
        let day = DayKey.key(for: date, calendar: calendar)
        add(day: day, model: Self.normalizeModel(model), counts: counts)
    }

    public func add(day: String, model: String, counts: TokenCounts) {
        let model = Self.normalizeModel(model)
        let key = day + "|" + model
        if var b = map[key] {
            b.counts += counts
            b.requests += 1
            map[key] = b
        } else {
            map[key] = UsageBucket(day: day, tool: tool, model: model, counts: counts, requests: 1)
        }
    }

    /// 去掉 provider 前缀：cjj-jksb/qwenwork/qwen3.8-max -> qwen3.8-max
    public static func normalizeModel(_ model: String) -> String {
        if let idx = model.lastIndex(of: "/") {
        let suffix = String(model[model.index(after: idx)...])
            if !suffix.isEmpty { return suffix }
        }
        return model
    }

    public func merge(_ buckets: [UsageBucket]) {
        for b in buckets {
            let key = b.day + "|" + b.model
            if var e = map[key] {
                e.counts += b.counts
                e.requests += b.requests
                map[key] = e
            } else {
                map[key] = b
            }
        }
    }

    public var buckets: [UsageBucket] { Array(map.values) }
}

enum SourcePaths {
    static var home: String { NSHomeDirectory() }
    static func expand(_ p: String) -> String {
        p.hasPrefix("~") ? home + String(p.dropFirst(1)) : p
    }
    static func files(under dir: String, suffix: String) -> [String] {
        let fm = FileManager.default
        guard let root = fm.enumerator(atPath: expand(dir)) else { return [] }
        var out: [String] = []
        for case let rel as String in root {
            if rel.hasSuffix(suffix) { out.append(expand(dir) + "/" + rel) }
        }
        return out
    }
}
