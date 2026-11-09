import Foundation

/// 逐行流式读取大文件（避免一次性载入 6.9GB 的 codex 日志）
public final class LineReader {
    private let handle: FileHandle
    private let delim: UInt8 = 0x0A
    private var buffer = Data()
    private let chunkSize = 1 << 20

    public init?(path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = h
    }

    public func forEachLine(_ body: (String) -> Void) {
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            flush(complete: false, body)
        }
        flush(complete: true, body)
        try? handle.close()
    }

    private func flush(complete: Bool, _ body: (String) -> Void) {
        var start = buffer.startIndex
        while let idx = buffer[start...].firstIndex(of: delim) {
            let line = buffer[start..<idx]
            if !line.isEmpty { body(String(decoding: line, as: UTF8.self)) }
            start = buffer.index(after: idx)
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
        #elseif os(Linux)
        let candidates = ["/usr/bin/zstd", "/usr/local/bin/zstd"]
        #else
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        #endif
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
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
