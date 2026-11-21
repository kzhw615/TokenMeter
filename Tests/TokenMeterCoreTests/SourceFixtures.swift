import XCTest
import SQLite3
@testable import TokenMeterCore

/// 四个没被覆盖的数据源补 fixture 测试：直接构造最小数据库，喂给解析器。
/// 这类解析逻辑最容易因为上游改表结构/字段而**静默出错**（不是崩溃，是数字悄悄变 0），
/// 所以只要有样本就能兜住。
final class SourceFixtures: XCTestCase {
    private var tmp = ""

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "tmfix-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    /// 用 sqlite3 建库并执行若干语句
    private func makeDB(_ name: String, _ statements: [String]) -> String {
        let path = tmp + "/" + name
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "?"
                XCTFail("SQL 失败: \(msg) — \(sql)")
                sqlite3_free(err)
            }
        }
        return path
    }

    // MARK: Hermes（session_model_usage + sessions）

    func testHermesFixture() {
        let db = makeDB("hermes.db", [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, git_repo_root TEXT);",
            "CREATE TABLE session_model_usage (session_id TEXT, model TEXT, input_tokens INT, output_tokens INT, cache_read_tokens INT, cache_write_tokens INT, last_seen REAL);",
            "INSERT INTO sessions VALUES ('s1', '/Users/x/Projects/demo-app', NULL);",
            "INSERT INTO session_model_usage VALUES ('s1','gpt-6.1-sol',1000,200,3000,100,1794156000);",
        ])
        let b = HermesSource().parseForTest(dbPath: db)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].model, "gpt-6.1-sol")
        XCTAssertEqual(b[0].tool, "Hermes")
        XCTAssertEqual(b[0].counts.input, 1000)
        XCTAssertEqual(b[0].counts.output, 200)
        XCTAssertEqual(b[0].counts.cacheRead, 3000)
        XCTAssertEqual(b[0].counts.cacheWrite, 100)
        XCTAssertEqual(b[0].project, "demo-app", "项目应取 cwd 的最后一段")
    }

    // MARK: ZCode（model_usage + session），reasoning 计入 output

    func testZCodeFixture() {
        let db = makeDB("zcode.db", [
            "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, path TEXT);",
            "CREATE TABLE model_usage (session_id TEXT, model_id TEXT, started_at INT, input_tokens INT, output_tokens INT, reasoning_tokens INT, cache_creation_input_tokens INT, cache_read_input_tokens INT);",
            "INSERT INTO session VALUES ('s1', '/Users/x/work/shop', NULL);",
            "INSERT INTO model_usage VALUES ('s1','qwen3.8-max',1794156000000,500,60,40,10,900);",
        ])
        let b = ZCodeSource().parseForTest(dbPath: db)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].model, "qwen3.8-max")
        XCTAssertEqual(b[0].tool, "ZCode")
        // reasoning 与 output 合并
        XCTAssertEqual(b[0].counts.output, 100)
        XCTAssertEqual(b[0].counts.cacheRead, 900)
        XCTAssertEqual(b[0].counts.cacheWrite, 10)
        XCTAssertEqual(b[0].project, "shop")
    }

    // MARK: OpenCode（用量藏在 data JSON 里）

    func testOpenCodeFixture() {
        let json = #"{"model":{"id":"deepseek-v4.1-flash"},"tokens":{"input":800,"output":120,"reasoning":30,"cache":{"read":2000,"write":0}},"time":{"created":1794156000000}}"#
        // 新 schema：session_message.data 是 JSON，session_v2.directory 给项目归属
        let db = makeDB("opencode.db", [
            "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT);",
            "CREATE TABLE session_message (session_id TEXT, type TEXT, data TEXT);",
            "INSERT INTO session_v2 VALUES ('s1', '/Users/x/projects/notes-bot');",
            "INSERT INTO session_message VALUES ('s1','assistant','\(json.replaceQuote)');",
        ])
        let b = OpenCodeSource().parseForTest(dbPath: db)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].model, "deepseek-v4.1-flash")
        XCTAssertEqual(b[0].counts.input, 800)
        XCTAssertEqual(b[0].counts.output, 150, "reasoning 要并入 output")
        XCTAssertEqual(b[0].counts.cacheRead, 2000)
        XCTAssertEqual(b[0].project, "notes-bot")
    }

    /// 空表不应该崩，也不该造出假数据
    func testEmptyDatabasesAreSafe() {
        let db = makeDB("empty.db", [
            "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT);",
            "CREATE TABLE session_message (session_id TEXT, type TEXT, data TEXT);",
        ])
        XCTAssertTrue(OpenCodeSource().parseForTest(dbPath: db).isEmpty)
        XCTAssertTrue(ZCodeSource().parseForTest(dbPath: db).isEmpty)
        XCTAssertTrue(HermesSource().parseForTest(dbPath: db).isEmpty)
    }
}

private extension String {
    var replaceQuote: String { replacingOccurrences(of: "'", with: "''") }
}
