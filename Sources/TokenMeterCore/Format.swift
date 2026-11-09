import Foundation

public enum Fmt {
    /// 中文单位：亿 / 万
    public static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        if abs(v) >= 1e8 { return String(format: "%.2f亿", v / 1e8) }
        if abs(v) >= 1e4 { return String(format: "%.1f万", v / 1e4) }
        return String(Int64(v))
    }

    public static func cost(_ c: Double) -> String {
        if c >= 1000 { return String(format: "$%.0f", c) }
        if c >= 100 { return String(format: "$%.1f", c) }
        return String(format: "$%.2f", c)
    }

    public static func percent(_ p: Double) -> String {
        String(format: "%.1f%%", p * 100)
    }

    public static func compactTokens(_ n: Int64) -> String {
        let v = Double(n)
        if abs(v) >= 1e8 { return String(format: "%.1f亿", v / 1e8) }
        if abs(v) >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if abs(v) >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return String(Int64(v))
    }
}
