import Foundation

/// 版本比较与 Releases 查询（App 与 CLI 共用，便于在任意机器上诊断更新问题）
public enum UpdateInfo {
    public static let repo = "kzhw615/TokenMeter"

    /// 语义化版本比较：0.9.10 > 0.9.9；0.13.1 > 0.13
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public struct Latest {
        public var version: String
        public var pageURL: URL?
        public var assetURL: URL?
        public var digest: String?
        /// 数据来自哪个通道（api / redirect）
        public var channel: String
    }

    public enum CheckError: Error, CustomStringConvertible {
        case network(String)
        case http(Int)
        case parse(String)

        public var description: String {
            switch self {
            case .network(let m): return "网络错误：\(m)"
            case .http(let c): return "接口返回 HTTP \(c)（403 通常是 GitHub 限流）"
            case .parse(let m): return m
            }
        }
    }

    /// 查询最新版本：先走 API，失败再走 releases/latest 重定向
    public static func fetchLatest(timeout: TimeInterval = 10) async throws -> Latest {
        var apiError: CheckError?
        // 诊断用：强制走重定向通道，验证兜底是否可用
        if ProcessInfo.processInfo.environment["TM_FORCE_REDIRECT"] == nil {
            do {
                return try await viaAPI(timeout: timeout)
            } catch let e as CheckError {
                apiError = e
            }
        }
        do {
            return try await viaRedirect(timeout: timeout)
        } catch {
            throw apiError ?? CheckError.network("无法连接 GitHub")
        }
    }

    private static func viaAPI(timeout: TimeInterval) async throws -> Latest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("TokenMeterApp", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw CheckError.network((error as NSError).localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw CheckError.http(code) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw CheckError.parse("返回内容无法解析")
        }
        let asset = (json["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String) == "TokenMeter.app.zip" }
        return Latest(version: tag.hasPrefix("v") ? String(tag.dropFirst(1)) : tag,
                      pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)),
                      assetURL: (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                      digest: asset?["digest"] as? String,
                      channel: "api")
    }

    private static func viaRedirect(timeout: TimeInterval) async throws -> Latest {
        var req = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        req.setValue("TokenMeterApp", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        let resp: URLResponse
        do {
            (_, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw CheckError.network((error as NSError).localizedDescription)
        }
        guard let finalURL = resp.url else { throw CheckError.parse("拿不到重定向地址") }
        let comps = finalURL.pathComponents
        guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else {
            throw CheckError.parse("重定向地址里没有版本号")
        }
        let tag = comps[idx + 1]
        return Latest(version: tag.hasPrefix("v") ? String(tag.dropFirst(1)) : tag,
                      pageURL: finalURL, assetURL: nil, digest: nil, channel: "redirect")
    }
}
