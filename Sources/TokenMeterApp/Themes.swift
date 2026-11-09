#if os(macOS)
import SwiftUI

/// 主题色（Accent）：影响总览卡片底色、工具/模型条形配色、每日用量图
struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let primary: Color
    let palette: [Color]

    var cardTint: Color { primary.opacity(0.12) }

    static let all: [AppTheme] = [
        AppTheme(id: "teal", name: "青", primary: .teal,
                 palette: [.teal, .blue, .orange, .purple, .pink, .mint, .yellow, .indigo]),
        AppTheme(id: "blue", name: "蓝", primary: .blue,
                 palette: [.blue, .cyan, .indigo, .teal, .purple, .mint, .orange, .pink]),
        AppTheme(id: "purple", name: "紫", primary: .purple,
                 palette: [.purple, .indigo, .pink, .blue, .teal, .orange, .mint, .yellow]),
        AppTheme(id: "green", name: "绿", primary: .green,
                 palette: [.green, .mint, .teal, .blue, .yellow, .orange, .pink, .indigo]),
        AppTheme(id: "orange", name: "橙", primary: .orange,
                 palette: [.orange, .yellow, .red, .pink, .purple, .blue, .teal, .mint]),
        AppTheme(id: "pink", name: "粉", primary: .pink,
                 palette: [.pink, .purple, .red, .orange, .yellow, .indigo, .blue, .teal]),
    ]

    static func theme(for id: String) -> AppTheme {
        all.first { $0.id == id } ?? all[0]
    }
}
#endif
