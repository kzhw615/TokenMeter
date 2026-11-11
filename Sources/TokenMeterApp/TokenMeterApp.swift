#if os(macOS)
import SwiftUI
import AppKit
import ServiceManagement
import TokenMeterCore

@main
struct TokenMeterApp: App {
    @StateObject private var model = AppModel()

    init() {
        PricingTable.writeTemplateIfMissing()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 扫描缓存常驻内存（独立于 MainActor，供后台扫描任务读写）
enum CacheStore {
    static let lock = NSLock()
    static var cache: ScanCache?
}

@MainActor
final class AppModel: ObservableObject {
    /// 所有范围的预计算结果：切换范围 = 内存查表，瞬时响应
    @Published private(set) var summariesByRange: [RangeKind: Summary] = [:]
    var summary: Summary? { summariesByRange[range] }

    @Published var range: RangeKind = .today
    @Published var lastScan: Date?
    @Published var scanning = false
    @Published var scanStartedAt: Date?
    @Published var updateChecking = false
    /// 统计口径：true = 含缓存（input+output+cacheRead+cacheWrite），false = 不含缓存（input+output）
    @Published var includeCache: Bool = UserDefaults.standard.object(forKey: "includeCache") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeCache, forKey: "includeCache") }
    }
    /// 主题色（Accent）
    @Published var themeID: String = UserDefaults.standard.string(forKey: "themeID") ?? "teal" {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    var theme: AppTheme { AppTheme.theme(for: themeID) }

    /// 菜单栏显示样式：both / tokens / cost / icon
    @Published var menuBarStyle: String = UserDefaults.standard.string(forKey: "menuBarStyle") ?? "both" {
        didSet { UserDefaults.standard.set(menuBarStyle, forKey: "menuBarStyle") }
    }

    /// 侧边悬浮坞：off / left / right
    @Published var sideDock: String = UserDefaults.standard.string(forKey: "sideDock") ?? "off" {
        didSet {
            UserDefaults.standard.set(sideDock, forKey: "sideDock")
            dockController.apply(mode: sideDock, model: self, useSaved: false)
        }
    }
    private let dockController = SideDockController()

    /// 开机自启（SMAppService）
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @Published var settingsMessage: String?
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            settingsMessage = on ? "已加入登录项" : "已移除登录项"
        } catch {
            settingsMessage = "设置失败：\(error.localizedDescription)"
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.settingsMessage = nil
        }
    }

    /// 燃烧速率（tokens/秒），由热扫描采样差分得出
    @Published var burnRate: Int64?
    private var rateSamples: [(Date, Int64)] = []

    /// 更新检查状态
    @Published var latestVersion: String?
    @Published var releaseURL: URL?
    @Published var latestAssetURL: URL?
    @Published var latestDigest: String?
    @Published var updatePhase: UpdatePhase = .idle

    enum UpdatePhase: Equatable {
        case idle, downloading, verifying, installing, restarting, failed(String)
        var busy: Bool {
            switch self {
            case .idle, .failed: return false
            default: return true
            }
        }
    }

    var updateButtonTitle: String {
        switch updatePhase {
        case .idle, .failed: return "一键更新"
        case .downloading: return "下载中…"
        case .verifying: return "校验中…"
        case .installing: return "安装中…"
        case .restarting: return "重启中…"
        }
    }

    /// 正在燃烧的 harness（日志近 2 分钟有写入）
    @Published var burningSources: [String] = []
    var isBurning: Bool { !burningSources.isEmpty }

    /// 坞底 harness 三态：0 运行中 / 1 待阅读 / 2 空闲；仅含本机有日志的源
    @Published var sourceStates: [(String, Int)] = []
    /// 侧边坞隐藏名单（默认全展示已安装源）
    @Published var hiddenDockSources: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dockHiddenSources") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(hiddenDockSources), forKey: "dockHiddenSources")
            dockController.apply(mode: sideDock, model: self, useSaved: true)
        }
    }
    /// harness 真实 App 图标（本机装了 .app 的源）；其余用品牌色字母徽章
    @Published var harnessIcons: [String: NSImage] = [:]
    private static let harnessAppPaths: [String: String] = [
        "WorkBuddy": "/Applications/WorkBuddy.app",
    ]
    /// 内置品牌 logo 资源名（官网 favicon/官方 logo 打包）
    private static let harnessBundledIcons: [String: String] = [
        "Claude Code": "claude",      // Anthropic spark
        "Codex": "codex",              // OpenAI knot
        "DSH": "deepseek",             // DeepSeek whale
        "OpenCode": "opencode",        // opencode block glyph
        "Hermes": "hermes",            // 用户提供：黑白女孩标
        "ZCode": "zcode",              // 用户提供：黑底白 Z
    ]
    func loadHarnessIcons() {
        var icons: [String: NSImage] = [:]
        for (name, res) in Self.harnessBundledIcons {
            if let url = Bundle.module.url(forResource: res, withExtension: "png", subdirectory: "harness"),
               let img = NSImage(contentsOf: url), img.size.width > 0 {
                icons[name] = img
            }
        }
        for (name, path) in Self.harnessAppPaths where FileManager.default.fileExists(atPath: path) {
            let img = NSWorkspace.shared.icon(forFile: path)
            if img.size.width > 0 { icons[name] = img }
        }
        harnessIcons = icons
    }

    /// 侧边坞是否展示 harness 状态条（总开关）
    @Published var dockShowHarness: Bool = UserDefaults.standard.object(forKey: "dockShowHarness") == nil ? true : UserDefaults.standard.bool(forKey: "dockShowHarness") {
        didSet {
            UserDefaults.standard.set(dockShowHarness, forKey: "dockShowHarness")
            dockController.apply(mode: sideDock, model: self, useSaved: true)
        }
    }
    var visibleDockSources: [(String, Int)] {
        guard dockShowHarness else { return [] }
        return sourceStates.filter { !hiddenDockSources.contains($0.0) }
    }

    func menuBarText(_ s: Summary) -> String {
        let shown = includeCache ? s.counts.total : s.counts.input + s.counts.output
        let rate = (isBurning && (burnRate ?? 0) > 0) ? "\(Fmt.compactTokens(burnRate ?? 0))/s · " : ""
        switch menuBarStyle {
        case "tokens": return rate + Fmt.compactTokens(shown)
        case "cost": return rate + Fmt.cost(s.cost)
        case "icon": return ""
        default: return rate + "\(Fmt.compactTokens(shown)) · \(Fmt.cost(s.cost))"
        }
    }

    func setRange(_ r: RangeKind) {
        guard r != range else { return }
        range = r   //  summariesByRange 已预计算，直接查表，无需重扫
    }

    /// 燃烧状态的彩色火苗帧（平稳版）
    static let flameFrames: [NSImage] = (0..<6).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = false
        return img
    }

    /// 旺盛版火苗帧：燃烧速率超过阈值时切换（更大轮廓+侧舌+白热芯+火星）
    static let flameFramesIntense: [NSImage] = (0..<6).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_hot_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = false
        return img
    }

    /// 旺盛档阈值：15K tokens/s
    static let intenseRateThreshold: Int64 = 15_000
    var flameIntense: Bool { (burnRate ?? 0) >= Self.intenseRateThreshold }
    var currentFlameFrames: [NSImage] { flameIntense && !Self.flameFramesIntense.isEmpty ? Self.flameFramesIntense : Self.flameFrames }

    @Published var flameFrame: Int = 0
    private var flameTick = 0

    private var timer: Timer?
    private var activityTimer: Timer?
    private var flameTimer: Timer?
    private var updateTimer: Timer?
    private var watcher: FolderWatcher?
    private var debouncedRefresh: DispatchWorkItem?

    init() {
        refresh()
        checkForUpdates()
        maybeDailyUpdateCheck()
        pollActivity()
        Self.cleanupOldBackups()
        startWatcher()
        dockController.apply(mode: sideDock, model: self, useSaved: true)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.maybeDailyUpdateCheck() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollActivity() }
        }
        flameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isBurning, !self.currentFlameFrames.isEmpty else { return }
                self.flameTick += 1
                // 旺盛档 10fps，平稳档 5fps
                let step = self.flameIntense ? 1 : 2
                guard self.flameTick % step == 0 else { return }
                self.flameFrame = (self.flameFrame + 1) % self.currentFlameFrames.count
            }
        }
    }

    /// 监听各 harness 日志目录：有写入 → 防抖 8 秒后刷新（日志静止即扫，比固定轮询更及时且省电）
    private func startWatcher() {
        let roots = [
            "~/.claude/projects", "~/.codex/sessions", "~/.codex/archived_sessions",
            "~/.dsh/sessions", "~/.workbuddy/traces", "~/.local/share/opencode",
            "~/.hermes", "~/.zcode/cli/db", "~/.cc-switch",
        ].map { SourcePaths.expand($0) }
        watcher = FolderWatcher(paths: roots) { [weak self] in
            self?.scheduleDebouncedRefresh()
        }
        watcher?.start()
    }

    func scheduleDebouncedRefresh() {
        debouncedRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        debouncedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func pollActivity() {
        Task.detached(priority: .utility) { [weak self] in
            let active = ActivityDetector.activeSources()
            let now = Date()
            let hot: Int64? = active.isEmpty ? nil : Aggregator.hotTodayTotal(since: now.addingTimeInterval(-180), now: now)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if active != self.burningSources { self.burningSources = active }
                // 三态：运行中(<60s) / 待阅读(60s~10min) / 空闲(>10min)
                let states: [(String, Int)] = ActivityDetector.lastActivity(now: now).compactMap { name, date in
                    guard let date else { return nil }   // 无日志 = 未安装，不展示
                    let age = now.timeIntervalSince(date)
                    var st = active.contains(name) ? 0 : (age < 600 ? 1 : 2)
                    // WorkBuddy 有真实未读回执：unread>0 即"待阅读"（不受 10min 限制）
                    if name == "WorkBuddy", st == 2, ActivityDetector.workBuddyUnreadCount() > 0 { st = 1 }
                    return (name, st)
                }
                let installedChanged = states.map { $0.0 } != self.sourceStates.map { $0.0 }
                self.sourceStates = states
                if installedChanged {
                    self.dockController.apply(mode: self.sideDock, model: self, useSaved: true)
                }
                if let hot {
                    self.rateSamples.append((now, hot))
                    self.rateSamples.removeAll { now.timeIntervalSince($0.0) > 25 }
                    // 20s 窗口平均速率（5s 采样）：跟手且平滑；停止出 token 后较快回落
                    if let first = self.rateSamples.first, let last = self.rateSamples.last,
                       first.0 < last.0, now.timeIntervalSince(first.0) >= 10 {
                        let dt = last.0.timeIntervalSince(first.0)
                        self.burnRate = max(0, Int64(Double(last.1 - first.1) / dt))
                    } else if self.burnRate == nil {
                        self.burnRate = 0   // 燃烧中但样本不足：显示 0/s 而非隐藏
                    }
                } else {
                    self.rateSamples.removeAll()
                    self.burnRate = nil
                }
            }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        scanStartedAt = Date()
        Task.detached(priority: .utility) {
            let pricing = PricingTable.load()
            var cache = CacheStore.lock.withLock { CacheStore.cache } ?? ScanCache.load()
            let scanned = Aggregator.scan(cache: &cache)
            // 一次扫描，七个范围的 Summary 全部预计算
            var all: [RangeKind: Summary] = [:]
            for r in RangeKind.allCases {
                all[r] = Aggregator.summarize(buckets: scanned.buckets, range: r, pricing: pricing, statuses: scanned.statuses)
            }
            if cache.dirty {
                var snapshot = cache
                snapshot.dirty = false
                Task.detached(priority: .background) { snapshot.save() }
            }
            CacheStore.lock.withLock { CacheStore.cache = cache }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.summariesByRange = all
                self.loadHarnessIcons()
                self.lastScan = Date()
                self.scanning = false
                self.scanStartedAt = nil
                self.evaluateBudget()
            }
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    /// 菜单栏专用单色模板图标（Assets/menubar_icon@2x.png），缺失时回退 SF Symbol
    static let barIcon: NSImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_icon@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 20, height: 20)
        img.isTemplate = true
        return img
    }()

    /// 燃烧状态的彩色火苗（非模板图，保留橙红渐变）
    static let flameIcon: NSImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = false
        return img
    }()

    var body: some View {
        HStack(spacing: 4) {
            if model.isBurning {
                let frames = model.currentFlameFrames
                if !frames.isEmpty {
                    Image(nsImage: frames[model.flameFrame % frames.count])
                } else {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
            } else if let img = Self.barIcon {
                Image(nsImage: img)
            } else {
                Image(systemName: "circle.hexagongrid.fill")
            }
            if model.menuBarStyle != "icon" {
                if let s = model.summary, s.counts.total > 0 {
                    Text(model.menuBarText(s))
                        .monospacedDigit()
                        .foregroundStyle(model.budgetOver ? Color.red : Color.primary)
                } else if model.scanning {
                    Text("…")
                } else {
                    Text("0")
                }
            }
        }
    }
}

#else
import Foundation

@main
struct TokenMeterAppFallback {
    static func main() {
        print("TokenMeter 菜单栏应用仅支持 macOS；本平台请使用 tokenmeter CLI。")
    }
}
#endif
