#if os(macOS)
import AppKit

// 纯 AppKit 入口：避免 SwiftUI 的 Settings/WindowGroup scene 自建空窗口
@MainActor
func runTokenMeterApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

MainActor.assumeIsolated {
    runTokenMeterApp()
}
#else
import Foundation

print("TokenMeter 菜单栏应用仅支持 macOS；本平台请使用 tokenmeter CLI。")
#endif
