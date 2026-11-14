import Foundation

/// 逐行流式读取大文件（避免一次性载入 6.9GB 的 codex 日志）
public final class LineReader {
    private let handle: FileHandle
    private let delim: UInt8 = 0x0A
    private var buffer = Data()
    private let chunkSize = 1 << 20
    /// 单行上限。日志里可能夹带 base64 图片/超大工具输出（实测有数百 MB 的单行），
    /// 逐行解析这类记录既无用又会让内存冲到 GB 级，直接跳过。
    public var maxLineBytes = 4 << 20

    public init?(path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = h
    }

    /// 从指定偏移开始逐行读（append-only 日志的增量解析）
    public init?(path: String, offset: UInt64) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        do { try h.seek(toOffset: offset) } catch { return nil }
        self.handle = h
    }

    /// 从 offset 读到 endOffset（不含），用于增量解析时排除末尾未写完的半行
    public init?(path: String, offset: UInt64, endOffset: UInt64) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        do { try h.seek(toOffset: offset) } catch { return nil }
        self.handle = h
        self.remaining = endOffset > offset ? Int64(endOffset - offset) : 0
    }

    private var remaining: Int64 = -1

    /// 文件末尾「最后一个完整行之后」的偏移：只解析到这里，剩余半行等下次写完再读
    public static func lastCompleteLineBoundary(path: String) -> Int64? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let endU = try? fh.seekToEnd() else { return nil }
        let size = Int64(endU)
        guard size > 0 else { return 0 }
        let tailLen = min(size, Int64(1 << 20))
        guard (try? fh.seek(toOffset: UInt64(size - tailLen))) != nil,
              let tail = try? fh.read(upToCount: Int(tailLen)),
              !tail.isEmpty else { return nil }
        if let idx = tail.lastIndex(of: 0x0A) {
            return size - tailLen + Int64(tail.distance(from: tail.startIndex, to: idx)) + 1
        }
        // 末尾 1MB 内没有换行：这一行还没写完，暂不消费
        return size - tailLen > 0 ? size - tailLen : 0
    }

    public func forEachLine(_ body: (String) -> Void) {
        while true {
            // 关键：read(upToCount:) 返回的 Data 是自动释放对象，必须和解析一起放进
            // autoreleasepool，否则整份日志的块会在池里累积（实测 1.4GB 文件 → 1.5GB 内存，
            // 修正后仅 8MB）。
            let finished: Bool = autoreleasepool {
                let want = remaining >= 0 ? Int(min(Int64(chunkSize), remaining)) : chunkSize
                guard want > 0 else { return true }
                guard let chunk = (try? handle.read(upToCount: want)) ?? nil, !chunk.isEmpty else {
                    return true
                }
                if remaining > 0 { remaining -= Int64(chunk.count) }
                buffer.append(chunk)
                flush(complete: false, body)
                return false
            }
            if finished { break }
        }
        autoreleasepool {
            flush(complete: true, body)
        }
        try? handle.close()
    }

    private func flush(complete: Bool, _ body: (String) -> Void) {
        var start = buffer.startIndex
        while let idx = buffer[start...].firstIndex(of: delim) {
            let line = buffer[start..<idx]
            if !line.isEmpty, line.count <= maxLineBytes {
                body(String(decoding: line, as: UTF8.self))
            }
            start = buffer.index(after: idx)
        }
        if !complete, start == buffer.startIndex, buffer.count > maxLineBytes {
            // 尚未遇到换行且已超上限：丢弃，等待下一个换行
            buffer.removeAll(keepingCapacity: false)
            return
        }
        if complete {
            if start < buffer.endIndex {
                let line = buffer[start...]
                if !line.isEmpty { body(String(decoding: line, as: UTF8.self)) }
            }
            buffer = Data()
        } else {
            buffer = Data(buffer[start...])
        }
    }
}

public enum Zstd {
    public static func zstdPath() -> String? {
        #if os(Windows)
        // Windows 依赖 PATH 解析 zstd.exe（CreateProcess 会搜索 PATH）
        return "zstd.exe"
        #else
        #if os(Linux)
        let candidates = ["/usr/bin/zstd", "/usr/local/bin/zstd"]
        #else
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        #endif
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
        #endif
    }

