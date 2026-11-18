#if os(macOS)
import Foundation
import TokenMeterCore

/// 汇总结果缓存：把算好的 7 个区间 Summary 落盘，启动时直接拿来显示。
///
/// 为什么要它：扫描缓存（scan-v1.json）只缓存了「每个文件的用量桶」，
/// 启动时仍要重新聚合、并且要先等阶段一扫描完才能出图——面板刚打开那一下会空着，
/// 两阶段刷新时还会闪成不完整的数据。把最终 Summary 也缓存之后：
///   启动 → 立刻用上次结果渲染 → 后台照常刷新 → 有变化再替换
enum SummaryCache {
    private static let schemaVersion = 1
    private static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-v1.json")
    }

    private struct Payload: Codable {
        var version: Int
        var savedAt: Date
        var summaries: [String: Summary]
    }

    /// 超过这个时间的缓存不再用于首屏（避免显示太旧的数据）
    private static let maxAge: TimeInterval = 24 * 3600

    static func save(_ summaries: [RangeKind: Summary], at date: Date = Date()) {
        var map: [String: Summary] = [:]
        for (k, v) in summaries { map[k.rawValue] = v }
        let payload = Payload(version: schemaVersion, savedAt: date, summaries: map)
        // 编码 + 写盘放到后台：1.3MB 的 JSON 编码在主线程会造成可感知的卡顿
        let target = url
        DispatchQueue.global(qos: .utility).async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(payload) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    static func load(now: Date = Date()) -> (summaries: [RangeKind: Summary], savedAt: Date)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let payload = try? dec.decode(Payload.self, from: data),
              payload.version == schemaVersion,
              now.timeIntervalSince(payload.savedAt) < maxAge else { return nil }
        var out: [RangeKind: Summary] = [:]
        for (k, v) in payload.summaries {
            if let r = RangeKind(rawValue: k) { out[r] = v }
        }
        return out.isEmpty ? nil : (out, payload.savedAt)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
