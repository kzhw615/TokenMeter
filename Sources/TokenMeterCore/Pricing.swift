import Foundation

/// 每百万 token 的美元单价
public struct ModelPrice: Codable, Equatable {
    public var pattern: String     // 小写子串匹配
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var note: String?

    public init(pattern: String, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, note: String? = nil) {
        self.pattern = pattern
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.note = note
    }
}

public struct PricingTable: Codable {
    public var prices: [ModelPrice]

    public init(prices: [ModelPrice]) { self.prices = prices }

    /// 大小写不敏感、按顺序子串匹配，第一个命中生效
    public func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        return prices.first { m.contains($0.pattern.lowercased()) }
    }

    public func cost(for counts: TokenCounts, model: String) -> Double {
        cost(for: counts, model: model, at: nil)
    }

    /// 带时间的计价：DeepSeek 官方分高峰/空闲时段（北京时间工作日 9:00-12:00、14:00-18:00 为高峰，
    /// 高峰价 = 空闲价 ×2）。内置表存空闲价，命中高峰时段自动 ×2。
    public func cost(for counts: TokenCounts, model: String, at date: Date?) -> Double {
        guard let p = price(for: model) else { return 0 }
        let mult: Double
        if let date, model.lowercased().contains("deepseek"), Self.isDeepSeekPeak(date) {
            mult = 2.0
        } else {
            mult = 1.0
        }
        var c = Double(counts.input) / 1e6 * p.input
        c += Double(counts.output) / 1e6 * p.output
        c += Double(counts.cacheRead) / 1e6 * (p.cacheRead ?? p.input * 0.1)
        c += Double(counts.cacheWrite) / 1e6 * (p.cacheWrite ?? p.input * 1.25)
        return c * mult
    }

    /// 北京时间工作日 9:00-12:00 / 14:00-18:00 为 DeepSeek 高峰时段
    public static func isDeepSeekPeak(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = cal.component(.weekday, from: date)   // 1=周日 ... 7=周六
        guard (2...6).contains(weekday) else { return false }
        let hour = cal.component(.hour, from: date)
        return (9..<12).contains(hour) || (14..<18).contains(hour)
    }

    // MARK: - 加载 / 保存

    public static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TokenMeter", isDirectory: true)
    }()

    public static var overrideURL: URL { supportDir.appendingPathComponent("pricing.json") }

    /// 内置默认表 + 用户覆盖（~/Library/Application Support/TokenMeter/pricing.json）
    public static func load() -> PricingTable {
        var table = PricingTable(prices: Self.builtin)
        if let data = try? Data(contentsOf: overrideURL),
           let decoded = try? JSONDecoder().decode(PricingTable.self, from: data) {
            table = decoded
        } else if let data = try? Data(contentsOf: overrideURL),
                  let arr = try? JSONDecoder().decode([ModelPrice].self, from: data) {
            table = PricingTable(prices: arr)
        }
        return table
    }

    public static func writeTemplateIfMissing() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: overrideURL.path) {
            try? save(PricingTable(prices: builtin))
        }
    }

    /// 把价格表写入用户覆盖文件 pricing.json
    public static func save(_ table: PricingTable) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(table).write(to: overrideURL, options: .atomic)
    }

    /// 内置价格表（USD / 1M tokens）。
    /// 来源：各家官方 API 定价页（2026-11 抓取）：developers.openai.com/api/docs/pricing、
    /// anthropic.com/pricing、ai.google.dev/gemini-api/docs/pricing、api-docs.deepseek.com/quick_start/pricing、
    /// help.aliyun.com/zh/model-studio/model-pricing。
    /// DeepSeek 为空闲时段价（人民币按 7.0 汇率折算）；千问缓存命中按输入价 10%、显式创建按 125%。
    /// 个别已下线的历史模型（gpt-5.x 等）为同系估算，可用 pricing.json 覆盖。
    public static let builtin: [ModelPrice] = [
        // Anthropic（first-party 全球价）
        .init(pattern: "claude-opus-4-7", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4-6", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        .init(pattern: "claude-sonnet-4-6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-sonnet-4-5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-sonnet-4", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-haiku-4-5", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        .init(pattern: "claude-3-7-sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-3-5-sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-3-5-haiku", input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),
        // OpenAI（Standard 档）
        .init(pattern: "gpt-6-astra", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        .init(pattern: "gpt-6.1-sol", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5),
        .init(pattern: "gpt-6-sol", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, note: "estimate: 同 6.1-sol"),
        .init(pattern: "gpt-6.1-terra", input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25),
        .init(pattern: "gpt-6-terra", input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25, note: "estimate: 同 6.1-terra"),
        .init(pattern: "gpt-6-luna", input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125),
        .init(pattern: "gpt-5.6-sol", input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5),
        .init(pattern: "gpt-5.5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, note: "estimate"),
        .init(pattern: "gpt-5.4", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 2.1875, note: "estimate: 同 5.3-codex"),
        .init(pattern: "gpt-5.3-codex", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 2.1875),
        .init(pattern: "gpt-5.2", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 2.1875, note: "estimate"),
        .init(pattern: "gpt-5.1-codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-5-codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-5.1", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-5", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-reserve", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, note: "estimate"),
        .init(pattern: "codex-auto-review", input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, note: "estimate: Codex 内部审查模型，按 luna 档"),
        .init(pattern: "fast-model", input: 0.143, output: 0.571, cacheRead: 0.0029, cacheWrite: 0.179, note: "estimate: WorkBuddy 内部别名，按 flash 档"),
        .init(pattern: "wb-lite", input: 0.143, output: 0.571, cacheRead: 0.0029, cacheWrite: 0.179, note: "estimate: WorkBuddy 内部别名，按 flash 档"),
        .init(pattern: "o4-mini", input: 1.1, output: 4.4, cacheRead: 0.275),
        .init(pattern: "o3", input: 2, output: 8, cacheRead: 0.5),
        // Google Gemini
        .init(pattern: "gemini-4", input: 2, output: 10, cacheRead: 0.1),
        .init(pattern: "gemini-3.8-flash", input: 0.75, output: 3.75, cacheRead: 0.075),
        .init(pattern: "gemini-3.6-flash", input: 0.75, output: 3.75, cacheRead: 0.075),
        .init(pattern: "gemini-3.5-flash", input: 0.3, output: 2.5, cacheRead: 0.03),
        .init(pattern: "gemini-3.1-pro", input: 2, output: 12, cacheRead: 0.2),
        .init(pattern: "gemini-3-pro", input: 2, output: 12, cacheRead: 0.2),
        .init(pattern: "gemini-3-flash", input: 0.5, output: 3, cacheRead: 0.05),
        .init(pattern: "gemini-2.5-pro", input: 1.25, output: 10, cacheRead: 0.125),
        .init(pattern: "gemini-2.5-flash", input: 0.3, output: 2.5, cacheRead: 0.03),
        // DeepSeek（空闲时段价，CNY@7.0 折算）
        .init(pattern: "deepseek-v4-pro", input: 0.643, output: 1.929, cacheRead: 0.0214, cacheWrite: 0.804),
        .init(pattern: "deepseek-v4", input: 0.643, output: 1.929, cacheRead: 0.0214, cacheWrite: 0.804),
        .init(pattern: "deepseek-flash", input: 0.143, output: 0.571, cacheRead: 0.0029, cacheWrite: 0.179),
        .init(pattern: "deepseek", input: 0.143, output: 0.571, cacheRead: 0.0029, cacheWrite: 0.179),
        // Qwen 千问（CNY@7.0 折算；缓存命中=输入价 10%，显式创建=125%）
        .init(pattern: "qwen3.8-max", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143),
        .init(pattern: "qwen3.7-max", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143),
        .init(pattern: "qwen3-max", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143, note: "estimate: 同 qwen3.8-max"),
        .init(pattern: "omni-flash", input: 0.114, output: 0.386, cacheRead: 0.0114, cacheWrite: 0.143),
        .init(pattern: "qwen-flash", input: 0.114, output: 0.386, cacheRead: 0.0114, cacheWrite: 0.143),
        .init(pattern: "qwen-plus", input: 0.114, output: 0.286, cacheRead: 0.0114, cacheWrite: 0.143, note: "estimate"),
        .init(pattern: "qwen", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143, note: "estimate: 按 qwen3.8-max"),
        // Zhipu GLM
        .init(pattern: "glm-5", input: 1, output: 4, cacheRead: 0.2, note: "estimate"),
        .init(pattern: "glm-4", input: 0.4, output: 1.6, cacheRead: 0.08, note: "estimate"),
        // Moonshot
        .init(pattern: "kimi-k2", input: 0.6, output: 2.5, cacheRead: 0.06, note: "estimate"),
        .init(pattern: "kimi", input: 0.6, output: 2.5, cacheRead: 0.06, note: "estimate"),
    ]
}
