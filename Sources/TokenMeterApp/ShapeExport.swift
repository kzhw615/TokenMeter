#if os(macOS)
import SwiftUI
import AppKit

/// 调试用：把悬浮坞外形单独渲染成 PNG，便于精确测量四个圆角（不依赖截图和壁纸颜色）。
/// 用法：TOKENMETER_EXPORT_DOCK=/tmp/dock.png open -a TokenMeter
@available(macOS 13.0, *)
@MainActor
enum ShapeExport {
    static func exportIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["TOKENMETER_EXPORT_DOCK"] else { return false }
        let w: CGFloat = 200, h: CGFloat = 600
        let view = ZStack {
            Color.white
            BarFlareShape(side: "right",
                          fuse: CGFloat(Double(ProcessInfo.processInfo.environment["TOKENMETER_DOCK_FUSE"] ?? "1") ?? 1),
                          bottomInset: 28, radius: 26,
                          flareRadius: CGFloat(Double(ProcessInfo.processInfo.environment["TOKENMETER_FLARE"] ?? "16") ?? 16))
                .fill(Color.black)
        }
        .frame(width: w, height: h)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("DBG dock shape exported to \(path)\n".utf8))
        }
        return true
    }
}
#endif
