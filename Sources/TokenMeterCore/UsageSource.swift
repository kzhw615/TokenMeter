import Foundation

/// 分块 + 限流并行：边解析边回收，避免上千个压缩日志全量驻留造成内存尖峰
public enum BoundedParallel {
    /// 分块并行：每块用 concurrentPerform 并行解析，块间串行入库，
    /// 峰值内存只与块大小相关（避免上千个解压日志同时驻留）
    public static func chunkedMap<T, R>(
        _ items: [T],
        chunkSize: Int = 32,
        transform: @escaping (T) -> R,
        handle: (T, R) -> Void
    ) {
        guard !items.isEmpty else { return }
        var index = 0
        while index < items.count {
            let end = min(index + chunkSize, items.count)
            let slice = Array(items[index..<end])
            let lock = NSLock()
            var results = [R?](repeating: nil, count: slice.count)
            DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                let value = transform(slice[i])
                lock.lock()
                results[i] = value
                lock.unlock()
            }
            for (i, item) in slice.enumerated() {
                if let value = results[i] { handle(item, value) }
            }
            index = end
        }
    }

    public static func forEach<T>(_ items: [T], _ body: @escaping (T) -> Void) {
        chunkedMap(items, transform: { body($0); return () }, handle: { _, _ in })
    }
}

public protocol UsageSource {
    var id: String { get }
    var displayName: String { get }
    /// 是否参与统计
    var enabledByDefault: Bool { get }
    /// 扫描并返回聚合桶；利用 cache 跳过未变化文件
    func scan(cache: inout ScanCache) -> ScanResult
    /// 全部日志文件路径（供热扫描/速率计算）
    func logFiles() -> [String]
    /// 解析单个文件（不经过缓存）
    func parseFile(path: String) -> [UsageBucket]
}

public extension UsageSource {
    func logFiles() -> [String] { [] }
    func parseFile(path: String) -> [UsageBucket] { [] }
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

public enum ProjectName {
    /// dsh 会话目录名形如 --Users-kzhw-Documents-foo--，非 ASCII 字符编码为 ~HEXHEXHEXHEX 连续段
    public static func decodeDsh(_ raw: String) -> String {
        var s = raw
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        s = s.replacingOccurrences(of: "-", with: "/")
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "~" {
                let hexStart = s.index(after: i)
                let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex) ?? s.endIndex
                let hex = String(s[hexStart..<hexEnd])
                if hex.count == 4, let scalar = UInt32(hex, radix: 16), let uni = Unicode.Scalar(scalar) {
                    out.append(Character(uni))
                    i = hexEnd
                } else {
                    out.append(s[i])
                    i = s.index(after: i)
                }
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return (out.split(separator: "/").last.map(String.init)) ?? raw
    }

    /// Claude 项目目录名：-Users-kzhw-Documents-foo → foo（取最后一段）；
    /// Windows 扁平布局（projects/xxx.jsonl）时返回未归属
    public static func decodeClaude(_ raw: String) -> String {
        if raw.hasSuffix(".jsonl") { return "-" }
        let parts = raw.split(separator: "-")
        return parts.last.map(String.init) ?? raw
    }

    public static func basename(_ path: String) -> String {
        let comps = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return comps.last.map(String.init) ?? path
    }
}

/// 把 (day, hour, model, project) 粒度的累加器转成 UsageBucket 列表
public final class BucketBuilder {
    private var map: [String: UsageBucket] = [:]
    private let tool: String
    public var project: String = "-"

    public init(tool: String) { self.tool = tool }

    public func add(date: Date, model: String, counts: TokenCounts, calendar: Calendar = .current) {
        let day = DayKey.key(for: date, calendar: calendar)
        let hour = calendar.component(.hour, from: date)
        add(day: day, hour: hour, model: model, counts: counts)
    }

    public func add(day: String, model: String, counts: TokenCounts) {
        add(day: day, hour: 0, model: model, counts: counts)
    }

    public func add(day: String, hour: Int, model: String, counts: TokenCounts) {
        let model = Self.normalizeModel(model)
        let key = day + "|" + String(hour) + "|" + model + "|" + project
        if var b = map[key] {
            b.counts += counts
            b.requests += 1
            map[key] = b
        } else {
            map[key] = UsageBucket(day: day, hour: hour, tool: tool, model: model, project: project, counts: counts, requests: 1)
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
            let key = b.day + "|" + String(b.hour) + "|" + b.model + "|" + b.project
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

public enum SourcePaths {
    static var home: String { NSHomeDirectory() }
    public static func expand(_ p: String) -> String {
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
    static func mtime(_ path: String) -> Date? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 并行取文件指纹：数千个 stat 串行是扫描的主要开销
    public static func parallelFingerprints(_ paths: [String]) -> [(size: Int64, mtime: Double)?] {
        guard !paths.isEmpty else { return [] }
        var out = [(size: Int64, mtime: Double)?](repeating: nil, count: paths.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let fp = ScanCache.fingerprint(path: paths[i])
            lock.lock(); out[i] = fp; lock.unlock()
        }
        return out
    }
}
