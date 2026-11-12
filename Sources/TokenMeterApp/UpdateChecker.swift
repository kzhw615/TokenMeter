#if os(macOS)
import Foundation
import AppKit
import CryptoKit
import TokenMeterCore

enum UpdateError: Error {
    case badDownload, digestMismatch, unzipFailed
    var message: String {
        switch self {
        case .badDownload: return "下载失败或文件不完整"
        case .digestMismatch: return "sha256 校验不一致，已中止（防篡改）"
        case .unzipFailed: return "解压失败"
        }
    }
}

/// 版本比对与仓库信息（无状态，独立于 MainActor）
enum UpdateKit {
    static let repo = UpdateInfo.repo

    static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        UpdateInfo.isNewer(a, than: b)
    }
}

/// 应用内更新检查：对比 GitHub Releases 最新版本号。
/// 仅匿名 GET 一次 Releases API（启动时 + 每 20 小时），不上传任何数据；
/// 发现新版本只在面板提示并跳转 Release 页，不自动替换二进制。
extension AppModel {
    func checkForUpdates(force: Bool = false) {
        guard !UserDefaults.standard.bool(forKey: "disableUpdateCheck") else {
            updateNotice = "已在设置中关闭检查更新"
            scheduleNoticeClear()
            return
        }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        if !force, now - last < 20 * 3600 { return }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        updateChecking = true
        updateNotice = nil
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor [weak self] in self?.updateChecking = false } }
            defer { Task { @MainActor [weak self] in self?.scheduleNoticeClear() } }

            let current = UpdateKit.currentVersion()

            /// 主通道：GitHub Releases API
            func viaAPI() async -> (tag: String, html: URL?, asset: URL?, digest: String?)? {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateKit.repo)/releases/latest")!)
                req.setValue("TokenMeterApp", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 10
                let data: Data
                let resp: URLResponse
                do {
                    (data, resp) = try await URLSession.shared.data(for: req)
                } catch {
                    await MainActor.run { self.lastCheckError = Self.friendly(error) }
                    return nil
                }
                guard let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
                guard code == 200,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    await MainActor.run { self.lastCheckError = "接口返回 HTTP \(code)" }
                    return nil
                }
                let html = (json["html_url"] as? String).flatMap(URL.init(string:))
                let asset = (json["assets"] as? [[String: Any]])?
                    .first { ($0["name"] as? String) == "TokenMeter.app.zip" }
                return (tag,
                        html,
                        (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                        asset?["digest"] as? String)
            }

            /// 兜底通道：直接请求 releases/latest，跟随重定向拿到 tag。
            /// 用于 api.github.com 被限流（403）或被公司网络拦截的情况。
            func viaRedirect() async -> (tag: String, html: URL?)? {
                var req = URLRequest(url: URL(string: "https://github.com/\(UpdateKit.repo)/releases/latest")!)
                req.setValue("TokenMeterApp", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 10
                guard let (_, resp) = try? await URLSession.shared.data(for: req),
                      let finalURL = resp.url else { return nil }
                let comps = finalURL.pathComponents
                guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else { return nil }
                return (comps[idx + 1], finalURL)
            }

            var result = await viaAPI()
            if result == nil { result = await viaRedirect().map { ($0.tag, $0.html, nil, nil) } }

            guard let got = result else {
                await MainActor.run {
                    self.updateNotice = "检查失败：\(self.lastCheckError ?? "无法连接 GitHub")"
                }
                return
            }
            let latest = got.tag.hasPrefix("v") ? String(got.tag.dropFirst(1)) : got.tag
            guard UpdateKit.isNewer(latest, than: current) else {
                await MainActor.run {
                    self.updateNotice = "已是最新版本（v\(current)）"
                }
                return
            }
            await MainActor.run {
                self.latestVersion = latest
                self.releaseURL = got.html ?? URL(string: "https://github.com/\(UpdateKit.repo)/releases/latest")
                self.latestAssetURL = got.asset
                self.latestDigest = got.digest
                self.updateNotice = got.asset == nil
                    ? "发现新版本 v\(latest)（可手动下载）"
                    : "发现新版本 v\(latest)"
            }
        }
    }

    /// 把网络错误翻译成人话
    static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "网络未连接"
        case NSURLErrorTimedOut: return "连接超时"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "无法解析 GitHub 域名（可能被网络拦截）"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "HTTPS 连接被拦截（可能有代理或证书问题）"
        default: return ns.localizedDescription
        }
    }

    /// 提示文字自动消失，避免长期占位
    func scheduleNoticeClear() {
        let token = updateNotice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if self?.updateNotice == token { self?.updateNotice = nil }
        }
    }

    /// 每日定检：10:00 及之后的第一个整点 tick 触发（每天仅一次）；
    /// 若当天尚未检查过且启动时已过 10 点，启动即补检
    func maybeDailyUpdateCheck() {
        let now = Date()
        guard Calendar.current.component(.hour, from: now) >= 10 else { return }
        let day = DayKey.key(for: now)
        guard UserDefaults.standard.string(forKey: "lastDailyUpdateCheckDay") != day else { return }
        UserDefaults.standard.set(day, forKey: "lastDailyUpdateCheckDay")
        checkForUpdates(force: true)
    }

    func dismissUpdate() {
        guard let v = latestVersion else { return }
        UserDefaults.standard.set(v, forKey: "dismissedUpdateVersion")
        latestVersion = nil
    }

    var updateVisible: Bool {
        guard let v = latestVersion else { return false }
        return UserDefaults.standard.string(forKey: "dismissedUpdateVersion") != v
    }

    /// 是否支持一键更新（Release 附件含 app zip 与 sha256 digest）
    var canAutoUpdate: Bool { latestAssetURL != nil && latestDigest != nil }

    /// 一键更新：下载 → sha256 校验 → 解压 → 替换 bundle → 拉起新实例退出旧实例；失败回滚
    func startUpdate() {
        guard !updatePhase.busy else { return }
        guard let assetURL = latestAssetURL, let digest = latestDigest else { return }
        updatePhase = .downloading
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let (data, resp) = try await URLSession.shared.data(from: assetURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 100_000 else {
                    throw UpdateError.badDownload
                }
                await MainActor.run { self.updatePhase = .verifying }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let expected = digest.lowercased().replacingOccurrences(of: "sha256:", with: "")
                guard hash == expected else { throw UpdateError.digestMismatch }
                await MainActor.run { self.updatePhase = .installing }
                let fm = FileManager.default
                let tmp = fm.temporaryDirectory
                let zipURL = tmp.appendingPathComponent("TokenMeter-update-\(UUID().uuidString).zip")
                try data.write(to: zipURL)
                let unzipDir = tmp.appendingPathComponent("TokenMeter-update-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", zipURL.path, unzipDir.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else { throw UpdateError.unzipFailed }
                let newApp = unzipDir.appendingPathComponent("TokenMeter.app")
                guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.unzipFailed }
                let current = URL(fileURLWithPath: Bundle.main.bundlePath)
                let backup = tmp.appendingPathComponent("TokenMeter-backup-\(Int(Date().timeIntervalSince1970)).app")
                try fm.moveItem(at: current, to: backup)
                do {
                    try fm.moveItem(at: newApp, to: current)
                } catch {
                    try? fm.moveItem(at: backup, to: current)
                    throw error
                }
                try? fm.removeItem(at: zipURL)
                try? fm.removeItem(at: unzipDir)
                await MainActor.run { self.updatePhase = .restarting }
                // 必须以「新实例」方式启动并带上标记参数，否则：
                // ① LaunchServices 可能只是激活旧实例；② 新实例的单实例保护会因旧实例仍在运行而自杀
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.createsNewApplicationInstance = true
                cfg.arguments = ["--post-update"]
                NSWorkspace.shared.openApplication(at: current, configuration: cfg) { _, _ in }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run { NSApplication.shared.terminate(nil) }
            } catch {
                let msg = (error as? UpdateError)?.message ?? error.localizedDescription
                await MainActor.run { self.updatePhase = .failed(msg) }
            }
        }
    }

    /// 启动时清理上次更新留下的备份
    static func cleanupOldBackups() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            if let items = try? fm.contentsOfDirectory(atPath: tmp.path) {
                for name in items where name.hasPrefix("TokenMeter-backup-") {
                    try? fm.removeItem(at: tmp.appendingPathComponent(name))
                }
            }
        }
    }
}
#endif