    static let frameMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// zstd 流式写入会把每次 flush 存成一个独立帧（同一文件内多帧拼接）。
    /// 这里返回「最后一个帧的起始偏移」——从它之前的内容都已完整落盘，可安全增量解析。
    public static func lastFrameStart(path: String) -> Int64? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        guard size > 0 else { return nil }
        // 只需找到「最后一个帧起点」，扫尾部 4MB 足够（活跃日志可达数 MB，全读没有必要）
        let window: UInt64 = 4 * 1024 * 1024
        let start: UInt64 = size > window ? size - window : 0
        do { try fh.seek(toOffset: start) } catch { return nil }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        var last: Int64 = 0
        var i = 0
        let n = bytes.count
        while i + 4 <= n {
            if bytes[i] == 0x28, bytes[i+1] == 0xB5, bytes[i+2] == 0x2F, bytes[i+3] == 0xFD {
                last = Int64(start) + Int64(i)
                i += 4
            } else {
                i += 1
            }
        }
        return last
    }

    /// 解压文件尾部若干「完整帧」（跳过可能正在写入的最后一帧）
    public static func decompressTailFrames(path: String, window: Int64 = 512 * 1024) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let start: UInt64 = size > UInt64(window) ? size - UInt64(window) : 0
        do { try fh.seek(toOffset: start) } catch { return nil }
        guard let chunk = try? fh.readToEnd(), !chunk.isEmpty else { return nil }
        let bytes = [UInt8](chunk)
        var positions: [Int] = []
        var i = 0
        let n = bytes.count
        while i + 4 <= n {
            if bytes[i] == 0x28, bytes[i+1] == 0xB5, bytes[i+2] == 0x2F, bytes[i+3] == 0xFD {
                positions.append(i); i += 4
            } else { i += 1 }
        }
        guard positions.count >= 2 else { return nil }
        let begin = Int64(start) + Int64(positions[0])
        let boundary = Int64(start) + Int64(positions[positions.count - 1])
        return decompressRange(path: path, from: begin, to: boundary)
    }

    /// 解压 [offset, boundary) 区间（即新追加且已完整的帧）
    public static func decompressRange(path: String, from offset: Int64, to boundary: Int64) -> Data? {
        guard boundary > offset, zstdPath() != nil else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let len = Int(boundary - offset)
        guard len > 0 else { return nil }
        do { try fh.seek(toOffset: UInt64(offset)) } catch { return nil }
        // 只读需要的字节数（readToEnd 会把整个尾部读进内存）
        guard let chunk = try? fh.read(upToCount: len), chunk.count == len else { return nil }
        let tail = chunk
        // 写临时文件交给 zstd 解压（进程方式最稳，支持多帧拼接）
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-zstd-\(UUID().uuidString).zst")
        do {
            try tail.write(to: tmp)
        } catch { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return decompress(path: tmp.path)
    }

    /// 解压到临时文件后按行流式读取：内存只与单行长度相关。
    /// 用于大 .zst（实测有 360MB 压缩、解压后 GB 级的会话日志）。
    @discardableResult
    public static func forEachDecompressedLine(path: String, handler: (String) -> Void) -> Bool {
        guard let zstd = zstdPath() else { return false }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let sink = FileHandle(forWritingAtPath: tmp.path) else { return false }
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: tmp)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zstd)
        p.arguments = ["-dc", path]
        p.standardOutput = sink
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        try? sink.close()
        guard let reader = LineReader(path: tmp.path) else { return false }
        reader.forEachLine(handler)
        return true
    }

    public static func decompress(path: String) -> Data? {
        guard let zstd = zstdPath() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zstd)
        p.arguments = ["-dc", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}

extension LineReader {
    /// 把整块 Data 按行切开（用于已解压的小文件）
    public static func split(_ data: Data) -> [String] {
        var out: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            var start = 0
            for i in 0..<buf.count {
                if buf[i] == 0x0A {
                    if i > start { out.append(String(decoding: buf[start..<i], as: UTF8.self)) }
                    start = i + 1
                }
            }
            if start < buf.count { out.append(String(decoding: buf[start..<buf.count], as: UTF8.self)) }
        }
        return out
    }
}

public enum JSONUtil {

    public static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func dict(_ o: [String: Any], _ key: String) -> [String: Any]? {
        o[key] as? [String: Any]
    }

    public static func int(_ o: [String: Any], _ key: String) -> Int64 {
        switch o[key] {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }

    public static func intOrNil(_ o: [String: Any], _ key: String) -> Int64? {
        switch o[key] {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    public static func string(_ o: [String: Any], _ key: String) -> String? {
        o[key] as? String
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    public static func date(_ o: [String: Any], _ key: String) -> Date? {
        guard let s = o[key] as? String else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    public static func dateFromMillis(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}
