import Foundation

/// 消耗速率采样器：用「今日总量」的差分估算 tokens/秒。
///
/// 单独抽出来是为了可测试——这个逻辑踩过坑：窗口比刷新间隔还短时，
/// 旧采样点一进来就被清掉，速率永远是 0（面板收起 + agent 在跑时最明显）。
public struct BurnRateSampler: Sendable {
    /// 采样保留窗口：必须 ≥ 2 倍的最大刷新间隔（面板 20s / 燃烧 60s / 空闲 180s，
    /// 所以至少要 360s，否则空闲节奏下两个采样点凑不到一起）
    public let window: TimeInterval
    /// 至少要跨这么久才认为速率可信，避免首轮抖动
    public let minSpan: TimeInterval
    private var samples: [(at: Date, total: Int64)] = []
    /// 最近一次算出的速率；样本不足时保持 0（表示「暂时测不出来」）
    public private(set) var rate: Int64 = 0

    public init(window: TimeInterval = 400, minSpan: TimeInterval = 8) {
        self.window = window
        self.minSpan = minSpan
    }

    /// 追加一次采样并重算速率
    @discardableResult
    public mutating func push(total: Int64, at now: Date) -> Int64 {
        samples.append((now, total))
        samples.removeAll { now.timeIntervalSince($0.at) > window }
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
        guard let last = samples.last else { return 0 }
        // 用「最近一次总量发生变化的那个采样点」做起点：
        // 轮询频率可能比统计刷新快很多，中间会插入大量总量未变的采样，
        // 拿最老的样本当起点会把速率稀释掉。
        let prev = samples.dropLast().last(where: { $0.total != last.total })
        if let prev, last.at.timeIntervalSince(prev.at) >= minSpan {
            let dt = last.at.timeIntervalSince(prev.at)
            rate = max(0, Int64(Double(last.total - prev.total) / dt))
        }
        return rate
    }

    public mutating func reset() {
        samples.removeAll()
        rate = 0
    }

    public var sampleCount: Int { samples.count }
}
