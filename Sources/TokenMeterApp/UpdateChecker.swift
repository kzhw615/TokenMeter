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
    static let repo = "kzhw615/TokenMeter"

    static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// 应用内更新检查：对比 GitHub Releases 最新版本号。
/// 仅匿名 GET 一次 Releases API（启动时 + 每 20 小时），不上传任何数据；
/// 发现新版本只在面板提示并跳转 Release 页，不自动替换二进制。
extension AppModel {
    func checkForUpdates(force: Bool = false) {
        guard !UserDefaults.standard.bool(forKey: "disableUpdateCheck") else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        if !force, now - last < 20 * 3600 { return }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        updateChecking = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor [weak self] in self?.updateChecking = false } }
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateKit.repo)/releases/latest")!)
            req.setValue("TokenMeterApp", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let html = json["html_url"] as? String,
                  let url = URL(string: html) else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst(1)) : tag
            let current = UpdateKit.currentVersion()
            guard UpdateKit.isNewer(latest, than: current) else { return }
            // 取 TokenMeter.app.zip 附件的下载地址与 sha256 digest
            let asset: [String: Any]? = (json["assets"] as? [[String: Any]])?
                .first { ($0["name"] as? String) == "TokenMeter.app.zip" }
            let assetURL: URL? = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
            let digest: String? = asset?["digest"] as? String
            await MainActor.run {
                self.latestVersion = latest
                self.releaseURL = url
                self.latestAssetURL = assetURL
                self.latestDigest = digest
            }
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
                NSWorkspace.shared.open(current)
                try? await Task.sleep(nanoseconds: 800_000_000)
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
