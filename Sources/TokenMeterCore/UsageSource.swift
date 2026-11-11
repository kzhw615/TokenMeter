import Foundation

/// 分块 + 限流并行：边解析边回收，避免上千个压缩日志全量驻留造成内存尖峰
public enum BoundedParallel {
    /// 分块并行：每块用 concurrentPerform 并行解析，块间串行入库，
    /// 峰值内存只与块大小相关（避免上千个解压日志同时驻留）
    public static func chunkedMap<T, R>(
        _ items: [T],
        chunkSize: Int = 8,
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

/// 会话级统计（不走分桶，避免数千个历史文件各占一份分桶把内存撑爆）。
/// 结构：tool|project|session → day → model → counts
/// 保留模型维度是为了按官方单价算准费用，仅有近 7 天，内存可忽略。
public typealias SessionTotals = [String: [String: [String: TokenCounts]]]

public struct SessionAgg {
    private var map: SessionTotals = [:]
    /// 会话维度只看最近 N 天：更早的历史不再保留明细
    public static let windowDays = 7

    public init() {}

    public mutating func add(tool: String, path: String, project: String, buckets: [UsageBucket],
                             calendar: Calendar = .current) {
        guard let sync = Self.cutoffDay(calendar: calendar) else { return }
        let session = SessionName.from(path)
        let key = tool + "|" + project + "|" + session
        var existing = map[key] ?? [:]
        var touched = false
        for b in buckets where b.day >= sync {
            var days = existing[b.day] ?? [:]
            days[b.model, default: TokenCounts()] += b.counts
            existing[b.day] = days
            touched = true
        }
        guard touched else { return }
        map[key] = existing
    }

    public mutating func absorb(_ other: SessionTotals) {
        for (key, days) in other {
            var existing = map[key] ?? [:]
            for (day, models) in days {
                var ms = existing[day] ?? [:]
                for (model, c) in models { ms[model, default: TokenCounts()] += c }
                existing[day] = ms
            }
            map[key] = existing
        }
    }

    public var totals: SessionTotals { map }

    private static func cutoffDay(calendar: Calendar) -> String? {
        guard let d = calendar.date(byAdding: .day, value: -windowDays, to: Date()) else { return nil }
        return DayKey.key(for: d, calendar: calendar)
    }
}

public struct ScanResult {
    public var buckets: [UsageBucket]
    public var files: Int
    public var note: String?
    public var sessions: SessionTotals
    public init(buckets: [UsageBucket] = [], files: Int = 0, note: String? = nil,
                sessions: SessionTotals = [:]) {
        self.buckets = buckets
        self.files = files
        self.note = note
        self.sessions = sessions
    }
}

public enum ProjectName {
    /// dsh 会话目录名形如 --Users-kzhw-Documents-foo--，非 ASCII 字符编码为 ~HEXHEXHEXHEX 连续段
    /// 通用目录名解码：DSH 的 --Users-xx-Projects-foo-- 或普通目录名都尽量还原
    public static func decodeGeneric(_ raw: String) -> String {
        raw.hasPrefix("--") ? decodeDsh(raw) : raw
    }

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

public enum SessionName {
    /// 从日志路径推断会话标识（「按会话」排行用）。取短标识，避免缓存膨胀。
    public static func from(_ path: String) -> String {
        let comps = path.split(separator: "/").map(String.init)
        // DSH: .../session-<uuid>/session.v4.jsonl.zstd（也兼容 session.<x> 形式）
        if let dir = comps.dropLast().last, dir.hasPrefix("session") {
            let stripped = dir.drop { $0 == "s" || $0 == "e" || $0 == "s" || $0 == "i"
                || $0 == "o" || $0 == "n" || $0 == "-" || $0 == "." || $0 == "_" }
            let candidate = stripped.isEmpty ? dir : String(stripped)
            return short(candidate)
        }
        var name = comps.last ?? "-"
        for suf in [".jsonl.zst", ".jsonl.zstd", ".jsonl", ".zst", ".json", ".db", ".sqlite"] where name.hasSuffix(suf) {
            name = String(name.dropLast(suf.count)); break
        }
        // 文件名本身没有信息量（如 session.v4）时，退回上一级目录名
        if name.lowercased().hasPrefix("session"), comps.count >= 3 {
            let dir = comps[comps.count - 2]
            if !dir.lowercased().hasPrefix("session") { return short(ProjectName.decodeGeneric(dir)) }
        }
        // Codex: rollout-2026-11-11T11-09-52-<uuid> ⇒ 取 uuid
        if let last = name.split(separator: "-").last, last.count >= 8 {
            let tail = String(last)
            let isHex = tail.allSatisfy { ($0.isHexDigit) }
            if isHex { return short(tail) }
        }
        if let dash = name.split(separator: "-").last, dash.count >= 6 { return short(String(dash)) }
        return short(name)
    }

    private static func short(_ s: String) -> String {
        let t = s.prefix(8)
        return t.isEmpty ? "-" : String(t)
    }
}

/// 把 (day, hour, model, project, session) 粒度的累加器转成 UsageBucket 列表
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
            map[key] = UsageBucket(day: day, hour: hour, tool: tool, model: model, project: project,
                                   counts: counts, requests: 1)
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
    /// 首屏两阶段扫描：非 nil 时 files(under:) 只返回该时刻之后修改过的文件。
    /// 阶段一用它把「今天/昨天」的数据在几秒内算出来，阶段二再后台补齐历史。
    nonisolated(unsafe) public static var recentOnlyCutoff: Date?

    static func files(under dir: String, suffix: String) -> [String] {
        let fm = FileManager.default
        let base = expand(dir)
        guard let root = fm.enumerator(atPath: base) else { return [] }
        var out: [String] = []
        let cutoff = recentOnlyCutoff
        for case let rel as String in root {
            if rel.hasSuffix(suffix) {
                let full = base + "/" + rel
                if let cutoff, let m = mtime(full), m < cutoff { continue }
                out.append(full)
            }
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
