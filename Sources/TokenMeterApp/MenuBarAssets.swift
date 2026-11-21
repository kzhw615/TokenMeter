#if os(macOS)
import AppKit

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
