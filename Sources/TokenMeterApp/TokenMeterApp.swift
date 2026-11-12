#if os(macOS)
import SwiftUI
import AppKit
import ServiceManagement
@preconcurrency import TokenMeterCore

/// 应用入口：NSStatusItem 承载菜单栏图标（左键面板 / 右键菜单）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        PricingTable.writeTemplateIfMissing()
        let model = AppModel()
        self.model = model
        statusBar = StatusBarController(model: model, actions: AppActions.shared)
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
    @Published var dataIssues: [DataIssue] = []
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

    /// 燃烧状态的彩色火苗帧，三档：平稳 / 微旺 / 旺盛
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

    /// 档位阈值：≥4K 微旺，≥15K 旺盛，≥40K 爆燃
    static let warmRateThreshold: Int64 = 4_000
    static let intenseRateThreshold: Int64 = 15_000
    static let infernoRateThreshold: Int64 = 40_000

    enum FlameTier { case calm, warm, hot, inferno }

    var flameTier: FlameTier {
        let rate = burnRate ?? 0
        if rate >= Self.infernoRateThreshold { return .inferno }
        if rate >= Self.intenseRateThreshold { return .hot }
        if rate >= Self.warmRateThreshold { return .warm }
        return .calm
    }

    /// 火苗点尺寸随速率连续变化（12 → 22pt，对数压缩让低速也有变化）
    var flamePointSize: CGFloat {
        let rate = Double(burnRate ?? 0)
        guard rate > 0 else { return 12 }
        let t = min(1.0, pow(rate / 60_000.0, 0.45))
        // 15K → 40K 之间把「爆燃加成」线性引入（0 → 2pt），
        // 这样跨档瞬间尺寸连续，不会突然弹一下；仅形状切换。
        let ramp = min(1.0, max(0.0, (rate - Double(Self.intenseRateThreshold))
                                       / (Double(Self.infernoRateThreshold) - Double(Self.intenseRateThreshold))))
        return 12 + 10 * t + 2 * CGFloat(ramp)
    }

    var currentFlameFrames: [NSImage] {
        switch flameTier {
        case .inferno:
            let big = flamePointSize >= 18
            let set = big && !Self.flameFramesInfernoBig.isEmpty ? Self.flameFramesInfernoBig : Self.flameFramesInferno
            return set.isEmpty ? Self.flameFramesIntense : set
        case .hot:
            let big = flamePointSize >= 18
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
        // 单一 UI 心跳：仅在「燃烧中」或「扫描中」运行，空闲时彻底停止
        startHeartbeat()
    }

    /// 按需启动心跳（有燃烧或扫描时才需要逐帧刷新）
    func startHeartbeat() {
        guard flameTimer == nil else { return }
        flameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flameTick += 1

                if self.scanning, let p = self.scanProgress, self.flameTick % 3 == 0 {
                    self.scanFraction = p.fraction
                    self.scanDone = p.done
                    self.scanTotal = p.total
                }

                if !self.isBurning && !self.scanning {
                    self.stopHeartbeat()      // 空闲：停掉定时器，让系统可以休眠
                    return
                }
                guard self.isBurning, !self.currentFlameFrames.isEmpty else { return }
                // 档位越高帧率越高：爆燃最"急"
                let fps: Int
                switch self.flameTier {
                case .inferno: fps = 18
                case .hot: fps = 15
                default: fps = 12
                }
                let step = max(1, Int((10.0 / Double(fps)).rounded()))
                guard self.flameTick % step == 0 else { return }
                self.flame.advance(count: self.currentFlameFrames.count)
            }
        }
        flameTimer?.tolerance = 0.02
        if let t = flameTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopHeartbeat() {
        flameTimer?.invalidate()
        flameTimer = nil
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
        Task.detached(priority: .utility) { [weak self] in
            // 单次合并遍历：各源最后活动 + 顶层活动
            let snapshot = ActivityDetector.activitySnapshot()
            let now = Date()
            // 精确状态信号（放在后台线程，避免阻塞 UI）
            let dshRunning = DshSource.isTaskRunning()
            let codexTurn = ActivityDetector.codexTurnState(now: now)
            let wbState = ActivityDetector.workBuddyState(now: now)
            let claudeHook = ActivityDetector.claudeHookState(now: now)
            let claudeRunning = ActivityDetector.claudeTaskRunning(now: now)

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
                let installedChanged = adjusted.map { $0.0 } != self.sourceStates.map { $0.0 }
                self.sourceStates = adjusted
                if installedChanged {
                    self.dockController.apply(mode: self.sideDock, model: self, useSaved: true)
                }
            }
        }
    }

    func refresh() {
        guard !scanning else { return }
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
            var cache = CacheStore.lock.withLock { CacheStore.cache } ?? ScanCache.load()
            let t0 = Date()

            /// 把一份 buckets 汇总成七个范围并推到 UI
            func publish(_ buckets: [UsageBucket], statuses: [SourceStatus], partial: Bool) {
                let all: [RangeKind: Summary] = Dictionary(uniqueKeysWithValues: RangeKind.allCases.map { r in
                    (r, Aggregator.summarize(buckets: buckets, range: r, pricing: pricing, statuses: statuses))
                })
                let todayTotal = all[.today]?.counts.total ?? 0
                let fileTotal = statuses.reduce(0) { $0 + $1.files }
                Task { @MainActor in
                    self.summariesByRange = all
                    self.loadHarnessIcons()
                    self.lastScan = Date()
                    if !partial {
                        self.lastFileTotal = fileTotal
                        self.updateRate(todayTotal: todayTotal, at: Date())
                    }
                }
            }

            // ── 阶段一：先扫最近 2 天改动过的文件，几秒内出「今天/昨天」────────────────
            let recentCutoff = Calendar.current.date(byAdding: .day, value: -2, to: Date())
            let quick = Aggregator.scan(cache: &cache, progress: nil, recentOnlySince: recentCutoff)
            if !quick.buckets.isEmpty {
                publish(quick.buckets, statuses: quick.statuses, partial: true)
            }

            // ── 阶段二：全量补齐历史（阶段一已解析的文件命中缓存，几乎零开销）──────────
            if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "DBG phase1 %.1fs buckets=%d\n",
                    Date().timeIntervalSince(t0), quick.buckets.count).utf8))
            }
            let scanned = Aggregator.scan(cache: &cache, progress: progress)
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
                self.dataIssues = DataCheck.run(buckets: scanned.buckets, statuses: scanned.statuses)
                    + DataCheck.pricingIssues(buckets: scanned.buckets, pricing: pricing)
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


#endif
