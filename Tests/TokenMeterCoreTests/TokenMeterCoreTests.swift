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
        let tc = #"{"timestamp":"2026-11-09T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":10}}}}"#
        let p = write("r.jsonl", meta + "\n" + tc + "\n")
        let b = CodexSource().parseFile(path: p)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].counts.input, 400, "input 应扣除 cached")
        XCTAssertEqual(b[0].counts.cacheRead, 600)
        XCTAssertEqual(b[0].counts.output, 60, "output 含 reasoning")
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

    func testProjectNameDecode() {
        XCTAssertEqual(ProjectName.decodeDsh("--Users-kzhw-Documents-deepseek-harness-token~7EDF~8BA1~63D2~4EF6--"), "token统计插件")
        XCTAssertEqual(ProjectName.decodeClaude("-Users-kzhw-Documents-obsidian"), "obsidian")
        XCTAssertEqual(ProjectName.basename("/a/b/crepo"), "crepo")
    }
}
