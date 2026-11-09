import Foundation

/// 文件级扫描缓存：path -> (size, mtime, 已聚合桶)。
/// 只有指纹变化的文件才会重新解析，codex 6.9GB 日志二次扫描接近零成本。
public struct ScanCache: Codable {
    public struct Entry: Codable {
        public var size: Int64
        public var mtime: Double
        public var buckets: [UsageBucket]
    }
    public var version: Int = 2
    public var entries: [String: Entry] = [:]
    /// 本次会话是否有新解析（决定是否值得写回磁盘），不持久化
    public var dirty: Bool = false

    private enum CodingKeys: String, CodingKey { case version, entries }

    public init() {}

    public static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TokenMeter", isDirectory: true)
    }()
    public static var url: URL { cacheDir.appendingPathComponent("scan-v1.json") }

    public static func load() -> ScanCache {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(ScanCache.self, from: data),
              c.version == 2 else { return ScanCache() }
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

    /// 若文件未变化返回缓存桶；否则返回 nil 表示需要重新解析
    public func cachedBuckets(path: String) -> [UsageBucket]? {
        guard let fp = Self.fingerprint(path: path),
              let e = entries[path],
              e.size == fp.size, abs(e.mtime - fp.mtime) < 0.001 else { return nil }
        return e.buckets
    }

    public mutating func store(path: String, buckets: [UsageBucket]) {
        guard let fp = Self.fingerprint(path: path) else { return }
        entries[path] = Entry(size: fp.size, mtime: fp.mtime, buckets: buckets)
        dirty = true
    }
}
