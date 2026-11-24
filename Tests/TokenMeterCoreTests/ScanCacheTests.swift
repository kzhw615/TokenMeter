import XCTest
@testable import TokenMeterCore

/// 扫描缓存是历史事故的重灾区（空桶污染导致某天少算 6 倍、解析器升级后旧结果一直不失效），
/// 这里把关键不变量固定下来。
final class ScanCacheTests: XCTestCase {
    private var tmp = ""

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "tmcache-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func makeFile(_ name: String, _ content: String) -> String {
        let p = tmp + "/" + name
        try! content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private func bucket(_ n: Int64) -> UsageBucket {
        UsageBucket(day: "2026-11-24", hour: 10, tool: "T", model: "m",
                    counts: TokenCounts(input: n), requests: 1)
    }

    /// 指纹一致才命中；文件变了（大小不同）必须当作 miss
    func testFingerprintGate() {
        let p = makeFile("a.jsonl", "12345")
        var cache = ScanCache()
        cache.store(path: p, buckets: [bucket(100)])
        let fp = ScanCache.fingerprint(path: p)!
        XCTAssertEqual(cache.cachedBuckets(path: p, size: fp.size, mtime: fp.mtime)?.first?.counts.input, 100)
        // 大小不同 → miss
        XCTAssertNil(cache.cachedBuckets(path: p, size: fp.size + 1, mtime: fp.mtime))
        // mtime 不同 → miss
        XCTAssertNil(cache.cachedBuckets(path: p, size: fp.size, mtime: fp.mtime - 5))
    }

    /// 空桶也要能落缓存（表示「这个文件确实没有用量」），否则每次都要重解析
    func testEmptyBucketsAreCached() {
        let p = makeFile("empty.jsonl", "{}")
        var cache = ScanCache()
        cache.store(path: p, buckets: [])
        let fp = ScanCache.fingerprint(path: p)!
        XCTAssertEqual(cache.cachedBuckets(path: p, size: fp.size, mtime: fp.mtime)?.count, 0)
    }

    /// dropEntry 之后必须 miss（解析器升级靠它强制重算）
    func testDropEntryForcesReparse() {
        let p = makeFile("b.jsonl", "abc")
        var cache = ScanCache()
        cache.store(path: p, buckets: [bucket(1)])
        XCTAssertNotNil(cache.cachedBuckets(path: p))
        cache.dropEntry(path: p)
        XCTAssertNil(cache.cachedBuckets(path: p))
    }

    /// threadModels 里的标记要能随缓存往返（Qoder/WorkBuddy 的「已探测」标记靠它）
    func testMarkersRoundTrip() throws {
        let p = makeFile("c.jsonl", "xyz")
        var cache = ScanCache()
        cache.store(path: p, buckets: [bucket(7)])
        var models = cache.threadModels ?? [:]
        models["__probe:demo"] = "1"
        cache.threadModels = models

        let data = try JSONEncoder().encode(cache)
        let restored = try JSONDecoder().decode(ScanCache.self, from: data)
        XCTAssertEqual(restored.threadModels?["__probe:demo"], "1")
        XCTAssertEqual(restored.cachedBuckets(path: p)?.first?.counts.input, 7)
    }

    /// 编码再解码，内容要一致（App 与 CLI 共用同一个缓存文件）
    func testSaveLoadRoundTrip() throws {
        let p = makeFile("d.jsonl", "roundtrip")
        var cache = ScanCache()
        cache.store(path: p, buckets: [bucket(42)])
        let data = try JSONEncoder().encode(cache)
        let loaded = try JSONDecoder().decode(ScanCache.self, from: data)
        XCTAssertEqual(loaded.cachedBuckets(path: p)?.first?.counts.input, 42)
        XCTAssertEqual(loaded.version, cache.version)
    }
}
