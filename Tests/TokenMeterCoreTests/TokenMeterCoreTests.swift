import XCTest
@testable import TokenMeterCore

final class TokenMeterCoreTests: XCTestCase {
    var tmp: String!

    override func setUp() {
        tmp = NSTemporaryDirectory() + "tmtest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func write(_ name: String, _ content: String) -> String {
        let p = tmp + "/" + name
        try! content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    // MARK: - 解析器

    func testClaudeParsingAndDedup() {
        let line = #"{"type":"assistant","timestamp":"2026-11-09T10:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":800,"cache_creation_input_tokens":200}}}"#
        let p = write("a.jsonl", line + "\n" + line + "\n")
        let buckets = ClaudeCodeSource().parseFile(path: p)
        XCTAssertEqual(buckets.count, 1, "同 message.id 应去重")
        XCTAssertEqual(buckets[0].counts.total, 1150)
        XCTAssertEqual(buckets[0].requests, 1)
        XCTAssertEqual(buckets[0].model, "claude-sonnet-4-5")
    }

    func testCodexParsingAndProject() {
        let meta = #"{"timestamp":"2026-11-09T10:00:00Z","type":"session_meta","payload":{"model":"gpt-6.1-sol","cwd":"/x/y/proj"}}"#
        let tc = #"{"timestamp":"2026-11-09T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":60,"reasoning_output_tokens":10}}}}"#
        let p = write("r.jsonl", meta + "\n" + tc + "\n")
        let b = CodexSource().parseFile(path: p)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].counts.input, 400, "input 应扣除 cached")
        XCTAssertEqual(b[0].counts.cacheRead, 600)
        XCTAssertEqual(b[0].counts.output, 60, "output_tokens 已含 reasoning（子集，不重复加）")
        XCTAssertEqual(b[0].project, "proj")
        XCTAssertEqual(b[0].model, "gpt-6.1-sol")
    }

    func testWorkBuddyToolOutputUsage() {
        let resp: [String: Any] = [
            "model": "custom-local:deepseek/deepseek-flash",
            "choices": [[String: Any]](),
            "usage": ["prompt_tokens": 500, "completion_tokens": 100,
                      "prompt_tokens_details": ["cached_tokens": 300]],
        ]
        let arrData = try! JSONSerialization.data(withJSONObject: [resp])
        let span: [String: Any] = [
            "type": "span_end",
            "span": ["type": "generation",
                     "endedAt": "2026-11-09T10:00:00.000Z",
                     "toolOutput": String(decoding: arrData, as: UTF8.self)],
        ]
        let lineData = try! JSONSerialization.data(withJSONObject: span)
        let p = write("trace_x.jsonl", String(decoding: lineData, as: UTF8.self) + "\n")
        let b = WorkBuddySource().parseFile(path: p)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].counts.total, 600)
        XCTAssertEqual(b[0].counts.cacheRead, 300)
        XCTAssertEqual(b[0].model, "deepseek-flash", "应剥离 custom-local: 前缀")
    }

    /// 中断的会话（停在 tool/call）长时间未写入时，不应永久判定为「运行中」
    func testDshStaleSessionNotRunning() throws {
        let base = tmp + "/sessions-stale"
        let dir = base + "/--proj--/session-abc"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/session.v4.jsonl.zstd"
        try Data([0x28, 0xB5, 0x2F, 0xFD, 0x00]).write(to: URL(fileURLWithPath: file))
        // 把文件时间设成 1 小时前
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file)

        XCTAssertEqual(DshSource.isTaskRunning(now: Date(), baseDir: base), false,
                       "超过 staleness 未写入应判定为已停止")
    }

    /// 判定矩阵：锁释放应尽快判停；锁持有时长工具不误判；无锁信息时用时间上限
    func testDshResolveTaskRunning() {
        // 锁已释放（进程退出）
        XCTAssertEqual(DshSource.resolveTaskRunning(silent: 10, lockHeld: false), nil, "刚写入先按尾部事件判断")
        XCTAssertEqual(DshSource.resolveTaskRunning(silent: 60, lockHeld: false), false, "锁释放且已静默应判停")

        // 锁仍被持有：长工具执行（实测最长 990s）不能误判
        XCTAssertEqual(DshSource.resolveTaskRunning(silent: 990, lockHeld: true), nil, "锁持有 + 990s 静默仍需看事件")
        XCTAssertEqual(DshSource.resolveTaskRunning(silent: 1801, lockHeld: true), false, "锁持有但超 30 分钟兜底判停")

        // 无锁信息：退回 180s 上限
        XCTAssertEqual(DshSource.resolveTaskRunning(silent: 100, lockHeld: nil), nil)
        XCTAssertEqual(DshSource.resolveTaskRunning(silent: 200, lockHeld: nil), false)
    }

    /// 锁检测：对方持有 flock 时应识别为「被持有」，释放后应识别为「未持有」
    func testDshSessionLockHeld() {
        let path = tmp + "/session.lock"
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertEqual(DshSource.isSessionLockHeld(lockPath: path), false, "无人持有")

        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "测试进程先独占")
        XCTAssertEqual(DshSource.isSessionLockHeld(lockPath: path), true, "已被独占持有")
        flock(fd, LOCK_UN)
        close(fd)
        XCTAssertEqual(DshSource.isSessionLockHeld(lockPath: path), false, "释放后应识别为未持有")

        // 没有 lock 文件时无法判断
        XCTAssertNil(DshSource.isSessionLockHeld(lockPath: tmp + "/nope.lock"))
    }

    // MARK: - 新维度：会话 / 环比 / 预测 / 体检

    /// 环比：d7 应能算出上一个 7 天
    func testPreviousPeriodRange() {
        let cal = Calendar.current
        let now = DayKey.date(from: "2026-11-11")!
        let r = RangeKind.d7.previousDayRange(now: now, calendar: cal)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.end, "2026-11-04", "上一个周期应紧邻本周期起点前一天")
        XCTAssertEqual(r?.start, "2026-10-29")
        XCTAssertNil(RangeKind.all.previousDayRange(now: now, calendar: cal), "全部范围无环比")
    }

    // MARK: - 价格表

    /// 具体型号必须排在家族兜底之前，否则会被兜底价吃掉
    func testPricingOrderSpecificBeforeFallback() {
        let table = PricingTable(prices: PricingTable.builtin)
        XCTAssertEqual(table.price(for: "gpt-5-mini")?.input, 0.25, "gpt-5-mini 不能被 gpt-5 兜底")
        XCTAssertEqual(table.price(for: "glm-5-3-flashx")?.input, 0.37, "flashx 不能命中 flash")
        XCTAssertEqual(table.price(for: "glm-5-3-flash")?.input, 0.15)
        // DeepSeek 内置表存「空闲价」（标准价的一半，高峰自动 ×2）
        XCTAssertEqual(table.price(for: "deepseek-v4.1-flash")?.input, 0.15, "v4.1-flash 不能被 deepseek-v4 吃掉")
        XCTAssertEqual(table.price(for: "deepseek-v4-pro")?.input, 0.66)
        XCTAssertEqual(table.price(for: "kimi-k3.1-pro-highspeed")?.input, 4)
        XCTAssertEqual(table.price(for: "kimi-k3.1-pro")?.input, 2)
        XCTAssertEqual(table.price(for: "minimax-m2.7-highspeed")?.input, 0.6)
        XCTAssertEqual(table.price(for: "mimo-v2.6-pro-ultraspeed")?.input, 4.35)
        XCTAssertEqual(table.price(for: "claude-sonnet-5-5")?.cacheRead, 0.1)
        XCTAssertEqual(table.price(for: "claude-sonnet-5")?.cacheRead, 0.2)
        XCTAssertEqual(table.price(for: "gemini-4-carbon")?.input, 2)
    }

    /// 家族兜底能覆盖未单列型号
    func testPricingFamilyFallback() {
        let table = PricingTable(prices: PricingTable.builtin)
        XCTAssertNotNil(table.price(for: "glm-6-unknown"))
        XCTAssertNotNil(table.price(for: "doubao-pro-32k"))
        XCTAssertNotNil(table.price(for: "hunyuan-turbo"))
        XCTAssertNotNil(table.price(for: "step-9-unknown"))
    }

    /// DeepSeek 高峰时段价格应为标准价（= 内置空闲价 ×2）
    func testDeepSeekPeakDoublesPrice() {
        let table = PricingTable(prices: PricingTable.builtin)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-11-11 是周三；北京时间 10:00 属高峰
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 11; comps.hour = 10
        let peak = cal.date(from: comps)!
        comps.hour = 3
        let offPeak = cal.date(from: comps)!
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        let a = table.cost(for: counts, model: "deepseek-v4.1-flash", at: peak)
        let b = table.cost(for: counts, model: "deepseek-v4.1-flash", at: offPeak)
        XCTAssertEqual(a, b * 2, accuracy: 1e-9)
        // 高峰 1M 输入 + 1M 输出 = 0.3 + 1.2（标准价）
        XCTAssertEqual(a, 1.5, accuracy: 1e-9)
    }

    /// GLM-4.7-Flash 官方免费
    func testFreeModelPricesToZero() {
        let table = PricingTable(prices: PricingTable.builtin)
        let c = table.cost(for: TokenCounts(input: 10_000_000, output: 1_000_000), model: "glm-4.7-flash")
        XCTAssertEqual(c, 0, accuracy: 0.0001)
    }

    /// 模板版本升级：旧模板被新内置表替换，但保留用户自定义型号
    func testPricingTemplateUpgradeKeepsCustom() throws {
        let dir = URL(fileURLWithPath: tmp)
        let url = dir.appendingPathComponent("pricing.json")
        let old = PricingTable(prices: [
            .init(pattern: "claude-opus-4-7", input: 999, output: 999),   // 旧内置值
            .init(pattern: "my-custom-model", input: 7, output: 8),
        ], templateVersion: 1)
        try JSONEncoder().encode(old).write(to: url)

        // 模拟 load 的升级决策
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(PricingTable.self, from: data)
        XCTAssertEqual(decoded.templateVersion, 1)
        let builtinPatterns = Set(PricingTable.builtin.map { $0.pattern })
        let custom = decoded.prices.filter { !builtinPatterns.contains($0.pattern) }
        XCTAssertEqual(custom.count, 1, "只保留非内置型号")
        XCTAssertEqual(custom.first?.pattern, "my-custom-model")
    }

    /// 环比对象名称：每个范围都要说清比的是哪一段
    func testPreviousPeriodLabels() {
        let cal = Calendar.current
        let now = DayKey.date(from: "2026-11-12")!
        XCTAssertEqual(RangeKind.today.previousPeriodName(now: now, calendar: cal), "昨天")
        XCTAssertEqual(RangeKind.yesterday.previousPeriodName(now: now, calendar: cal), "前天")
        XCTAssertEqual(RangeKind.d7.previousPeriodName(now: now, calendar: cal), "前 7 天")
        XCTAssertEqual(RangeKind.d30.previousPeriodName(now: now, calendar: cal), "前 30 天")
        XCTAssertEqual(RangeKind.thisMonth.previousPeriodName(now: now, calendar: cal), "上月同期")
        XCTAssertNil(RangeKind.all.previousPeriodName(now: now, calendar: cal))
    }

    /// 本月环比应为「上月同期」（1 号到同一天），不是上月最后 N 天
    func testThisMonthPreviousIsSamePeriodLastMonth() {
        let cal = Calendar.current
        let now = DayKey.date(from: "2026-11-12")!
        let r = RangeKind.thisMonth.previousDayRange(now: now, calendar: cal)
        XCTAssertEqual(r?.start, "2026-10-01")
        XCTAssertEqual(r?.end, "2026-10-12", "应到同一天，而非上月最后一天")
    }

    /// 上月环比应为「上上月」的完整自然月
    func testLastMonthPreviousIsFullCalendarMonth() {
        let cal = Calendar.current
        let now = DayKey.date(from: "2026-11-12")!
        let r = RangeKind.lastMonth.previousDayRange(now: now, calendar: cal)
        XCTAssertEqual(r?.start, "2026-09-01")
        XCTAssertEqual(r?.end, "2026-09-30", "应是 9 月整月，而不是按天数倒推的 8/31")
        XCTAssertEqual(RangeKind.lastMonth.previousPeriodName(now: now, calendar: cal), "2026 年 9 月")
    }

    /// 预测：本月范围内给出整月外推
    func testForecast() {
        let b = UsageBucket(day: "2026-11-11", hour: 10, tool: "DSH", model: "deepseek-v4.1-flash",
                            project: "p", counts: TokenCounts(input: 1_000_000), requests: 1)
        let now = DayKey.date(from: "2026-11-11")!
        let s = Aggregator.summarize(buckets: [b], range: .thisMonth, pricing: PricingTable(prices: []),
                                     statuses: [], now: now)
        XCTAssertNotNil(s.forecastCounts)
        XCTAssertGreaterThan(s.forecastCounts?.total ?? 0, s.counts.total, "整月预测应大于当前已用")
    }

    /// 体检：非法日期与未来日期应被报出
    func testDataCheckFlagsBadDays() {
        let now = DayKey.date(from: "2026-11-11")!
        let bad = UsageBucket(day: "not-a-date", tool: "X", model: "m",
                              counts: TokenCounts(input: 1), requests: 1)
        let future = UsageBucket(day: "2030-01-01", tool: "X", model: "m",
                                 counts: TokenCounts(input: 1), requests: 1)
        let issues = DataCheck.run(buckets: [bad, future], statuses: [], now: now)
        XCTAssertTrue(issues.contains { $0.title.contains("非法日期") })
        XCTAssertTrue(issues.contains { $0.title.contains("未来日期") })
    }

    /// 体检：有日志但没用量应被报出（历史上出现过的"扫了但没数"）
    func testDataCheckFlagsEmptySource() {
        let now = DayKey.date(from: "2026-11-11")!
        let st = SourceStatus(id: "x", name: "Codex", enabled: true, files: 100, note: nil)
        let issues = DataCheck.run(buckets: [], statuses: [st], now: now)
        XCTAssertTrue(issues.contains { $0.title.contains("没有用量") })
    }

    func testDshParsing() {
        let sel = #"{"type":"model/selection","time":1794156000000,"data":{"model":"cjj-jksb/qwenwork/qwen3.8-max"}}"#
        let msg = #"{"type":"assistant/message","time":1794156046001,"data":{"turn":1,"step":1,"usage":{"inputTokens":6,"outputTokens":100,"cacheReadTokens":800,"cacheWriteTokens":200},"stream":[{"type":"chunk","chunk":{"type":"finish","replayState":{"response":{"model":"cjj-jksb/qwenwork/qwen3.8-max"}}}}]}}"#
        let p = write("session.v4.jsonl", sel + "\n" + msg + "\n")
        let b = DshSource().parseFile(path: p)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].counts.total, 1106)
        XCTAssertEqual(b[0].model, "qwen3.8-max")
        // 项目归属回归：zstd 与明文两条路径共用 makeBuilder
        let b2 = DshSource().parseFile(path: "/Users/x/.dsh/sessions/--Users-kzhw-Documents-deepseek-harness-token~7EDF~8BA1~63D2~4EF6--/session-abc/session.v4.jsonl")
        XCTAssertEqual(b2.count, 0, "不存在的文件应返回空")
        _ = b2
    }

    func testDshProjectAttribution() {
        let msg = #"{"type":"assistant/message","time":1794156046001,"data":{"turn":1,"step":1,"usage":{"inputTokens":6,"outputTokens":100,"cacheReadTokens":0,"cacheWriteTokens":0}}}"#
        let p = write("session.v4.jsonl", msg + "\n")
        // 通过临时目录结构模拟 sessions/<ws>/session-x/file
        let ws = tmp + "/--Users-kzhw-Documents-deepseek-harness-token~7EDF~8BA1~63D2~4EF6--/session-abc"
        try! FileManager.default.createDirectory(atPath: ws, withIntermediateDirectories: true)
        let real = ws + "/session.v4.jsonl"
        try! msg.write(toFile: real, atomically: true, encoding: .utf8)
        let b = DshSource().parseFile(path: real)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].project, "token统计插件")
    }

    // MARK: - 聚合与口径

    func testBucketBuilderMerge() {
        let b = BucketBuilder(tool: "T")
        b.add(day: "2026-11-09", model: "m", counts: TokenCounts(input: 1))
        b.add(day: "2026-11-09", model: "m", counts: TokenCounts(input: 2))
        b.add(day: "2026-11-09", hour: 5, model: "m", counts: TokenCounts(input: 1))
        XCTAssertEqual(b.buckets.count, 2, "小时不同应分桶")
        XCTAssertEqual(b.buckets.first { $0.hour == 0 }?.counts.input, 3)
        XCTAssertEqual(b.buckets.first { $0.hour == 0 }?.requests, 2)
    }

    func testRangeBounds() {
        let now = Date()
        XCTAssertEqual(RangeKind.yesterday.startDayKey(now: now), RangeKind.yesterday.endDayKey(now: now))
        let sk = RangeKind.lastMonth.startDayKey(now: now)!
        let ek = RangeKind.lastMonth.endDayKey(now: now)!
        XCTAssertLessThan(sk, ek)
        XCTAssertNil(RangeKind.all.startDayKey(now: now))
        XCTAssertNil(RangeKind.all.endDayKey(now: now))
        XCTAssertNotNil(RangeKind.thisMonth.startDayKey(now: now))
    }

    func testSummarizeRangeFilter() {
        let buckets = [
            UsageBucket(day: "2020-01-01", hour: 0, tool: "T", model: "m", project: "-", counts: TokenCounts(input: 10), requests: 1),
            UsageBucket(day: DayKey.key(for: Date()), hour: 0, tool: "T", model: "m", project: "-", counts: TokenCounts(input: 5), requests: 1),
        ]
        let s = Aggregator.summarize(buckets: buckets, range: .today, pricing: PricingTable(prices: []), statuses: [])
        XCTAssertEqual(s.counts.input, 5, "today 应过滤掉旧桶")
        XCTAssertEqual(s.trendDays.count, 30)
        XCTAssertEqual(s.hours.count, 24)
    }

    // MARK: - 价格与格式

    func testPricingMatchCaseInsensitive() {
        let t = PricingTable(prices: PricingTable.builtin)
        let p = t.price(for: "CJJ-JKSB/qwenwork/QWEN3.8-MAX")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.input ?? 0, 1.714, accuracy: 0.001)
        XCTAssertNil(t.price(for: "zzz-totally-unknown-model-xyz"))
    }

    func testFmt() {
        XCTAssertEqual(Fmt.tokens(228_000_000), "2.28亿")
        XCTAssertEqual(Fmt.tokens(20_561_000), "2056.1万")
        XCTAssertEqual(Fmt.tokens(999), "999")
        XCTAssertEqual(Fmt.compactTokens(850_000), "850.0K")
        XCTAssertEqual(Fmt.cost(45.12), "$45.12")
    }

    func testDeepSeekPeakPricing() {
        let t = PricingTable(prices: [ModelPrice(pattern: "deepseek-flash", input: 1, output: 4, cacheRead: 0.1, cacheWrite: 1.25)])
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-11-10 是周二：10:00 高峰、20:00 空闲、周六 10:00 空闲
        let peak = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10))!
        let off = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 20))!
        let sat = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10))!
        let counts = TokenCounts(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let offCost = t.cost(for: counts, model: "deepseek-flash", at: off)
        XCTAssertEqual(offCost, 1.0, accuracy: 1e-9)
        XCTAssertEqual(t.cost(for: counts, model: "deepseek-flash", at: peak), 2.0, accuracy: 1e-9, "工作日高峰应 ×2")
        XCTAssertEqual(t.cost(for: counts, model: "deepseek-flash", at: sat), 1.0, accuracy: 1e-9, "周末不算高峰")
        XCTAssertTrue(PricingTable.isDeepSeekPeak(peak))
        XCTAssertFalse(PricingTable.isDeepSeekPeak(off))
    }

    func testProjectNameDecode() {
        XCTAssertEqual(ProjectName.decodeDsh("--Users-kzhw-Documents-deepseek-harness-token~7EDF~8BA1~63D2~4EF6--"), "token统计插件")
        XCTAssertEqual(ProjectName.decodeClaude("-Users-kzhw-Documents-obsidian"), "obsidian")
        XCTAssertEqual(ProjectName.decodeClaude("645564414bdd.jsonl"), "-", "Windows 扁平布局应归未归属")
        XCTAssertEqual(ProjectName.basename("/a/b/crepo"), "crepo")
        XCTAssertEqual(ProjectName.basename("C:\\Users\\a\\Documents\\Codex\\2026-11-01\\sao-mi"), "sao-mi")
    }
}
