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

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func setRange(_ r: RangeKind) {
        guard r != range else { return }
        range = r
        refresh()
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

    var body: some View {
        HStack(spacing: 4) {
            if let img = Self.barIcon {
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
