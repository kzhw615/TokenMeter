import Foundation
#if os(macOS)
import SQLite3
#endif
/// generation span 的 span_end.toolOutput 是原始 chat.completion 响应数组，
/// 每个响应带 usage{prompt_tokens, completion_tokens, prompt_tokens_details.cached_tokens}。
public struct WorkBuddySource: UsageSource {
    public var id: String { "workbuddy" }
    public var displayName: String { "WorkBuddy" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func logFiles() -> [String] {
        SourcePaths.files(under: "~/.workbuddy/traces", suffix: ".jsonl")
    }

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = logFiles()
        let builder = BucketBuilder(tool: "WorkBuddy")
        var toParse: [String] = []
        // 并行取指纹（数千个 stat 串行是主要耗时）
        let prints = SourcePaths.parallelFingerprints(files)
        for (i, path) in files.enumerated() {
            if let fp = prints[i], let cached = cache.cachedBuckets(path: path, size: fp.size, mtime: fp.mtime) {
                // 旧版本的缓存里这些 trace 全是「未归属」。新版本会用路径前缀推断项目，
                // 所以全未归属的条目要重算一次；用 marker 记住已重算，避免每轮都重解析。
                let markKey = "__wbproj:\(path)"
                let allUnassigned = !cached.isEmpty && cached.allSatisfy { $0.project == "-" }
                if allUnassigned, cache.threadModels?[markKey] == nil {
                    cache.dropEntry(path: path)
                    var marks = cache.threadModels ?? [:]
                    marks[markKey] = "1"
                    cache.threadModels = marks
                    toParse.append(path)
                    continue
                }
                ScanProgressReporter.current?.bump()
                builder.merge(cached)
            } else {
                toParse.append(path)
            }
        }
        // 分块解析：每块解析完立刻入库并释放，峰值内存只与块大小相关
        BoundedParallel.chunkedMap(toParse, chunkSize: 32, transform: { path in
            let buckets = parseFile(path: path)
            ScanProgressReporter.current?.bump()
            return buckets
        }, handle: { path, buckets in
            cache.store(path: path, buckets: buckets)
            builder.merge(buckets)
        })
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    public func parseFile(path: String) -> [UsageBucket] {
        let projects = Self.projects()
        let builder = BucketBuilder(tool: "WorkBuddy")
        guard let reader = LineReader(path: path) else { return [] }
        var pending: [(date: Date, model: String, counts: TokenCounts)] = []
        var hits: [String: Int] = [:]
        var candidates: [String: Int] = [:]
        reader.forEachLine { line in
            if !projects.isEmpty, line.contains("/Users/") {
                for p in projects where line.contains(p.path) {
                    hits[p.path, default: 0] += 1
                }
            }
            if line.contains("/Users/") {
                for root in Self.pathCandidateRoots(in: line) { candidates[root, default: 0] += 1 }
            }
            guard line.contains("\"generation\""), line.contains("span_end") else { return }
            guard let o = JSONUtil.object(line),
                  JSONUtil.string(o, "type") == "span_end",
                  let span = JSONUtil.dict(o, "span"),
                  JSONUtil.string(span, "type") == "generation",
                  let toolOutput = JSONUtil.string(span, "toolOutput") else { return }
            let date = JSONUtil.date(span, "endedAt") ?? JSONUtil.date(span, "startedAt") ?? Date()
            if let data = toolOutput.data(using: .utf8),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                for el in arr {
                    guard let usage = JSONUtil.dict(el, "usage") else { continue }
                    if let c = Self.counts(from: usage) {
                        pending.append((date, JSONUtil.string(el, "model") ?? "unknown", c))
                    }
                }
            } else {
                // tracePayloadTruncated 截断的 toolOutput：碎片提取 "model" 与 "usage"
                for (model, usage) in Self.fragments(in: toolOutput) {
                    if let c = Self.counts(from: usage) {
                        pending.append((date, model, c))
                    }
                }
            }
        }
        // 出现次数最多的已知工作区路径胜出 → 用 spaces 表的显示名作为项目名
        if let best = hits.max(by: { $0.value < $1.value }), best.value > 0,
           let name = projects.first(where: { $0.path == best.key })?.name {
            builder.project = name
        } else if let best = candidates.max(by: { $0.value < $1.value }), best.value >= 3 {
            // 兜底：trace 里没有已知 workSpace，但从出现的绝对路径能看出工作目录
            // （例：~/Nutstore Files/我的笔记-obsidian/…、~/Documents/WorkBuddy/…）
            builder.project = best.key
        }
        for p in pending {
            builder.add(date: p.date, model: p.model, counts: p.counts)
        }
        return builder.buckets
    }

    /// 从一行文本里提取「看起来像项目根目录」的路径（workSpace 匹配不上时的兜底）
    ///
    /// 规则：
    /// - 跳过工具自身目录（~/.workbuddy、任何隐藏目录）与系统目录（Library/Downloads/…）
    /// - 归一层目录：~/Documents/<x>、~/Nutstore Files/<x>、~/Desktop/<x> 都取 <x>
    /// - 只取第一个路径段的项目名，其余层级不要（否则同一个项目会碎成很多名字）
    static func pathCandidateRoots(in line: String) -> [String] {
        let home = NSHomeDirectory()
        var out: [String] = []
        // 带空格的目录名要单独处理（Nutstore Files），否则按空白切分只能拿到 "Nutstore"
        var scan = Substring(line)
        while let r = scan.range(of: home + "/Nutstore Files/") {
            scan = scan[r.upperBound...]
            let seg = scan.prefix { ch in
                guard let u = ch.unicodeScalars.first else { return false }
                return !CharacterSet(charactersIn: "\"\\'\n\r\t /<>|*?()[],;").contains(u)
            }
            if !seg.isEmpty { out.append(String(seg)) }
            scan = seg.endIndex < scan.endIndex ? scan[seg.endIndex...] : Substring("")
            if scan.isEmpty { break }
        }
        var rest = Substring(line)
        while let r = rest.range(of: home + "/") {
            rest = rest[r.upperBound...]
            let stop = CharacterSet(charactersIn: "\"\\'\n\r\t <>|*?()[],;")
            let tail = rest.prefix { ch in
                guard let u = ch.unicodeScalars.first else { return false }
                return !stop.contains(u) && !CharacterSet.whitespacesAndNewlines.contains(u)
            }
            let comps = tail.split(separator: "/").map(String.init)
            if let root = projectRoot(fromHomeRelative: comps) { out.append(root) }
            rest = tail.endIndex < rest.endIndex ? rest[tail.endIndex...] : Substring("")
            if rest.isEmpty { break }
        }
        return out
    }

