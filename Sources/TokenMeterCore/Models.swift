import Foundation

/// 四个口径的 token 计数（与各家 harness 日志对齐）
public struct TokenCounts: Codable, Equatable, Sendable {
    public var input: Int64       // 未命中缓存的输入
    public var output: Int64      // 输出（含 reasoning）
    public var cacheRead: Int64   // 缓存读取
    public var cacheWrite: Int64  // 缓存写入

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// 含缓存口径总量
    public var total: Int64 { input + output + cacheRead + cacheWrite }

    public static func + (l: TokenCounts, r: TokenCounts) -> TokenCounts {
        TokenCounts(input: l.input + r.input,
                    output: l.output + r.output,
                    cacheRead: l.cacheRead + r.cacheRead,
                    cacheWrite: l.cacheWrite + r.cacheWrite)
    }

    public static func += (l: inout TokenCounts, r: TokenCounts) { l = l + r }
}

/// 一个文件解析/缓存复用后的聚合桶：某天 + 某小时 + 某工具 + 某模型 + 某项目
public struct UsageBucket: Codable, Equatable, Sendable {
    public var day: String        // yyyy-MM-dd（本地时区）
    public var hour: Int          // 0...23
    public var tool: String
    public var model: String
    public var project: String    // 项目/仓库名；未知为 "-"
    public var session: String    // 会话/对话标识；未知为 "-"
    public var counts: TokenCounts
    public var requests: Int      // 模型调用次数

    public init(day: String, hour: Int = 0, tool: String, model: String, project: String = "-",
                session: String = "-", counts: TokenCounts, requests: Int) {
        self.day = day
        self.hour = hour
        self.tool = tool
        self.model = model
        self.project = project
        self.session = session
        self.counts = counts
        self.requests = requests
    }

    private enum CodingKeys: String, CodingKey {
        case day, hour, tool, model, project, session, counts, requests
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 0
        tool = try c.decode(String.self, forKey: .tool)
        model = try c.decode(String.self, forKey: .model)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? "-"
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? "-"
        counts = try c.decode(TokenCounts.self, forKey: .counts)
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
    }
}

public enum RangeKind: String, CaseIterable, Codable, Sendable {
    case today, yesterday, d7, d30, thisMonth, lastMonth, all
    public var label: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .d7: return "近 7 天"
        case .d30: return "近 30 天"
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .all: return "全部"
        }
    }
    /// 范围起始日（本地当天 0 点）的 day key；all 返回 nil
    public func startDayKey(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let startOfDay = calendar.startOfDay(for: now)
        switch self {
        case .today: return DayKey.key(for: startOfDay, calendar: calendar)
        case .yesterday:
            let d = calendar.date(byAdding: .day, value: -1, to: startOfDay)!
            return DayKey.key(for: d, calendar: calendar)
        case .d7:
            let d = calendar.date(byAdding: .day, value: -6, to: startOfDay)!
            return DayKey.key(for: d, calendar: calendar)
        case .d30:
            let d = calendar.date(byAdding: .day, value: -29, to: startOfDay)!
            return DayKey.key(for: d, calendar: calendar)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            return DayKey.key(for: calendar.date(from: comps)!, calendar: calendar)
        case .lastMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let thisMonthStart = calendar.date(from: comps)!
            let d = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return DayKey.key(for: d, calendar: calendar)
        case .all: return nil
        }
    }
    /// 范围结束日（闭区间）；开放式范围返回 nil
    /// 上一个等长周期的起止日（用于环比）；`.all` 无环比
    public func previousDayRange(now: Date = Date(), calendar: Calendar = .current) -> (start: String, end: String)? {
        guard let startKey = startDayKey(now: now, calendar: calendar),
              let start = DayKey.date(from: startKey, calendar: calendar) else { return nil }
        // 结束日：昨天=与起始同一天；上月=上月最后一天；其余=今天
        let end: Date
        switch self {
        case .yesterday:
            end = start
        case .lastMonth:
            guard let ek = endDayKey(now: now, calendar: calendar),
                  let d = DayKey.date(from: ek, calendar: calendar) else { return nil }
            end = d
        default:
            end = calendar.startOfDay(for: now)
        }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        guard days > 0,
              let prevEnd = calendar.date(byAdding: .day, value: -1, to: start),
              let prevStart = calendar.date(byAdding: .day, value: -(days - 1), to: prevEnd) else { return nil }
        return (DayKey.key(for: prevStart, calendar: calendar), DayKey.key(for: prevEnd, calendar: calendar))
    }

    public func endDayKey(now: Date = Date(), calendar: Calendar = .current) -> String? {
        switch self {
        case .yesterday: return startDayKey(now: now, calendar: calendar)
        case .lastMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let thisMonthStart = calendar.date(from: comps)!
            let d = calendar.date(byAdding: .day, value: -1, to: thisMonthStart)!
            return DayKey.key(for: d, calendar: calendar)
        default: return nil
        }
    }
}

public enum DayKey {
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let lock = NSLock()
    public static func date(from key: String, calendar: Calendar = .current) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fmt.date(from: key)
    }

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fmt.string(from: date)
    }
    public static func date(for key: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fmt.date(from: key)
    }
}

public struct ToolStat: Codable, Sendable {
    public var tool: String
    public var counts: TokenCounts
    public var cost: Double
    public var requests: Int
    public var share: Double   // 0...1，按含缓存总量
}

public struct ModelStat: Codable, Sendable {
    public var model: String
    public var counts: TokenCounts
    public var cost: Double
    public var requests: Int
    public var share: Double
    public var tools: [String]
}

public struct DayStat: Codable, Sendable {
    public var day: String
    public var counts: TokenCounts
    public var cost: Double
}

public struct ProjectStat: Codable, Sendable {
    public var project: String
    public var counts: TokenCounts
    public var cost: Double
    public var share: Double
    public var tools: [String]
}

public struct SessionStat: Codable, Sendable {
    public var session: String       // 会话标识（已缩短显示名）
    public var tool: String
    public var project: String
    public var counts: TokenCounts
    public var cost: Double
    public var requests: Int
    public var share: Double
    public var lastActive: String?   // yyyy-MM-dd HH:mm（该会话最后活动）
}

public struct HourStat: Codable, Sendable {
    public var hour: Int
    public var counts: TokenCounts
    public var cost: Double
}

public struct Summary: Codable, Sendable {
    public var range: RangeKind
    public var generatedAt: Date
    public var counts: TokenCounts
    public var cost: Double
    public var requests: Int
    public var cacheHitRate: Double        // cacheRead / (input + cacheRead)
    public var tools: [ToolStat]
    public var models: [ModelStat]
    public var days: [DayStat]             // 升序（按所选范围）
    public var trendDays: [DayStat]        // 近 30 天（含补零），与范围无关
    public var projects: [ProjectStat]     // 按项目降序
    public var hours: [HourStat]           // 逐小时（单日为当日 24 桶；多日为范围内按钟点汇总）
    public var hoursMode: String           // 逐小时图的标题说明
    public var sessions: [SessionStat]     // 按会话降序（Top N + 其他）
    public var unpricedModels: [String]    // 没有价格表条目的模型
    public var sourceStatuses: [SourceStatus]
    /// 环比：上一个等长周期的总量（用于「本周 vs 上周」）
    public var previousCounts: TokenCounts?
    public var previousCost: Double?
    /// 本月预测（仅在 range == .month 时有效）
    public var forecastCost: Double?
    public var forecastCounts: TokenCounts?
}

public struct SourceStatus: Codable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var files: Int
    public var note: String?
}
