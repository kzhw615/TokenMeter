#if os(macOS)
import SwiftUI
import AppKit
import ServiceManagement
@preconcurrency import TokenMeterCore

@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        PricingTable.writeTemplateIfMissing()
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// 应用入口：NSStatusItem 承载菜单栏图标（左键面板 / 右键菜单）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        self.model = model
        statusBar = StatusBarController(model: model, actions: AppActions.shared)
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
            let keys = model.harnessIcons.keys.sorted().joined(separator: ",")
            FileHandle.standardError.write(Data("DBG icons=\(keys)\n".utf8))
        }
        AppActions.shared.closePanel()
    }
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
    @Published var frame: Int = 0
    func advance(count: Int) {
        guard count > 0 else { return }
        frame = (frame + 1) % count
    }
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
    /// 扫描进度（0...1）与已处理/总文件数
    @Published var scanFraction: Double = 0
    @Published var scanDone: Int = 0
    @Published var scanTotal: Int = 0
    private var scanProgress: ScanProgress?
    @Published var updateChecking = false
    /// 面板是否展开（用于降低后台轮询频率省电）
    @Published var panelOpen = false
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
        "Reasonix": "reasonix",        // reasonix.io favicon
        "Droid": "droid",              // Factory AI 官方 avatar
        "Kiro": "kiro",                // kiro.dev favicon（紫底幽灵）
        "Copilot CLI": "copilot",      // GitHub Copilot 官方 mark（反白）
        "MiniMax Code": "minimax",     // minimax.io favicon
        "Qoder": "qoder",              // Qoder 官方 avatar
    ]
    private var harnessIconsLoaded = false
    func loadHarnessIcons() {
        guard !harnessIconsLoaded else { return }
        harnessIconsLoaded = true
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
    static let flameFrames: [NSImage] = (0..<16).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = false
        return img
    }

    /// 旺盛版火苗帧：燃烧速率超过阈值时切换（更大轮廓+侧舌+白热芯+火星）
    static let flameFramesIntense: [NSImage] = (0..<16).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_hot_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = false
        return img
    }

    /// 大尺寸火苗帧（高速率时用，避免放大失真）
    static let flameFramesBig: [NSImage] = (0..<16).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_big_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        return img
    }

    static let flameFramesIntenseBig: [NSImage] = (0..<16).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_hot_big_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        return img
    }

    /// 旺盛档阈值：15K tokens/s
    static let intenseRateThreshold: Int64 = 15_000
    var flameIntense: Bool { (burnRate ?? 0) >= Self.intenseRateThreshold }

    /// 火苗点尺寸随速率连续变化（13 → 20pt，对数压缩让低速也有变化）
    var flamePointSize: CGFloat {
        let rate = Double(burnRate ?? 0)
        guard rate > 0 else { return 13 }
        let t = min(1.0, pow(rate / 60_000.0, 0.45))
        return 13 + 7 * t
    }

    var currentFlameFrames: [NSImage] {
        let big = flamePointSize >= 17
        if flameIntense {
            let set = big && !Self.flameFramesIntenseBig.isEmpty ? Self.flameFramesIntenseBig : Self.flameFramesIntense
            return set.isEmpty ? Self.flameFrames : set
        }
        let set = big && !Self.flameFramesBig.isEmpty ? Self.flameFramesBig : Self.flameFrames
        return set.isEmpty ? Self.flameFrames : set
    }

    /// 火苗帧计数器独立成小对象：只让火苗图标重绘，避免 10fps 重绘整个面板树
    let flame = FlameTicker()
    private var flameTick = 0

    private var timer: Timer?
    private var activityTimer: Timer?
    private var flameTimer: Timer?
    private var updateTimer: Timer?
    private var watcher: FolderWatcher?
    private var debouncedRefresh: DispatchWorkItem?
    /// 上次统计刷新时刻（节流用）
    private var lastRefreshAt: Date = .distantPast
    private var lastPollAt: Date = .distantPast
    /// 上次扫描的文件总数（用作下次进度条分母）
    private var lastFileTotal: Int = 0

    init() {
        loadHarnessIcons()   // 图标随包内置/系统图标，启动即可用，避免坞上出现字母占位
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 面板收起时降到 15s 一次（省电）；燃烧中保持 5s 以便及时更新状态
                if !self.panelOpen && !self.isBurning {
                    let now = Date()
                    if now.timeIntervalSince(self.lastPollAt) < 15 { return }
                    self.lastPollAt = now
                } else {
                    self.lastPollAt = Date()
                }
                self.pollActivity()
            }
        }
        // 单一 UI 心跳：扫描进度 4Hz、火苗帧 5/10fps，全部空闲时不做任何工作
        flameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flameTick += 1

                if self.scanning, let p = self.scanProgress, self.flameTick % 3 == 0 {
                    self.scanFraction = p.fraction
                    self.scanDone = p.done
                    self.scanTotal = p.total
                }

                guard self.isBurning, !self.currentFlameFrames.isEmpty else { return }
                // 旺盛档 10fps，平稳档 5fps
                let step = self.flameIntense ? 1 : 2
                guard self.flameTick % step == 0 else { return }
                self.flame.advance(count: self.currentFlameFrames.count)
            }
        }
    }

    /// 监听各 harness 日志目录：有写入 → 防抖 8 秒后刷新（日志静止即扫，比固定轮询更及时且省电）
    private func startWatcher() {
        let roots = [
            "~/.claude/projects", "~/.codex/sessions", "~/.codex/archived_sessions",
            "~/.dsh/sessions", "~/.workbuddy/traces", "~/.local/share/opencode",
            "~/.hermes", "~/.zcode/cli/db",
        ].map { SourcePaths.expand($0) }
        watcher = FolderWatcher(paths: roots) { [weak self] in
            self?.scheduleDebouncedRefresh()
        }
        watcher?.start()
    }

    /// 刷新最小间隔：面板打开 20s（看数据要新）；面板关闭 45s；完全空闲（无燃烧）120s
    private var refreshInterval: TimeInterval {
        if panelOpen { return 20 }
        return isBurning ? 45 : 120
    }

    /// 节流式刷新：持续写入时也保证按间隔最多扫一次（旧防抖会无限推迟直到日志静止）
    func scheduleDebouncedRefresh() {
        let minInterval = refreshInterval
        let elapsed = Date().timeIntervalSince(lastRefreshAt)
        if elapsed >= minInterval {
            refresh()
            return
        }
        guard debouncedRefresh == nil else { return }   // 已有待执行任务，合并本次事件
        let delay = minInterval - elapsed
        let work = DispatchWorkItem { [weak self] in
            self?.debouncedRefresh = nil
            self?.refresh()
        }
        debouncedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 速率 = 今日总量在滑动窗口内的平均增速（采样来自统计刷新，无额外扫描开销）
    func updateRate(todayTotal: Int64, at now: Date) {
        rateSamples.append((now, todayTotal))
        rateSamples.removeAll { now.timeIntervalSince($0.0) > 25 }
        if let first = rateSamples.first, let last = rateSamples.last,
           first.0 < last.0, now.timeIntervalSince(first.0) >= 8 {
            let dt = last.0.timeIntervalSince(first.0)
            burnRate = max(0, Int64(Double(last.1 - first.1) / dt))
        } else if burnRate == nil {
            burnRate = 0
        }
    }

    /// 停止燃烧时清空速率
    func clearRate() {
        rateSamples.removeAll()
        burnRate = nil
    }

    func pollActivity() {
        Task.detached(priority: .utility) { [weak self] in
            // 单次合并遍历：同时得到「是否在跑」和「顶层任务最后活动」
            let snapshot = ActivityDetector.activitySnapshot()
            let now = Date()
            let active = snapshot.compactMap { $0.lastActive != nil && now.timeIntervalSince($0.lastActive!) <= ActivityDetector.defaultWindow ? $0.name : nil }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if active != self.burningSources {
                    self.burningSources = active
                    if active.isEmpty { self.clearRate() }
                }
                // 三态：运行中(<60s) / 待阅读(60s~10min) / 空闲(>10min)
                let states: [(String, Int)] = snapshot.compactMap { item in
                    guard let last = item.lastActive else { return nil }   // 无日志 = 未安装
                    let top = item.topLevel ?? last
                    let age = now.timeIntervalSince(top)
                    var st = active.contains(item.name) ? 0 : (age < 600 ? 1 : 2)
                    // WorkBuddy 用 sessions 表真实状态裁决
                    if item.name == "WorkBuddy", let wb = ActivityDetector.workBuddyState(now: now) { st = wb }
                    return (item.name, st)
                }
                let installedChanged = states.map { $0.0 } != self.sourceStates.map { $0.0 }
                self.sourceStates = states
                if installedChanged {
                    self.dockController.apply(mode: self.sideDock, model: self, useSaved: true)
                }
            }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        scanStartedAt = Date()
        scanFraction = 0
        scanDone = 0
        scanTotal = 0
        let progress = ScanProgress()
        // 用上一次扫描的文件总数作为进度分母：省掉一次全量目录遍历
        progress.start(total: lastFileTotal)
        scanProgress = progress
        lastRefreshAt = Date()
        Task.detached(priority: .utility) {
            let pricing = PricingTable.load()
            var cache = CacheStore.lock.withLock { CacheStore.cache } ?? ScanCache.load()
            let scanned = Aggregator.scan(cache: &cache, progress: progress)
            // 一次扫描，七个范围的 Summary 全部预计算
            let all: [RangeKind: Summary] = Dictionary(uniqueKeysWithValues: RangeKind.allCases.map { r in
                (r, Aggregator.summarize(buckets: scanned.buckets, range: r, pricing: pricing, statuses: scanned.statuses))
            })
            // 落盘后释放内存中的全量分桶缓存（约 150-200MB），下次从磁盘按需加载
            if cache.dirty {
                var mutable = cache
                mutable.dirty = false
                let snapshot = mutable
                Config.saveQueue.async { snapshot.save() }
            }
            CacheStore.lock.withLock { CacheStore.cache = nil }
            let todayTotal = all[.today]?.counts.total ?? 0
            let fileTotal = scanned.statuses.reduce(0) { $0 + $1.files }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.summariesByRange = all
                self.loadHarnessIcons()
                self.lastScan = Date()
                self.scanning = false
                self.scanStartedAt = nil
                self.scanProgress = nil
                self.lastFileTotal = fileTotal
                self.updateRate(todayTotal: todayTotal, at: Date())
                self.evaluateBudget()
            }
        }
    }
}

/// 菜单栏图标资源（NSStatusItem 使用）
enum MenuBarAssets {
    /// 单色模板图标（Assets/menubar_icon@2x.png），缺失时回退 SF Symbol
    static let barIcon: NSImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_icon@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 20, height: 20)
        img.isTemplate = true
        return img
    }()
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
