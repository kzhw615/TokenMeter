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
    /// 自动生成的模板版本；内置表更新后据此判断是否需要用新价目覆盖旧模板
    public var templateVersion: Int?

    public init(prices: [ModelPrice], templateVersion: Int? = nil) {
        self.prices = prices
        self.templateVersion = templateVersion
    }

    /// 大小写不敏感、按顺序子串匹配，第一个命中生效
    public func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        return prices.first { m.contains($0.pattern.lowercased()) }
    }

    public func cost(for counts: TokenCounts, model: String) -> Double {
        cost(for: counts, model: model, at: nil)
    }

    /// 计价：内置价目表即最终单价（不做时段倍率，保证与公开价目一致）
    public func cost(for counts: TokenCounts, model: String, at date: Date?) -> Double {
        guard let p = price(for: model) else { return 0 }
        var c = Double(counts.input) / 1e6 * p.input
        c += Double(counts.output) / 1e6 * p.output
        c += Double(counts.cacheRead) / 1e6 * (p.cacheRead ?? p.input * 0.1)
        c += Double(counts.cacheWrite) / 1e6 * (p.cacheWrite ?? p.input * 1.25)
        return c
    }

    // MARK: - 加载 / 保存

    public static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TokenMeter", isDirectory: true)
    }()

    public static var overrideURL: URL { supportDir.appendingPathComponent("pricing.json") }

    /// 内置默认表 + 用户覆盖（~/Library/Application Support/TokenMeter/pricing.json）
    /// 内置价目版本号：更新内置表时递增，用于把旧的自动生成模板升级到新价目
    public static let builtinVersion = 3

    public static func load() -> PricingTable {
        guard let data = try? Data(contentsOf: overrideURL) else {
            return PricingTable(prices: Self.builtin)
        }
        if let decoded = try? JSONDecoder().decode(PricingTable.self, from: data) {
            // 无版本号 = 用户自己维护的表，完全以它为准
            guard let v = decoded.templateVersion else {
                return PricingTable(prices: decoded.prices)
            }
            if v >= builtinVersion { return PricingTable(prices: decoded.prices) }
            // 旧模板：换上新的内置价目，但保留用户自行添加（不在内置表中）的型号
            let builtinPatterns = Set(Self.builtin.map { $0.pattern })
            let custom = decoded.prices.filter { !builtinPatterns.contains($0.pattern) }
            return PricingTable(prices: Self.builtin + custom, templateVersion: builtinVersion)
        }
        if let arr = try? JSONDecoder().decode([ModelPrice].self, from: data) {
            return PricingTable(prices: arr)
        }
        return PricingTable(prices: Self.builtin)
    }

    /// 首次运行写出模板；内置表升级后自动刷新旧模板（保留用户自定义型号）
    public static func writeTemplateIfMissing() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: overrideURL.path) else {
            try? save(PricingTable(prices: builtin, templateVersion: builtinVersion))
            return
        }
        guard let data = try? Data(contentsOf: overrideURL),
              let decoded = try? JSONDecoder().decode(PricingTable.self, from: data),
              let v = decoded.templateVersion, v < builtinVersion else { return }
        let builtinPatterns = Set(builtin.map { $0.pattern })
        let custom = decoded.prices.filter { !builtinPatterns.contains($0.pattern) }
        try? save(PricingTable(prices: builtin + custom, templateVersion: builtinVersion))
    }

    /// 把价格表写入用户覆盖文件 pricing.json
    public static func save(_ table: PricingTable) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(table).write(to: overrideURL, options: .atomic)
    }

    /// 内置价格表（USD / 1M tokens，2026-11 更新）。
    /// 明细价优先，行尾的「家族兜底」用于未单列的型号；按顺序子串匹配，先命中者生效，
    /// 因此「具体型号」必须排在「型号前缀」「家族兜底」之前。
    /// DeepSeek 存空闲时段价，高峰时段（北京时间工作日 9-12 / 14-18）自动 ×2。
    public static let builtin: [ModelPrice] = [
        // ── Anthropic ──────────────────────────────────────────────
        .init(pattern: "claude-opus-5.5", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5),
        .init(pattern: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5),
        .init(pattern: "claude-opus-4-8", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4-7", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4-6", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(pattern: "claude-opus-4", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        .init(pattern: "claude-fable-5-1", input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        .init(pattern: "claude-fable-5", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        .init(pattern: "claude-mythos-5-1", input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        .init(pattern: "claude-mythos-5", input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        .init(pattern: "claude-sonnet-5-5", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5),
        .init(pattern: "claude-sonnet-5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        .init(pattern: "claude-sonnet-4-6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-sonnet-4-5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-sonnet-4", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-haiku-5-5", input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125),
        .init(pattern: "claude-haiku-4-5", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        .init(pattern: "claude-3-7-sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-3-5-sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(pattern: "claude-3-5-haiku", input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1),

        // ── OpenAI ────────────────────────────────────────────────
        .init(pattern: "gpt-6-astra", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        .init(pattern: "gpt-6.1-sol", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5),
        .init(pattern: "gpt-6.1-terra", input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25),
        .init(pattern: "gpt-6-sol", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        .init(pattern: "gpt-6-terra", input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25),
        .init(pattern: "gpt-6-luna", input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125),
        .init(pattern: "gpt-5.6-sol", input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5),
        .init(pattern: "gpt-5.6-terra", input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5),
        .init(pattern: "gpt-5.6-luna", input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25),
        .init(pattern: "gpt-5.5", input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5),
        .init(pattern: "gpt-5-5", input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5),
        .init(pattern: "gpt-5.4", input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5),
        .init(pattern: "gpt-5-4", input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5),
        .init(pattern: "gpt-5-mini", input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0.25),
        .init(pattern: "gpt-5.3-codex", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 2.1875),
        .init(pattern: "gpt-5.2", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 2.1875, note: "estimate"),
        .init(pattern: "gpt-5.1-codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-5-codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-5.1", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-5", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.5625, note: "estimate"),
        .init(pattern: "gpt-reserve", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, note: "estimate"),
        .init(pattern: "codex-auto-review", input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, note: "estimate: Codex 内部审查模型，按 luna 档"),
        .init(pattern: "fast-model", input: 0.143, output: 0.571, cacheRead: 0.0029, cacheWrite: 0.179, note: "estimate: WorkBuddy 内部别名"),
        .init(pattern: "wb-lite", input: 0.143, output: 0.571, cacheRead: 0.0029, cacheWrite: 0.179, note: "estimate: WorkBuddy 内部别名"),
        .init(pattern: "o4-mini", input: 1.1, output: 4.4, cacheRead: 0.275),
        .init(pattern: "o3", input: 2, output: 8, cacheRead: 0.5),

        // ── Google Gemini ─────────────────────────────────────────
        .init(pattern: "gemini-4-argon", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2),
        .init(pattern: "gemini-4-carbon", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2),
        .init(pattern: "gemini-4", input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2),
        .init(pattern: "gemini-3.8-flash", input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.75),
        .init(pattern: "gemini-3.7-flash", input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.75),
        .init(pattern: "gemini-3.6-flash", input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.75),
        .init(pattern: "gemini-3.5-flash", input: 0.3, output: 2.5, cacheRead: 0.03, cacheWrite: 0.3),
        .init(pattern: "gemini-3.1-pro", input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2),
        .init(pattern: "gemini-3-1-pro", input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2),
        .init(pattern: "gemini-3-pro", input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2),
        .init(pattern: "gemini-3-flash", input: 0.5, output: 3, cacheRead: 0.05, cacheWrite: 0.5),
        .init(pattern: "gemini-2.5-pro", input: 1.25, output: 10, cacheRead: 0.125),
        .init(pattern: "gemini-2.5-flash", input: 0.3, output: 2.5, cacheRead: 0.03),

        // ── 智谱 GLM ──────────────────────────────────────────────
        .init(pattern: "glm-5-3-flashx", input: 0.37, output: 1.25, cacheRead: 0.075, cacheWrite: 0.37),
        .init(pattern: "glm-5-3-flash", input: 0.15, output: 0.5, cacheRead: 0.03, cacheWrite: 0.15),
        .init(pattern: "glm-5-3", input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4),
        .init(pattern: "glm-5-2", input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4),
        .init(pattern: "glm-5-1", input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4),
        .init(pattern: "glm-5", input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4, note: "estimate: 家族兜底"),
        .init(pattern: "glm-4.7-flash", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, note: "免费"),
        .init(pattern: "glm-4", input: 0.4, output: 1.6, cacheRead: 0.08, note: "estimate"),
        .init(pattern: "glm", input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4, note: "estimate: 家族兜底"),

        // ── DeepSeek（按公开价目原值使用，不再按时段折算）─────────────
        .init(pattern: "deepseek-v4-pro", input: 1.32, output: 3.96, cacheRead: 0.044, cacheWrite: 1.32),
        .init(pattern: "deepseek-v4.1-flash", input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3),
        .init(pattern: "deepseek-v4-flash", input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3),
        .init(pattern: "deepseek-v4", input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3, note: "estimate: 同 v4-flash"),
        .init(pattern: "deepseek-chat", input: 0.28, output: 0.42, cacheRead: 0.028, cacheWrite: 0.28),
        .init(pattern: "deepseek", input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3, note: "estimate: 家族兜底"),

        // ── 通义千问 ──────────────────────────────────────────────
        .init(pattern: "qwen3.8-max", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143),
        .init(pattern: "qwen3.7-max", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143),
        .init(pattern: "qwen3-max", input: 1.714, output: 5.143, cacheRead: 0.171, cacheWrite: 2.143, note: "estimate: 同 qwen3.8-max"),
        .init(pattern: "omni-flash", input: 0.114, output: 0.386, cacheRead: 0.0114, cacheWrite: 0.143),
        .init(pattern: "qwen-flash", input: 0.114, output: 0.386, cacheRead: 0.0114, cacheWrite: 0.143),
        .init(pattern: "qwen-plus", input: 0.114, output: 0.286, cacheRead: 0.0114, cacheWrite: 0.143),
        .init(pattern: "qwen", input: 0.4, output: 1.2, cacheRead: 0.06, cacheWrite: 0.4, note: "estimate: 家族兜底"),

        // ── Moonshot Kimi ─────────────────────────────────────────
        .init(pattern: "kimi-k3.1-pro-highspeed", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 4),
        .init(pattern: "kimi-k3.1-pro", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2),
        .init(pattern: "kimi-k3", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3),
        .init(pattern: "kimi-k2.7-code", input: 0.95, output: 4, cacheRead: 0.19, cacheWrite: 0.95),
        .init(pattern: "kimi-k2.6", input: 0.95, output: 4, cacheRead: 0.16, cacheWrite: 0.95),
        .init(pattern: "kimi-k2", input: 0.95, output: 4, cacheRead: 0.16, cacheWrite: 0.95, note: "estimate: 同 k2.6"),
        .init(pattern: "kimi", input: 0.95, output: 4, cacheRead: 0.16, cacheWrite: 0.95, note: "estimate: 家族兜底"),

        // ── MiniMax ──────────────────────────────────────────────
        .init(pattern: "minimax-m3.1-flash", input: 0.15, output: 0.6, cacheRead: 0.015, cacheWrite: 0.15),
        .init(pattern: "minimax-m3", input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.3),
        .init(pattern: "minimax-m2.7-highspeed", input: 0.6, output: 2.4, cacheRead: 0.06, cacheWrite: 0.375),
        .init(pattern: "minimax-m2.7", input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.375),
        .init(pattern: "minimax", input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.3, note: "estimate: 家族兜底"),

        // ── 小米 MiMo ────────────────────────────────────────────
        .init(pattern: "mimo-v2.6-pro-ultraspeed", input: 4.35, output: 8.7, cacheRead: 0.036, cacheWrite: 4.35),
        .init(pattern: "mimo-v2.6-pro", input: 0.435, output: 0.87, cacheRead: 0.0036, cacheWrite: 0.435),
        .init(pattern: "mimo-v2.6-flash", input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0.14),
        .init(pattern: "mimo-v2.5-pro", input: 1, output: 3, cacheRead: 0.2, cacheWrite: 0),
        .init(pattern: "mimo-v2.5", input: 0.4, output: 2, cacheRead: 0.08, cacheWrite: 0),
        .init(pattern: "mimo", input: 0.4, output: 2, cacheRead: 0.06, cacheWrite: 0.4, note: "estimate: 家族兜底"),

        // ── xAI Grok ─────────────────────────────────────────────
        .init(pattern: "grok-4-fast", input: 0.2, output: 0.5, cacheRead: 0.2, cacheWrite: 0.2),
        .init(pattern: "grok-4.7", input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2),
        .init(pattern: "grok-4.6", input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2),
        .init(pattern: "grok-4.5", input: 2, output: 6, cacheRead: 0.3, cacheWrite: 2),
        .init(pattern: "grok-4", input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2),

        // ── 腾讯混元 ──────────────────────────────────────────────
        .init(pattern: "hy4-preview", input: 0.834, output: 2.501, cacheRead: 0.042, cacheWrite: 0.834),
        .init(pattern: "hy3", input: 0.132, output: 0.528, cacheRead: 0.033, cacheWrite: 0.132),
        .init(pattern: "hunyuan", input: 0.15, output: 0.4, cacheRead: 0.0225, cacheWrite: 0.15, note: "estimate: 家族兜底"),

        // ── 阶跃 Step ─────────────────────────────────────────────
        .init(pattern: "step-5-preview", input: 1, output: 2.7, cacheRead: 0.1, cacheWrite: 1),
        .init(pattern: "step-3.7-flash", input: 0.2, output: 1.15, cacheRead: 0.04, cacheWrite: 0.2),
        .init(pattern: "step-", input: 0.5, output: 2, cacheRead: 0.075, cacheWrite: 0.5, note: "estimate: 家族兜底"),

        // ── Cursor Composer ──────────────────────────────────────
        .init(pattern: "composer-2.5-fast", input: 3, output: 15, cacheRead: 0.5, cacheWrite: 3),
        .init(pattern: "composer-2.5", input: 0.5, output: 2, cacheRead: 0.2, cacheWrite: 0.5),
        .init(pattern: "composer", input: 0.5, output: 2, cacheRead: 0.2, cacheWrite: 0.5, note: "estimate"),

        // ── 豆包 / 方舟（家族兜底）────────────────────────────────
        .init(pattern: "doubao", input: 0.11, output: 0.28, cacheRead: 0.0165, cacheWrite: 0.11, note: "家族兜底"),
        .init(pattern: "ark-", input: 0.11, output: 0.28, cacheRead: 0.0165, cacheWrite: 0.11, note: "家族兜底"),

        // ── 美团 LongCat ─────────────────────────────────────────
        .init(pattern: "longcat", input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3),
    ]
}
