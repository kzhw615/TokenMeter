import Foundation

/// 文件级扫描缓存：path -> (size, mtime, 已聚合桶)。
/// 只有指纹变化的文件才会重新解析，codex 6.9GB 日志二次扫描接近零成本。
public struct ScanCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var buckets: [UsageBucket]
        /// 已解析到的字节偏移（append-only 日志增量解析用）
        public var offset: Int64
        /// 增量解析时需要沿用的上下文（如 DSH 会话当前模型）
        public var lastModel: String?
        public init(size: Int64, mtime: Double, buckets: [UsageBucket], offset: Int64 = 0, lastModel: String? = nil) {
            self.size = size
            self.mtime = mtime
            self.buckets = buckets
            self.offset = offset
            self.lastModel = lastModel
        }
    }
    public var version: Int = 7   // v7: 允许空结果落盘（避免无用量文件每次重解析）+ 增量 offset
    public var entries: [String: Entry] = [:]
    /// 本次会话是否有新解析（决定是否值得写回磁盘），不持久化
    public var dirty: Bool = false

    /// 线程 id → 模型名。Codex 的子智能体会话文件不记录模型，
    /// 只能靠父线程继承；这里持久化映射，避免每次都重建。
    public var threadModels: [String: String]?

    private enum CodingKeys: String, CodingKey { case version, entries, threadModels }

    public init() {}

    public static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TokenMeter", isDirectory: true)
    }()
    public static var url: URL { cacheDir.appendingPathComponent("scan-v1.json") }

    public static func load() -> ScanCache {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(ScanCache.self, from: data),
              // v5+ 兼容：会话维度是从缓存分桶现场派生的，不进缓存结构，
              // 因此升级不会触发全量重建
              c.version >= 5 else { return ScanCache() }
        return c
    }

    public func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }

    public static func fingerprint(path: String) -> (size: Int64, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 ?? (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (size, mtime.timeIntervalSince1970)
    }

    /// 用调用方已取得的指纹判断（避免重复 stat）
    public func cachedBuckets(path: String, size: Int64, mtime: Double) -> [UsageBucket]? {
        guard let e = entries[path],
              e.size == size, abs(e.mtime - mtime) < 0.001 else { return nil }
        return e.buckets
    }

    /// 若文件未变化返回缓存桶（可能为空数组，表示该文件确实无用量）；未变化才返回，否则 nil
    public func cachedBuckets(path: String) -> [UsageBucket]? {
        guard let fp = Self.fingerprint(path: path),
              let e = entries[path],
              e.size == fp.size, abs(e.mtime - fp.mtime) < 0.001 else { return nil }
        return e.buckets
    }

    public mutating func store(path: String, buckets: [UsageBucket]) {
        store(path: path, buckets: buckets, offset: Self.fingerprint(path: path)?.size ?? 0)
    }

    public mutating func store(path: String, buckets: [UsageBucket], offset: Int64, lastModel: String? = nil) {
        // 空桶也可以落盘：条目只在「解析完成」后写入，空结果代表该文件确实没有用量。
        // （历史上曾因 App 与 CLI 并发写半成品缓存导致空桶被当有效缓存，现已用串行落盘 + 全量原子写修复）

        guard let fp = Self.fingerprint(path: path) else { return }
        entries[path] = Entry(size: fp.size, mtime: fp.mtime, buckets: buckets, offset: offset, lastModel: lastModel)
        dirty = true
    }

    public func cachedEntry(path: String) -> Entry? {
        entries[path]
    }

    /// 仅当文件指纹未变时返回条目（含 offset，即使 buckets 为空也可用于增量解析）
    public func freshEntry(path: String) -> Entry? {
        guard let fp = Self.fingerprint(path: path), let e = entries[path] else { return nil }
        guard e.size == fp.size, abs(e.mtime - fp.mtime) < 0.001 else { return nil }
        return e
    }

    /// 更新条目（保留增量 offset 与解析上下文）
    public mutating func update(path: String, buckets: [UsageBucket], offset: Int64, lastModel: String? = nil) {
        guard let fp = Self.fingerprint(path: path) else { return }
        entries[path] = Entry(size: fp.size, mtime: fp.mtime, buckets: buckets, offset: offset, lastModel: lastModel)
        dirty = true
    }
}