    /// 家目录后的路径组件 → 项目名（不是项目时返回 nil）
    static func projectRoot(fromHomeRelative comps: [String]) -> String? {
        guard let first = comps.first, !first.hasPrefix(".") else { return nil }
        // 系统目录：里面的东西不是项目
        let system: Set<String> = ["Library", "Downloads", "Applications", "Movies", "Music",
                                   "Pictures", "Public", "bin", "node_modules"]
        if system.contains(first) { return nil }
        // 归档型目录：取下一级作为项目（Documents/x、Desktop/x、Nutstore Files/x）
        let archiving: Set<String> = ["Documents", "Desktop", "Projects", "Code"]
        if archiving.contains(first) {
            guard comps.count >= 2 else { return nil }
            let second = comps[1]
            // Documents/WorkBuddy/2026-11-09-... 这种：第二级才是项目
            guard !second.hasPrefix(".") else { return nil }
            return second
        }
        // 根目录下直接就是项目：至少要有一段（~/my-project/...）
        guard comps.count >= 2 else { return nil }   // ~/file.txt 这种不算
        return first
    }

    private static func counts(from usage: [String: Any]) -> TokenCounts? {
        let prompt = JSONUtil.int(usage, "prompt_tokens")
        let completion = JSONUtil.int(usage, "completion_tokens")
        var cached: Int64 = 0
        var cacheWrite: Int64 = 0
        if let details = JSONUtil.dict(usage, "prompt_tokens_details") {
            cached = JSONUtil.int(details, "cached_tokens")
            cacheWrite = JSONUtil.int(details, "cache_write_tokens")
        }
        let counts = TokenCounts(
            input: max(0, prompt - cached - cacheWrite),
            output: completion,
            cacheRead: cached,
            cacheWrite: cacheWrite
        )
        return counts.total > 0 ? counts : nil
    }

    private static let projectsLock = NSLock()
    private static var projectsStore: [(path: String, name: String)]?

    static func projects() -> [(path: String, name: String)] {
        projectsLock.withLock {
            if let p = projectsStore { return p }
            let p = loadProjects()
            projectsStore = p
            return p
        }
    }

    /// 从 workbuddy.db 的 spaces / space_folders 读取 工作区路径 → 项目显示名
    private static func loadProjects() -> [(path: String, name: String)] {
        #if os(macOS)
        let dbPath = SourcePaths.expand("~/.workbuddy/workbuddy.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT f.path, s.name FROM spaces s JOIN space_folders f ON f.space_id = s.id
        UNION
        SELECT create_folder_path, name FROM spaces WHERE create_folder_path IS NOT NULL AND create_folder_path != ''
        UNION
        SELECT primary_folder_path, name FROM spaces WHERE primary_folder_path IS NOT NULL AND primary_folder_path != ''
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let n = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  !p.isEmpty, !n.isEmpty else { continue }
            out.append((p, n))
        }
        // 长路径优先，避免父目录抢匹配
        return out.sorted { $0.0.count > $1.0.count }
        #else
        return []
        #endif
    }

    /// 在被截断的 toolOutput 字符串里扫出所有 ("model", usageDict) 片段
    static func fragments(in s: String) -> [(String, [String: Any])] {
        var out: [(String, [String: Any])] = []
        let chars = Array(s)
        var i = 0
        let marker: [Character] = Array("\"usage\":")
        while i < chars.count {
            // 找 "usage":
            guard let hit = findMarker(chars, from: i, marker: marker) else { break }
            var j = hit + marker.count
            while j < chars.count, chars[j] != "{" { j += 1 }
            guard j < chars.count else { break }
            // 平衡花括号提取（处理字符串转义）
            var depth = 0
            var inStr = false
            var esc = false
            var k = j
            while k < chars.count {
                let c = chars[k]
                if inStr {
                    if esc { esc = false }
                    else if c == "\\" { esc = true }
                    else if c == "\"" { inStr = false }
                } else {
                    if c == "\"" { inStr = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                k += 1
            }
            guard k < chars.count else { break }
            let fragment = "{\"u\":" + String(chars[j...k]) + "}"
            if let data = fragment.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let usage = JSONUtil.dict(obj, "u") {
                // 向前找最近的 "model":"..."
                let prefix = String(chars[0..<hit])
                let model = lastModel(before: prefix) ?? "unknown"
                out.append((model, usage))
            }
            i = k + 1
        }
        return out
    }

    private static func findMarker(_ chars: [Character], from start: Int, marker: [Character]) -> Int? {
        var i = start
        while i + marker.count <= chars.count {
            if chars[i] == marker[0] && Array(chars[i..<(i + marker.count)]) == marker { return i }
            i += 1
        }
        return nil
    }

    private static func lastModel(before prefix: String) -> String? {
        guard let r = prefix.range(of: "\"model\":\"", options: .backwards) else { return nil }
        let rest = prefix[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
