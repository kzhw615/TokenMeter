#if os(macOS)
import SwiftUI
import Darwin
import AppKit
import ServiceManagement
import Combine
@preconcurrency import TokenMeterCore

/// 应用入口：NSStatusItem 承载菜单栏图标（左键面板 / 右键菜单）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        // 记录退出时间：下次启动时用它把「关机前就完成」的任务直接判为已读
        model?.noteRunEnd()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 调试：启动即展开面板，避免自动化点击菜单栏图标带来的不稳定
        if ProcessInfo.processInfo.environment["TOKENMETER_SHOW_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.statusBar?.showPanel()
            }
        }
        // 截图/排查用：直接打开设置窗口
        if ProcessInfo.processInfo.environment["TOKENMETER_SHOW_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                AppActions.shared.openSettings()
            }
        }
        // 一键更新后的重启：此时旧实例可能还没退干净，不能按「重复实例」处理
        let isPostUpdate = CommandLine.arguments.contains("--post-update")
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
            let me = ProcessInfo.processInfo.processIdentifier
            let bid = Bundle.main.bundleIdentifier ?? "nil"
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != me }
                .map { "\($0.processIdentifier)/\($0.localizedName ?? "?")" }
            FileHandle.standardError.write(Data("DBG dup-check bid=\(bid) others=\(others) postUpdate=\(isPostUpdate)\n".utf8))
        }
        if !isPostUpdate, StatusBarController.terminateIfDuplicate() {
            NSApp.terminate(nil)
            return
        }
        Fmt.english = L10n.isEnglish   // 数字单位（万/亿 vs K/M/B）跟语言走
        PricingTable.writeTemplateIfMissing()
        let model = AppModel()
        self.model = model
        statusBar = StatusBarController(model: model, actions: AppActions.shared)
        // 调试：TOKENMETER_FORCE_REFRESH=2 每 2 秒刷新一次，用于复现「刷新时日历闪」
        if let v = ProcessInfo.processInfo.environment["TOKENMETER_FORCE_REFRESH"].flatMap(Double.init), v > 0 {
            Timer.scheduledTimer(withTimeInterval: v, repeats: true) { _ in
                Task { @MainActor in model.refresh() }
            }
        }
        // 调试：TOKENMETER_DUMP_CSV=1 时把各范围导出到 /tmp，便于核对导出内容
        if ProcessInfo.processInfo.environment["TOKENMETER_DUMP_CSV"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                for r in RangeKind.allCases {
                    let csv = CSVExport.makeCSV(model: model, range: r)
                    try? csv.write(toFile: "/tmp/tm-export-\(r.rawValue).csv", atomically: true, encoding: .utf8)
                }
            }
        }
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
            let keys = model.harnessIcons.keys.sorted().joined(separator: ",")
            FileHandle.standardError.write(Data("DBG icons=\(keys)\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let titles = NSApp.windows.map { "[\($0.className) t=\($0.title) f=\($0.frame) vis=\($0.isVisible)]" }.joined(separator: " | ")
                FileHandle.standardError.write(Data("DBG windows \(NSApp.windows.count): \(titles)\n".utf8))
            }
        }
    }
}

    /// 自愈 Claude Code 钩子：设置文件里的 tokenmeter 钩子路径失效（应用被移动/重装）
    /// 或命令没加引号（旧版本的 bug，路径含空格会被 shell 拆断）时重新安装。
fileprivate func ensureClaudeHooks() {
        let settings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        let bin = "/Applications/TokenMeter.app/Contents/Resources/tokenmeter"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        let text = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        let hasHook = text.contains("tokenmeter hook-event")
        let wrongPath = hasHook
            && (!text.contains(bin) || text.contains("Application Support/TokenMeter/bin/tokenmeter"))
        // 钩子「配置了但从未生效」：Claude 日志最近还在写，而状态文件缺失或超过 2 天没更新。
        // 这通常是会话在钩子装好之前就启动了（Claude Code 只在会话启动时读一次配置），
        // 或者 settings.json 被别的工具覆盖过。静默重装一次，下次新会话即可生效。
        let neverFired: Bool = {
            guard hasHook else { return false }
            let fm = FileManager.default
            let statePath = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/TokenMeter/claude-state.json")
            let stateAge = (try? fm.attributesOfItem(atPath: statePath)[.modificationDate] as? Date) ?? nil
            let stale: Bool
            if let stateAge { stale = Date().timeIntervalSince(stateAge) > 2 * 86400 } else { stale = true }
            guard stale else { return false }
            // Claude 最近是否真的在用
            let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
            guard let en = fm.enumerator(atPath: root) else { return false }
            let cutoff = Date().addingTimeInterval(-2 * 86400)
            for case let rel as String in en where rel.hasSuffix(".jsonl") {
                let p = root + "/" + rel
                if let m = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? nil, m > cutoff {
                    return true
                }
            }
            return false
        }()
        let needsRepair = wrongPath || neverFired || !hasHook
        guard needsRepair else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["hook-install", "--apply"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

/// 扫描缓存常驻内存（独立于 MainActor，供后台扫描任务读写）
/// 缓存落盘串行队列：避免 App/CLI 并发写造成半成品覆盖
enum Config {
    static let saveQueue = DispatchQueue(label: "local.tokenmeter.cache-save", qos: .utility)
}

enum CacheStore {
    static let lock = NSLock()
    static var cache: ScanCache?
}

/// 火苗图标：只订阅 FlameTicker，不牵动面板其它内容重绘
struct FlameIcon: View {
    @ObservedObject var ticker: FlameTicker
    let frames: [NSImage]
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if frames.isEmpty {
            Image(systemName: "flame.fill")
                .foregroundStyle(.orange)
                .font(.system(size: size * 0.8))
        } else {
            Image(nsImage: frames[(reduceMotion ? 0 : ticker.frame) % frames.count])
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// 火苗逐帧计数器：独立 ObservableObject，避免整树重绘
@MainActor
final class FlameTicker: ObservableObject {
    @Published private(set) var frame: Int = 0
    private var phase: Double = 0

    func advance(elapsed: TimeInterval, period: TimeInterval, count: Int) {
        guard count > 0 else { return }
        phase = (phase + elapsed / period).truncatingRemainder(dividingBy: 1)
        let next = Int((phase * Double(count)).rounded()) % count
        if frame != next { frame = next }
    }
}

#endif
