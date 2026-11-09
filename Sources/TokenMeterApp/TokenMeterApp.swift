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

@MainActor
final class AppModel: ObservableObject {
    @Published var summary: Summary?
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
    @Published var updateMessage: String?

    /// 正在燃烧的 harness（日志近 2 分钟有写入）
    @Published var burningSources: [String] = []
    var isBurning: Bool { !burningSources.isEmpty }

    func setRange(_ r: RangeKind) {
        guard r != range else { return }
        range = r
        refresh()
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
        let currentRange = range
        Task.detached(priority: .utility) {
            var cache = ScanCache.load()
            let scanned = Aggregator.scan(cache: &cache)
            cache.save()
            let pricing = PricingTable.load()
            let summary = Aggregator.summarize(buckets: scanned.buckets, range: currentRange, pricing: pricing, statuses: scanned.statuses)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.summary = summary
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
