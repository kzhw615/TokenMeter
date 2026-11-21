#if os(macOS)
import SwiftUI
import Darwin
import AppKit
import ServiceManagement
@preconcurrency import TokenMeterCore

@MainActor
final class AppModel: ObservableObject {
    /// 所有范围的预计算结果：切换范围 = 内存查表，瞬时响应
    @Published private(set) var summariesByRange: [RangeKind: Summary] = [:]
    /// 最近一次扫描的原始分桶与价目表：导出 CSV 用（不参与 UI 渲染）
    private(set) var lastBuckets: [UsageBucket] = []
    private(set) var lastPricing: PricingTable = .load()
    /// 上次把汇总结果写入缓存的时间（落盘节流用）
    private var lastSummarySaveAt: Date?
    /// 上一次运行结束的时间（启动时读取并冻结）。
    /// 用途：重启电脑/重开 App 时，关机前就已完成的任务不该再亮「待阅读」——
    /// 那些完成时间比上次退出还早，我们根本没机会「读」到它。
    private let previousExitAt: Date? = {
        guard let ts = UserDefaults.standard.object(forKey: "lastRunEndAt") as? Double, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }()
    var summary: Summary? { summariesByRange[range] }

    @Published var range: RangeKind = .today
    private var hasPublishedData = false
    private var lastFullScanAt: Date?
    @Published var lastScan: Date?
    @Published var scanning = false
    @Published var scanStartedAt: Date?
    /// 扫描进度（0...1）与已处理/总文件数
    @Published var scanFraction: Double = 0
    @Published var scanDone: Int = 0
    @Published var scanTotal: Int = 0
    /// 当前正在扫描的数据源（骨架屏展示用）
    @Published var scanLabel: String = ""
    private var scanProgress: ScanProgress?
    @Published var updateChecking = false
    /// 检查更新的结果提示（已是最新 / 失败原因 / 发现新版），面板头部展示
    @Published var updateNotice: String?
    /// 最近一次检查失败的具体原因，用于拼提示文案
    var lastCheckError: String?
    /// 面板是否展开（用于降低后台轮询频率省电）
    @Published var panelOpen = false {
        didSet { if flameTimer != nil { startHeartbeat() } }
    }
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
            if flameTimer != nil { startHeartbeat() }
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
    var isBurning: Bool {
        // 调试：TOKENMETER_FORCE_BURN=1 强行进入「燃烧中」，方便验证菜单栏宽度变化
        if ProcessInfo.processInfo.environment["TOKENMETER_FORCE_BURN"] != nil { return true }
        return !burningSources.isEmpty
    }

    /// 坞底 harness 三态：0 运行中 / 1 待阅读 / 2 空闲；仅含本机有日志的源
    @Published var sourceStates: [(String, Int)] = []
    @Published var dataIssues: [DataIssue] = []
    /// 面板外观：auto（跟随系统）/ dark / light
    @Published var panelAppearance: String = UserDefaults.standard.string(forKey: "panelAppearance") ?? "auto" {
        didSet { UserDefaults.standard.set(panelAppearance, forKey: "panelAppearance") }
    }
    /// 悬浮坞材质：ink（纯黑）/ glass（液态玻璃）
    @Published var dockStyle: String = UserDefaults.standard.string(forKey: "dockStyle") ?? "ink" {
        didSet {
            UserDefaults.standard.set(dockStyle, forKey: "dockStyle")
            // 重建坞以应用新材质
            dockController.apply(mode: sideDock, model: self, useSaved: true)
        }
    }
    /// 玻璃不透明度：0 = 全透明，1 = 完全不透明。面板与悬浮坞共用
    @Published var glassOpacity: Double = UserDefaults.standard.object(forKey: "glassOpacity") as? Double ?? 0.55 {
        didSet {
            UserDefaults.standard.set(glassOpacity, forKey: "glassOpacity")
            dockController.apply(mode: sideDock, model: self, useSaved: true)
        }
    }
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
        "OpenMausBot": "openmausbot",  // 用户提供：黑白幽灵标
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

