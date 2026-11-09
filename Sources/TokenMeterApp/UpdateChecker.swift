import Foundation
import AppKit

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
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
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
            await MainActor.run {
                self.latestVersion = latest
                self.releaseURL = url
            }
        }
    }

    func manualCheck() {
        updateMessage = "检查更新中…"
        checkForUpdates(force: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.updateMessage == "检查更新中…" else { return }
            self.updateMessage = self.latestVersion == nil ? "已是最新版本" : nil
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.updateMessage = nil
        }
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
}
