import Foundation

/// DSH harness：~/.dsh/sessions/*/*/session.v4.jsonl.zstd（zstd 压缩）
/// chunk.usage{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens} + 紧随的 finish chunk 带模型名
public struct DshSource: UsageSource {
    public var id: String { "dsh" }
    public var displayName: String { "DSH" }
    public var enabledByDefault: Bool { true }

    public init() {}

    public func logFiles() -> [String] {
        var files = SourcePaths.files(under: "~/.dsh/sessions", suffix: ".zstd")
        files += SourcePaths.files(under: "~/.dsh/sessions", suffix: ".jsonl")
        return files
    }

    public func scan(cache: inout ScanCache) -> ScanResult {
        let files = logFiles()
        if Zstd.zstdPath() == nil && files.contains(where: { $0.hasSuffix(".zstd") }) {
            // 有压缩文件但找不到 zstd：只解析未压缩的
            let note = "未找到 zstd 可执行文件，压缩会话日志已跳过"
            let plain = files.filter { !$0.hasSuffix(".zstd") }
            return ScanResult(buckets: scanPlain(plain, cache: &cache), files: files.count, note: note)
        }
        let builder = BucketBuilder(tool: "DSH")
        for path in files {
            // 压缩日志：按 zstd 帧边界增量解析，避免每次解压整个文件（活跃会话可达数 MB）
            // 活跃文件一直在增长：不能要求指纹完全一致，只要求「比上次更大」（append-only）
            if path.hasSuffix(".zstd"),
               let entry = cache.cachedEntry(path: path),
               entry.offset > 0,
               let cur = ScanCache.fingerprint(path: path),
               cur.size >= entry.size,
               let boundary = Zstd.lastFrameStart(path: path),
               boundary > entry.offset {
                let dbg = ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil
                if dbg { FileHandle.standardError.write(Data("    [dsh] incremental offset=\(entry.offset) boundary=\(boundary) gap=\(boundary-entry.offset)\n".utf8)) }
                if let tail = Zstd.decompressRange(path: path, from: entry.offset, to: boundary) {
                    let parsed = parseWithModel(data: tail, path: path, initialModel: entry.lastModel)
                    let merged = mergeBuckets(entry.buckets, parsed.buckets)
                    cache.update(path: path, buckets: merged, offset: boundary, lastModel: parsed.model)
                    builder.merge(merged)
                    ScanProgressReporter.current?.bump()
                    continue
                }
            }
            if let cached = cache.cachedBuckets(path: path) {
                ScanProgressReporter.current?.bump()
                builder.merge(cached)
                continue
            }
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                FileHandle.standardError.write(Data("    [dsh] FULL \(path.split(separator: "/").last ?? "")\n".utf8))
            }
            let local: [UsageBucket]
            var model: String?
            if path.hasSuffix(".zstd") {
                guard let data = Zstd.decompress(path: path) else { continue }
                let parsed = parseWithModel(data: data, path: path, initialModel: nil)
                local = parsed.buckets
                model = parsed.model
            } else {
                local = parseFile(path: path)
            }
            // 记录帧边界，供下次增量解析
            let offset = path.hasSuffix(".zstd") ? (Zstd.lastFrameStart(path: path) ?? 0) : 0
            cache.store(path: path, buckets: local, offset: offset, lastModel: model)
            builder.merge(local)
            ScanProgressReporter.current?.bump()
        }
        return ScanResult(buckets: builder.buckets, files: files.count)
    }

    private func scanPlain(_ files: [String], cache: inout ScanCache) -> [UsageBucket] {
        let builder = BucketBuilder(tool: "DSH")
        for path in files {
            if let cached = cache.cachedBuckets(path: path) {
                ScanProgressReporter.current?.bump()
                builder.merge(cached); continue
            }
            let local = parseFile(path: path)
            ScanProgressReporter.current?.bump()
            cache.store(path: path, buckets: local)
            builder.merge(local)
        }
        return builder.buckets
    }

    /// 合并两组桶（增量解析：旧桶 + 新增桶）
    private func mergeBuckets(_ old: [UsageBucket], _ new: [UsageBucket]) -> [UsageBucket] {
        guard !old.isEmpty else { return new }
        guard !new.isEmpty else { return old }
        let builder = BucketBuilder(tool: "DSH")
        builder.merge(old)
        builder.merge(new)
        return builder.buckets
    }

    private func makeBuilder(path: String) -> BucketBuilder {
        let builder = BucketBuilder(tool: "DSH")
        let comps = path.split(separator: "/")
        if comps.count >= 3 {
            builder.project = ProjectName.decodeDsh(String(comps[comps.count - 3]))
        }
        return builder
    }

    public func parseFile(path: String) -> [UsageBucket] {
        let builder = makeBuilder(path: path)
        guard let reader = LineReader(path: path) else { return [] }
        let state = ParseState(builder: builder)
        state.currentModel = firstModel(path: path) ?? "unknown"
        reader.forEachLine { state.consume($0) }
        state.flush()
        return builder.buckets
    }

    /// 会话是否仍在推进：解析最新会话日志尾部最后一条生命周期事件。
    /// 长工具执行期间日志可能几分钟不 flush，mtime 会误判为「已结束」，所以要看事件本身。
    /// 返回 true=运行中, false=已结束, nil=无法判断
    /// 会话日志多久没写入就认为任务已停。
    /// 实测同一轮任务内部的静默：p95=52s、p99=126s，最长可到 990s（长工具执行）。
    /// 因此纯靠时间无法兼顾，主判据用「会话锁」；此值仅在没有锁文件可查时生效。
    public static let runningStaleness: TimeInterval = 180

    /// 纯判定：结合「多久没写入」与「会话锁是否被持有」得出任务是否还在跑。
    /// 返回 nil 表示需要继续看日志尾部事件。
    public static func resolveTaskRunning(silent: TimeInterval, lockHeld: Bool?) -> Bool? {
        switch lockHeld {
        case .some(false):
            // 锁已释放 ⇒ DSH 进程退出，任务必然停止（留 30s 容忍落盘延迟）
            return silent > 30 ? false : nil
        case .some(true):
            // 锁仍被持有 ⇒ 进程活着，长工具执行（实测可达 990s）不应误判为停止；
            // 仅极端情况下兜底，避免灯永远亮
            return silent > 1800 ? false : nil
        case .none:
            // 没有锁文件可查，退回保守的时间上限
            return silent > runningStaleness ? false : nil
        }
    }

    /// 会话是否仍被 DSH 进程持有（flock）。
    /// DSH 用 BSD flock 独占 session.lock，进程退出即自动释放 ⇒ 可以精确判断"会话是否还活着"。
    /// 返回 nil 表示无法判断（没有 lock 文件等）。
    public static func isSessionLockHeld(lockPath: String) -> Bool? {
        guard FileManager.default.fileExists(atPath: lockPath) else { return nil }
        let fd = open(lockPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // 共享锁试探：被独占持有则失败（EWOULDBLOCK），否则瞬时获取后立即释放
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// - Parameter baseDir: 会话根目录（默认 ~/.dsh/sessions，测试时可注入临时目录）
    public static func isTaskRunning(now: Date = Date(), baseDir: String? = nil) -> Bool? {
        let fm = FileManager.default
        let base = baseDir ?? SourcePaths.expand("~/.dsh/sessions")
        guard let projects = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        var newest: (path: String, mtime: Date)?
        for project in projects {
            let projDir = base + "/" + project
            guard let sessions = try? fm.contentsOfDirectory(atPath: projDir) else { continue }
            for session in sessions {
                let path = projDir + "/" + session + "/session.v4.jsonl.zstd"
                guard let m = SourcePaths.mtime(path) else { continue }
                if newest == nil || m > newest!.mtime { newest = (path, m) }
            }
        }
        guard let target = newest else { return nil }
        let silent = now.timeIntervalSince(target.mtime)
        let lockPath = (target.path as NSString).deletingLastPathComponent + "/session.lock"
        let lockHeld = isSessionLockHeld(lockPath: lockPath)
        if let decided = resolveTaskRunning(silent: silent, lockHeld: lockHeld) { return decided }
        guard let data = Zstd.decompressTailFrames(path: target.path) else { return nil }
        // 只看尾部事件：从后往前找第一条生命周期标记
        let lines = LineReader.split(data)
        for line in lines.reversed() {
            guard let o = JSONUtil.object(line), let type = JSONUtil.string(o, "type") else { continue }
            switch type {
            case "turn/end":
                return false         // 一轮对话确实结束
            case "tool/call", "step/start", "assistant/message":
                return true          // 工具执行中 / 步骤进行中 / 正在产出
            default:
                continue             // step/end、job/settled、tool/result 等是过程事件，继续往前找
            }
        }
        return nil
    }

    private func parse(data: Data, path: String) -> [UsageBucket] {
        parseWithModel(data: data, path: path, initialModel: nil).buckets
    }

    /// 解析并返回结束时生效的模型（增量解析时作为下文初始模型沿用）
    private func parseWithModel(data: Data, path: String, initialModel: String?) -> (buckets: [UsageBucket], model: String?) {
        let builder = makeBuilder(path: path)
        let state = ParseState(builder: builder)
        if let initialModel { state.currentModel = initialModel }
        let lines = LineReader.split(data)
        if initialModel == nil {
            for line in lines where line.contains("\"model/selection\"") {
                if let m = Self.modelFromSelection(line) { state.currentModel = m }
                break
            }
        }
        for line in lines { state.consume(line) }
        state.flush()
        return (builder.buckets, state.currentModel)
    }

    private func firstModel(path: String) -> String? {
        guard let reader = LineReader(path: path) else { return nil }
        var found: String?
        reader.forEachLine { line in
            if found == nil, line.contains("\"model/selection\"") {
                found = Self.modelFromSelection(line)
            }
        }
        return found
    }

    private static func modelFromSelection(_ line: String) -> String? {
        guard let o = JSONUtil.object(line), let data = JSONUtil.dict(o, "data") else { return nil }
        return JSONUtil.string(data, "model")
    }

    private final class ParseState {
        let builder: BucketBuilder
        var currentModel = "unknown"

        init(builder: BucketBuilder) { self.builder = builder }

        func consume(_ line: String) {
            if line.contains("\"model/selection\"") {
                if let o = JSONUtil.object(line), let data = JSONUtil.dict(o, "data"),
                   let m = JSONUtil.string(data, "model") {
                    currentModel = m
                }
                return
            }
            guard line.contains("\"usage\"") else { return }
            guard let o = JSONUtil.object(line),
                  JSONUtil.string(o, "type") == "assistant/message",
                  let data = JSONUtil.dict(o, "data"),
                  let usage = JSONUtil.dict(data, "usage") else { return }
            let counts = TokenCounts(
                input: JSONUtil.int(usage, "inputTokens"),
                output: JSONUtil.int(usage, "outputTokens"),
                cacheRead: JSONUtil.int(usage, "cacheReadTokens"),
                cacheWrite: JSONUtil.int(usage, "cacheWriteTokens")
            )
            guard counts.total > 0 else { return }
            var model = currentModel
            if let stream = data["stream"] as? [[String: Any]] {
                for ch in stream {
                    // stream 元素形如 {"type":"chunk","chunk":{...}}，也可能直接是内层对象
                    let inner = (JSONUtil.string(ch, "type") == "chunk" && JSONUtil.dict(ch, "chunk") != nil)
                        ? JSONUtil.dict(ch, "chunk")!
                        : ch
                    if JSONUtil.string(inner, "type") == "finish",
                       let replay = JSONUtil.dict(inner, "replayState"),
                       let resp = JSONUtil.dict(replay, "response"),
                       let m = JSONUtil.string(resp, "model") {
                        model = m
                        break
                    }
                }
            }
            let date = JSONUtil.dateFromMillis(JSONUtil.int(o, "time"))
            builder.add(date: date, model: model, counts: counts)
        }

        func flush() {}
    }

    // MARK: 调试

    public func debugParse(path: String) {
        guard let data = Zstd.decompress(path: path) else {
            print("decompress failed: \(path)")
            return
        }
        print("bytes: \(data.count)")
        var lines = 0
        var containsUsage = 0
        var objOK = 0
        var typeChunk = 0
        var chunkTypeUsage = 0
        var firstUsageLine: String?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            var start = 0
            for i in 0..<buf.count {
                if buf[i] == 0x0A {
                    if i > start {
                        let line = String(decoding: buf[start..<i], as: UTF8.self)
                        lines += 1
                        if line.contains("\"usage\"") {
                            containsUsage += 1
                            if let o = JSONUtil.object(line) {
                                objOK += 1
                                if JSONUtil.string(o, "type") == "chunk" {
                                    typeChunk += 1
                                    if let chunk = JSONUtil.dict(o, "chunk"), JSONUtil.string(chunk, "type") == "usage" {
                                        chunkTypeUsage += 1
                                        if firstUsageLine == nil { firstUsageLine = line }
                                    }
                                }
                            }
                        }
                    }
                    start = i + 1
                }
            }
        }
        print("lines=\(lines) containsUsage=\(containsUsage) objOK=\(objOK) typeChunk=\(typeChunk) chunkTypeUsage=\(chunkTypeUsage)")
        if let l = firstUsageLine { print("sample: \(String(l.prefix(300)))") }
        let buckets = parse(data: data, path: path)
        print("buckets: \(buckets.count)")
        for b in buckets.prefix(5) { print("  \(b.day) \(b.model) total=\(b.counts.total)") }
    }
}