    /// 菜单栏是否太挤（挤的时候只显示用量，不显示速度，见 menuBarRateMode）
    @Published var menuBarCrowded = false
    /// 速度显示策略：auto（默认，菜单栏挤时收起）/ always / never
    var menuBarRateMode: String {
        get { UserDefaults.standard.string(forKey: "menuBarRateMode") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarRateMode") }
    }

    func menuBarText(_ s: Summary, includeRate: Bool = true) -> String {
        let shown = includeCache ? s.counts.total : s.counts.input + s.counts.output
        // 速率段定宽（figure space 补位）：否则「29.5K/s · 7.09亿」↔「7.09亿」会让
        // 状态栏图标左右跳动，连带着面板位置也会晃。
        // 显示速度时把这一段补成定宽，避免数值位数变化让图标抖动；
        // 不显示速度时不要留白，否则「收起速度」就白收了（宽度一点没省）。
        let forced = ProcessInfo.processInfo.environment["TOKENMETER_FORCE_BURN"] != nil
        let wantsRate = includeRate && isBurning && (forced || (burnRate ?? 0) > 0)
        let rate = wantsRate
            ? "\(Fmt.compactTokens(burnRate ?? 29_500))/s · ".padding(toLength: 10, withPad: "\u{2007}", startingAt: 0)
            : ""
        switch menuBarStyle {
        // 与面板、坞保持一致：用 Fmt.tokens（亿两位小数）。
        // compactTokens 只保留一位小数，会把 6.99亿 显示成 7.0亿，和别处对不上。
        case "tokens": return rate + Fmt.tokens(shown)
        case "cost": return rate + Fmt.cost(s.cost)
        case "icon": return ""
        default: return rate + "\(Fmt.tokens(shown)) · \(Fmt.cost(s.cost))"
        }
    }

    func setRange(_ r: RangeKind) {
        guard r != range else { return }
        range = r   //  summariesByRange 已预计算，直接查表，无需重扫
    }

    /// 每档用 24 帧覆盖一个完整周期，显示时按经过的时间取样。
    static let flameFrameCount = 24

    private static func loadFlameFrames(_ prefix: String, pointSize: CGFloat) -> [NSImage] {
        (0..<flameFrameCount).compactMap { i in
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("\(prefix)\(i)@2x.png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            img.size = NSSize(width: pointSize, height: pointSize)
            img.isTemplate = false
            return img
        }
    }

    static let flameFrames = loadFlameFrames("menubar_flame_", pointSize: 19)
    static let flameFramesWarm = loadFlameFrames("menubar_flame_warm_", pointSize: 19)
    static let flameFramesIntense = loadFlameFrames("menubar_flame_hot_", pointSize: 19)
    static let flameFramesIntenseBig = loadFlameFrames("menubar_flame_hot_big_", pointSize: 19)
    static let flameFramesInferno = loadFlameFrames("menubar_flame_inferno_", pointSize: 19)
    static let flameFramesInfernoBig = loadFlameFrames("menubar_flame_inferno_big_", pointSize: 19)
    static let flameFramesBlast = loadFlameFrames("menubar_flame_blast_", pointSize: 19)
    static let flameFramesBlastBig = loadFlameFrames("menubar_flame_blast_big_", pointSize: 19)

    /// 档位阈值：≥4K 微旺，≥15K 旺盛，≥30K 猛燃（多舌），≥50K 爆燃（最高档）
    static let warmRateThreshold: Int64 = 4_000
    static let intenseRateThreshold: Int64 = 15_000
    static let infernoRateThreshold: Int64 = 30_000
    static let blastRateThreshold: Int64 = 50_000

    enum FlameTier {
        case calm, warm, hot, inferno, blast

        func period(menuOnly: Bool) -> TimeInterval {
            switch self {
            case .calm: return 2.65
            case .warm: return 1.72
            case .hot: return 1.12
            case .inferno: return menuOnly ? 1.30 : 1.08
            case .blast: return menuOnly ? 1.95 : 1.48
            }
        }
    }

    var flameTier: FlameTier {
        // 诊断：TOKENMETER_FLAME_TIER=calm|warm|hot|inferno|blast 强制档位
        switch ProcessInfo.processInfo.environment["TOKENMETER_FLAME_TIER"] {
        case "calm": return .calm
        case "warm": return .warm
        case "hot": return .hot
        case "inferno": return .inferno
        case "blast": return .blast
        default: break
        }
        let rate = burnRate ?? 0
        if rate >= Self.blastRateThreshold { return .blast }
        if rate >= Self.infernoRateThreshold { return .inferno }
        if rate >= Self.intenseRateThreshold { return .hot }
        if rate >= Self.warmRateThreshold { return .warm }
        return .calm
    }

    /// 火苗点尺寸随速率连续变化（12 → 23pt，对数压缩让低速也有变化）
    var flamePointSize: CGFloat {
        if let forced = ProcessInfo.processInfo.environment["TOKENMETER_FLAME_TIER"] {
            switch forced {
            case "calm": return 13
            case "warm": return 16
            case "hot": return 19
            case "inferno": return 22
            case "blast": return 23
            default: break
            }
        }
        let rate = Double(burnRate ?? 0)
        guard rate > 0 else { return 12 }
        let t = min(1.0, pow(rate / 60_000.0, 0.45))
        // 15K → 40K 之间把「爆燃加成」线性引入（0 → 2pt），
        // 这样跨档瞬间尺寸连续，不会突然弹一下；仅形状切换。
        let ramp = min(1.0, max(0.0, (rate - Double(Self.intenseRateThreshold))
                                       / (Double(Self.infernoRateThreshold) - Double(Self.intenseRateThreshold))))
        // 爆燃档再加一段，封顶 23pt（菜单栏高度有限，再大就会被裁）
        let ramp2 = min(1.0, max(0.0, (rate - Double(Self.infernoRateThreshold))
                                        / (Double(Self.blastRateThreshold) - Double(Self.infernoRateThreshold))))
        return min(23, 12 + 10 * t + 2 * CGFloat(ramp) + 1.5 * CGFloat(ramp2))
    }

    var currentFlameFrames: [NSImage] {
        flameFrames(for: flamePointSize)
    }

    func flameFrames(for pointSize: CGFloat) -> [NSImage] {
        let big = pointSize >= 18
        switch flameTier {
        case .blast:
            let set = big && !Self.flameFramesBlastBig.isEmpty ? Self.flameFramesBlastBig : Self.flameFramesBlast
            return set.isEmpty ? Self.flameFramesInferno : set
        case .inferno:
            let set = big && !Self.flameFramesInfernoBig.isEmpty ? Self.flameFramesInfernoBig : Self.flameFramesInferno
            return set.isEmpty ? Self.flameFramesIntense : set
        case .hot:
            let set = big && !Self.flameFramesIntenseBig.isEmpty ? Self.flameFramesIntenseBig : Self.flameFramesIntense
            return set.isEmpty ? Self.flameFrames : set
        case .warm:
            return Self.flameFramesWarm.isEmpty ? Self.flameFrames : Self.flameFramesWarm
        case .calm:
            return Self.flameFrames
        }
    }

    /// 火苗帧计数器独立成小对象：只让火苗图标重绘，避免 10fps 重绘整个面板树
    let flame = FlameTicker()
    private var flameTick = 0
    private var lastHeartbeat: TimeInterval = 0

    private var timer: Timer?
    private var activityTimer: Timer?
    private var flameTimer: Timer?
    // 诊断计数（TOKENMETER_DEBUG 时每 10 秒输出一次）
    private var dbgWatcherEvents = 0
    private var dbgPollCount = 0
    private var dbgPollSeconds = 0.0
    private var dbgRefreshCount = 0
    private var dbgTimer: Timer?
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
        // 先把上次的汇总结果贴上去：面板立刻有数据，不必等本次扫描
        if let cached = SummaryCache.load() {
            summariesByRange = cached.summaries
            hasPublishedData = true
            lastScan = cached.savedAt
        }
        refresh()
        checkForUpdates()
        maybeDailyUpdateCheck()
        pollActivity()
        Self.cleanupOldBackups()
        startWatcher()
        startDebugMeter()
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
                // 面板打开时才需要 5s 级的新鲜度；收起时（含燃烧中）放宽到 10~15s。
                // 单次活动检测约 0.11s CPU，5s 一次等于白白吃掉 2%+ 单核。
                let now = Date()
                let minGap: TimeInterval = self.panelOpen ? 0 : (self.isBurning ? 20 : 45)
                if now.timeIntervalSince(self.lastPollAt) < minGap { return }
                self.lastPollAt = now
                self.pollActivity()
            }
        }
        // 单一 UI 心跳：仅在「燃烧中」或「扫描中」运行，空闲时彻底停止
        startHeartbeat()
    }

    /// 按需启动心跳（有燃烧或扫描时才需要逐帧刷新）。
    ///
    /// 性能注意：之前每 100ms 新建一个 Task 再跳回主线程，实测这一项就吃掉 ~6% CPU
    /// （定时器本来就在主 RunLoop 上，Task 是多此一举的调度开销）。
    /// 现在直接在主线程执行；并且只在「动画看得见」时才用 10Hz：
    /// 面板打开或悬浮坞开着 → 0.1s；否则 → 0.25s（菜单栏火苗降到 4Hz，肉眼几乎无差）。
    func startHeartbeat() {
        let animateFast = panelOpen || sideDock != "off"
        // 10fps：6fps 实测肉眼可见卡顿（火焰是逐帧位图，帧少了像掉帧）。
        // 两处共用同一帧号，帧率必须一致，否则节奏对不上。
        let override = ProcessInfo.processInfo.environment["TOKENMETER_HEARTBEAT"].flatMap(Double.init)
        let hbInterval = override.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (animateFast ? 0.1 : 0.25)
        if flameTimer?.timeInterval == hbInterval { return }
        flameTimer?.invalidate()
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: hbInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeatTick() }
        }
        t.tolerance = hbInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        flameTimer = t
    }

    /// 心跳主体（主线程直调，不再每个 tick 新建 Task）
    private func heartbeatTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastHeartbeat
        lastHeartbeat = now
        flameTick += 1

        if scanning, let p = scanProgress, flameTick % 3 == 0 {
            scanFraction = p.fraction
            scanDone = p.done
            scanTotal = p.total
        }

        if !isBurning && !scanning {
            stopHeartbeat()          // 空闲：停掉定时器，让系统可以休眠
            return
        }
        guard isBurning else { return }
        let period = flameTier.period(menuOnly: (flameTimer?.timeInterval ?? 0.1) >= 0.25)
        flame.advance(elapsed: elapsed, period: period, count: currentFlameFrames.count)
    }

    func stopHeartbeat() {
        flameTimer?.invalidate()
        flameTimer = nil
    }

    /// 监听各 harness 日志目录：有写入 → 防抖 8 秒后刷新（日志静止即扫，比固定轮询更及时且省电）
    private func startDebugMeter() {
        guard ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil else { return }
        dbgTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let line = String(format: "DBG 10s: watcher=%d refresh=%d poll=%d pollCPU=%.2fs open=%d\n",
                                  self.dbgWatcherEvents, self.dbgRefreshCount,
                                  self.dbgPollCount, self.dbgPollSeconds, self.panelOpen ? 1 : 0)
                FileHandle.standardError.write(Data(line.utf8))
                self.dbgWatcherEvents = 0; self.dbgRefreshCount = 0
                self.dbgPollCount = 0; self.dbgPollSeconds = 0
            }
        }
        dbgTimer.map { RunLoop.main.add($0, forMode: .common) }
    }

    private func startWatcher() {
        if ProcessInfo.processInfo.environment["TOKENMETER_NO_WATCH"] != nil { return }
        let roots = [
            "~/.claude/projects", "~/.codex/sessions", "~/.codex/archived_sessions",
            "~/.dsh/sessions", "~/.workbuddy/traces", "~/.local/share/opencode",
            "~/.hermes", "~/.zcode/cli/db",
        ].map { SourcePaths.expand($0) }
        watcher = FolderWatcher(paths: roots) { [weak self] in
            self?.dbgWatcherEvents += 1
            self?.scheduleDebouncedRefresh()
        }
        watcher?.start()
    }

    /// 刷新最小间隔：面板打开 20s（看数据要新）；面板关闭 45s；完全空闲（无燃烧）120s
    private var refreshInterval: TimeInterval {
        if panelOpen { return 20 }          // 面板打开：数据要新
        return isBurning ? 60 : 180         // 收起时放宽：一次扫描 1.2s，45s 一次太密
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

    /// 已读闩锁：记录每个源「已查看到的完成时间」，避免切走后绿灯又亮
    func markRead(name: String, completedAt: Date) {
        let key = "readUpTo-\(name)"
        let value = completedAt.timeIntervalSince1970
        if abs(UserDefaults.standard.double(forKey: key) - value) > 1 {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// 手动把所有源当前的结果标记为已读（CLI 类工具没有宿主 App，只能手动消灯）
    func markAllRead() {
        // 用当前时间作为已读水位：此刻之前的完成结果全部视为已读
        let now = Date()
        for (name, _) in sourceStates {
            markRead(name: name, completedAt: now)
        }
        // 立即刷新三态，让灯马上变灰
        pollActivity()
    }

    func isRead(name: String, completedAt: Date) -> Bool {
        let stored = UserDefaults.standard.double(forKey: "readUpTo-\(name)")
        return stored > 0 && completedAt.timeIntervalSince1970 <= stored + 1
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
        if ProcessInfo.processInfo.environment["TOKENMETER_NO_POLL"] != nil { return }
        // 持续刷新「本次运行到过的时间」，供下次启动判断「关机前就已完成」的任务
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastRunEndAt")
        dbgPollCount += 1
        let dbgT0 = Date()
        Task.detached(priority: .utility) { [weak self] in
            // 单次合并遍历：各源最后活动 + 顶层活动
            let snapshot = ActivityDetector.activitySnapshot()
            let now = Date()
            // 精确状态信号（放在后台线程，避免阻塞 UI）
            let dshRunning = DshSource.isTaskRunning()
            let codexTurn = ActivityDetector.codexTurnState(now: now)
            let wbState = ActivityDetector.workBuddyState(now: now)
            let ombState = ActivityDetector.openMausBotState(now: now)
            let claudeHook = ActivityDetector.claudeHookState(now: now)
            let claudeRunning = ActivityDetector.claudeTaskRunning(now: now)

            let dbgElapsed = Date().timeIntervalSince(dbgT0)
            await MainActor.run { [weak self] in self?.dbgPollSeconds += dbgElapsed }
            let states: [(name: String, st: Int, done: Date?)] = snapshot.compactMap { item in
                guard let last = item.lastActive else { return nil }   // 无日志 = 未安装
                let top = item.topLevel ?? last
                let age = now.timeIntervalSince(top)
                let fresh = now.timeIntervalSince(last) <= ActivityDetector.defaultWindow
                // 能判断「是否正在看」的源给 3 分钟；其余（如通过 Obsidian 插件驱动的
                // Claude Code，前台永远是 Obsidian）无法感知已读，绿灯只保留 90 秒。
                let readWindow: TimeInterval = ActivityDetector.hasHostAppSignal(for: item.name) ? 180 : 90
                var st = fresh ? 0 : (age < readWindow ? 1 : 2)
                var done: Date? = top

                switch item.name {
                case "DSH":
                    // 长工具执行时日志可能几分钟不 flush：看日志尾部事件是否仍在推进
                    if st != 0, dshRunning == true { st = 0 }
                case "Codex":
                    // 以 thread_history sqlite 的 turn 状态为准（被继续的会话写在旧日期目录里）
                    if let cs = codexTurn {
                        if cs.running {
                            st = 0
                        } else if let cdone = cs.lastCompleted {
                            done = cdone
                            if now.timeIntervalSince(cdone) < 180 { st = max(st, 1) }
                        }
                    }
                case "Claude Code":
                    // ① 装了 hooks ⇒ 用事件精确判定（Stop 一触发就是结束）
                    // ② 否则回退日志尾部 stop_reason：
                    //    end_turn ⇒ 立刻熄灭；tool_use ⇒ 长工具期间保持亮灯
                    if let hook = claudeHook {
                        if hook.running { st = 0 } else if st == 0 { st = 1 }
                    } else if let running = claudeRunning {
                        if running { st = 0 } else if st == 0 { st = 1 }
                    }
                case "WorkBuddy":
                    if let wb = wbState { st = wb }
                case "OpenMausBot":
                    // 有真实已读回执，别用 mtime 推断（否则读完还要绿 3 分钟）
                    if let omb = ombState { st = omb }
                default:
                    break
                }
                return (item.name, st, done)
            }

            // 「燃烧中」直接由三态推导：状态准确，菜单栏火苗就不会在大任务中途熄灭
            let active = states.filter { $0.st == 0 }.map { $0.name }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if active != self.burningSources {
                    self.burningSources = active
                    if !active.isEmpty { self.startHeartbeat() }
                    if active.isEmpty { self.clearRate() }
                }
                if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                    let desc = snapshot.map { "\($0.name):last=\($0.lastActive.map { String(format: "%.0fs", now.timeIntervalSince($0)) } ?? "-")" }.joined(separator: " ")
                    FileHandle.standardError.write(Data("DBG snapshot \(desc)\n".utf8))
                    FileHandle.standardError.write(Data("DBG active=\(active) states=\(states.map { "\($0.name)=\($0.st)" })\n".utf8))
                }
                // 已读闩锁：只要「正在看着某个工具」时它有待阅读任务，就把该完成时间记为已读，
                // 之后即使切走也不再亮绿（此前只在当前台时抑制，一离开就绿回来）
                let frontApp = NSWorkspace.shared.frontmostApplication
                let frontBundle = frontApp?.bundleIdentifier
                let frontSource = ActivityDetector.sourceName(matching: frontApp?.localizedName, bundleID: frontBundle)
                // Claudian 这类 Obsidian 插件：前台是 Obsidian，需靠 vault 推断
                let claudeInObsidian = ActivityDetector.claudeViewedInObsidian(
                    frontName: frontApp?.localizedName, frontBundle: frontBundle)
                let adjusted = states.map { item -> (String, Int) in
                    guard item.st == 1 else { return (item.name, item.st) }
                    // 上次退出之前就完成的 → 直接视为已读（重启后不会再骗我们「刚完成」）
                    if let prev = self.previousExitAt, let done = item.done, done <= prev {
                        return (item.name, 2)
                    }
                    // WorkBuddy 有自己的真实已读回执，不用我们猜
                    if item.name == "WorkBuddy" {
                        return (item.name, ActivityDetector.sourceBundleIDs[item.name] == frontBundle ? 2 : item.st)
                    }
                    let isFrontHost = frontSource == item.name
                        || (ActivityDetector.sourceBundleIDs[item.name].map { $0 == frontBundle } ?? false)
                        || (item.name == "Claude Code" && claudeInObsidian)
                    guard isFrontHost || item.done != nil else { return (item.name, item.st) }
                    if isFrontHost, let done = item.done {
                        self.markRead(name: item.name, completedAt: done)
                        return (item.name, 2)
                    }
                    if let done = item.done, self.isRead(name: item.name, completedAt: done) {
                        return (item.name, 2)
                    }
                    return (item.name, item.st)
                }
                // 状态没变就不要赋值：@Published 每次赋值都会让坞整树重绘
                var statesChanged = adjusted.count != self.sourceStates.count
                if !statesChanged {
                    for i in adjusted.indices {
                        if adjusted[i].0 != self.sourceStates[i].0
                            || adjusted[i].1 != self.sourceStates[i].1 {
                            statesChanged = true
                            break
                        }
                    }
                }
                let installedChanged = adjusted.map { $0.0 } != self.sourceStates.map { $0.0 }
                if statesChanged { self.sourceStates = adjusted }
                if installedChanged {
                    self.dockController.apply(mode: self.sideDock, model: self, useSaved: true)
                }
            }
        }
    }

    /// 退出时记录时间，供下次启动判断「关机前已完成」
    func noteRunEnd() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastRunEndAt")
    }

    func refresh() {
        if ProcessInfo.processInfo.environment["TOKENMETER_NO_SCAN"] != nil { return }
        guard !scanning else { return }
        dbgRefreshCount += 1
        scanning = true
        startHeartbeat()
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
            // 取走全局引用再改：ScanCache 是结构体（写时复制），
            // 如果 CacheStore 里还留着同一份，扫描过程中任何一次写都会整份复制，
            // 一次扫描的内存峰值直接翻倍（实测 RSS 从 ~110MB 冲到 200MB+）。
            var cache = CacheStore.lock.withLock { () -> ScanCache? in
                let c = CacheStore.cache
                CacheStore.cache = nil
                return c
            } ?? ScanCache.load()
            let t0 = Date()

            /// 把一份 buckets 汇总成七个范围并推到 UI
            func publish(_ buckets: [UsageBucket], statuses: [SourceStatus], partial: Bool) {
                let all: [RangeKind: Summary] = Dictionary(uniqueKeysWithValues: RangeKind.allCases.map { r in
                    (r, Aggregator.summarize(buckets: buckets, range: r, pricing: pricing, statuses: statuses))
                })
                let todayTotal = all[.today]?.counts.total ?? 0
                let fileTotal = statuses.reduce(0) { $0 + $1.files }
                Task { @MainActor in
                    var next = all
                    if partial {
                        // 阶段一只扫了近两天：趋势/逐小时这类「跨天」图表拿到的数据不完整，
                        // 直接推上去会闪一下（30 天柱状图只剩几天、且只剩一个模型的颜色）。
                        // 这里沿用上一轮的完整系列数据，等阶段二算完再整体替换。
                        for (r, var summary) in next {
                            if let prev = self.summariesByRange[r] {
                                // 有上一轮：沿用完整系列数据，避免闪成"只剩一个颜色"
                                summary.trendByTool = prev.trendByTool
                                summary.trendByModel = prev.trendByModel
                                summary.hoursByModel = prev.hoursByModel
                                // 日历热力图用的是「全部历史」序列，阶段一同样不完整，
                                // 不沿用上一轮就会闪成「只有最近几十天有记录」
                                summary.calendarDays = prev.calendarDays
                                summary.calendarByTool = prev.calendarByTool
                                summary.calendarByModel = prev.calendarByModel
                            } else {
                                // 首启无上一轮：宁可空着（显示"暂无数据"）也不要画错的图
                                summary.trendByTool = nil
                                summary.trendByModel = nil
                                summary.hoursByModel = nil
                                summary.calendarDays = nil
                                summary.calendarByTool = nil
                                summary.calendarByModel = nil
                            }
                            next[r] = summary
                        }
                    }
                    self.summariesByRange = next
                    self.loadHarnessIcons()
                    self.lastScan = Date()
                    // 只要这一轮数据是完整的就落盘：
                    // 「数据无变化」走的是 partial 分支（跳过了阶段二），但内容其实完整，
                    // 只在 !partial 时保存会导致缓存长期写不进去。
                    // 落盘节流：完整结果体积约 1.3MB，每 60 秒刷一次没必要；
                    // 首次（启动后第一轮）立即写，之后最多每 3 分钟写一次。
                    let nowTs = Date()
                    let dueForSave = self.lastSummarySaveAt.map { nowTs.timeIntervalSince($0) > 180 } ?? true
                    if dueForSave, !partial || next.values.allSatisfy({ $0.calendarDays != nil }) {
                        SummaryCache.save(next, at: nowTs)
                        self.lastSummarySaveAt = nowTs
                    }
                    if !partial {
                        self.lastFileTotal = fileTotal
                        self.updateRate(todayTotal: todayTotal, at: Date())
                    }
                }
            }

            // ── 阶段一：先扫最近 2 天改动过的文件，几秒内出「今天/昨天」────────────────
            // cache.dirty 只在「真的解析/更新了某个文件」时被置位，
            // 因此可以用它判断本次是否完全没有变化。
            cache.dirty = false
            let recentCutoff = Calendar.current.date(byAdding: .day, value: -2, to: Date())
            let quick = Aggregator.scan(cache: &cache, progress: nil, recentOnlySince: recentCutoff)
            let nothingChanged = !cache.dirty

            // 没有任何文件变化 + 已经发布过数据 + 上次全量扫描在 10 分钟内
            // → 直接沿用现有结果，跳过阶段二（每次省约 0.7s CPU，且不触发整树重绘）
            if nothingChanged, await MainActor.run(body: { self.hasPublishedData }),
               await MainActor.run(body: { self.lastFullScanAt.map { Date().timeIntervalSince($0) < 600 } ?? false }) {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.scanning = false
                    self.scanStartedAt = nil
                    self.scanProgress = nil
                    self.lastScan = Date()
                }
                if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("DBG skip: nothing changed\n".utf8))
                }
                return
            }

            if !quick.buckets.isEmpty {
                publish(quick.buckets, statuses: quick.statuses, partial: true)
            }

            // ── 阶段二：全量补齐历史（阶段一已解析的文件命中缓存，几乎零开销）──────────
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "DBG phase1 %.1fs buckets=%d\n",
                    Date().timeIntervalSince(t0), quick.buckets.count).utf8))
            }
            let scanned = Aggregator.scan(cache: &cache, progress: progress)
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "DBG phase2 %.1fs files=%d\n",
                    Date().timeIntervalSince(t0), scanned.statuses.reduce(0) { $0 + $1.files }).utf8))
            }
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
            // 扫描会把分桶缓存撑到上百 MB；释放后主动把空闲页还给系统，
            // 否则 malloc 会留着一大块不交回（RSS 长期偏高）。
            malloc_zone_pressure_relief(nil, 0)
            let todayTotal = all[.today]?.counts.total ?? 0
            let fileTotal = scanned.statuses.reduce(0) { $0 + $1.files }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.summariesByRange = all
                self.lastBuckets = scanned.buckets
                self.lastPricing = pricing
                self.loadHarnessIcons()
                self.lastScan = Date()
                self.scanning = false
                self.scanStartedAt = nil
                self.scanProgress = nil
                self.lastFileTotal = fileTotal
                self.updateRate(todayTotal: todayTotal, at: Date())
                self.evaluateBudget()
                self.hasPublishedData = true
                self.lastFullScanAt = Date()
                self.dataIssues = DataCheck.run(buckets: scanned.buckets, statuses: scanned.statuses)
                    + DataCheck.pricingIssues(buckets: scanned.buckets, pricing: pricing)
            }
        }
    }
}

#endif
