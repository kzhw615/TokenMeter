import SwiftUI
import AppKit
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
    /// 统计口径：true = 含缓存（input+output+cacheRead+cacheWrite），false = 不含缓存（input+output）
    @Published var includeCache: Bool = UserDefaults.standard.object(forKey: "includeCache") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeCache, forKey: "includeCache") }
    }
    /// 主题色（Accent）
    @Published var themeID: String = UserDefaults.standard.string(forKey: "themeID") ?? "teal" {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    var theme: AppTheme { AppTheme.theme(for: themeID) }

    /// 更新检查状态
    @Published var latestVersion: String?
    @Published var releaseURL: URL?

    /// 正在燃烧的 harness（日志近 2 分钟有写入）
    @Published var burningSources: [String] = []
    var isBurning: Bool { !burningSources.isEmpty }

    func setRange(_ r: RangeKind) {
        guard r != range else { return }
        range = r   //  summariesByRange 已预计算，直接查表，无需重扫
    }

    /// 燃烧状态的彩色火苗帧（8fps 切换形成跳动动画）
    static let flameFrames: [NSImage] = (0..<6).compactMap { i in
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar_flame_\(i)@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = false
        return img
    }
    @Published var flameFrame: Int = 0

    private var timer: Timer?
    private var activityTimer: Timer?
    private var flameTimer: Timer?

    init() {
        refresh()
        checkForUpdates()
        pollActivity()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollActivity() }
        }
        flameTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isBurning, !Self.flameFrames.isEmpty else { return }
                self.flameFrame = (self.flameFrame + 1) % Self.flameFrames.count
            }
        }
    }

    func pollActivity() {
        Task.detached(priority: .utility) { [weak self] in
            let active = ActivityDetector.activeSources()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if active != self.burningSources { self.burningSources = active }
            }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
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
                self.lastScan = Date()
                self.scanning = false
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
                if !AppModel.flameFrames.isEmpty {
                    Image(nsImage: AppModel.flameFrames[model.flameFrame % AppModel.flameFrames.count])
                } else if let flame = Self.flameIcon {
                    Image(nsImage: flame)
                } else {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
            } else if let img = Self.barIcon {
                Image(nsImage: img)
            } else {
                Image(systemName: "circle.hexagongrid.fill")
            }
            if let s = model.summary, s.counts.total > 0 {
                let shown = model.includeCache ? s.counts.total : s.counts.input + s.counts.output
                Text("\(Fmt.compactTokens(shown)) · \(Fmt.cost(s.cost))")
                    .monospacedDigit()
            } else if model.scanning {
                Text("…")
            } else {
                Text("0")
            }
        }
    }
}
