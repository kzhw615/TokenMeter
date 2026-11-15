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

    /// 高区分度色板：用于模型/项目等数量不定的系列。
    /// 手挑而非色相轮转——轮转出来的相邻色（如 79° 与 131°）在深色背景上容易看成一类。
    static let distinct: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 1.00),   // 蓝
        Color(red: 1.00, green: 0.65, blue: 0.24),   // 橙
        Color(red: 0.22, green: 0.83, blue: 0.63),   // 薄荷
        Color(red: 1.00, green: 0.42, blue: 0.62),   // 玫红
        Color(red: 0.71, green: 0.48, blue: 1.00),   // 紫
        Color(red: 1.00, green: 0.85, blue: 0.24),   // 黄
        Color(red: 0.30, green: 0.82, blue: 0.88),   // 青
        Color(red: 1.00, green: 0.48, blue: 0.36),   // 珊瑚
        Color(red: 0.49, green: 0.88, blue: 0.49),   // 草绿
        Color(red: 0.78, green: 0.57, blue: 0.92),   // 薰衣草
        Color(red: 0.94, green: 0.38, blue: 0.57),   // 玫瑰
        Color(red: 0.38, green: 0.71, blue: 0.96),   // 天蓝
        Color(red: 1.00, green: 0.72, blue: 0.30),   // 琥珀
        Color(red: 0.30, green: 0.75, blue: 0.70),   // 蓝绿
        Color(red: 0.58, green: 0.46, blue: 0.85),   // 靛紫
        Color(red: 0.68, green: 0.84, blue: 0.50),   // 黄绿
        Color(red: 0.96, green: 0.56, blue: 0.70),   // 浅粉
        Color(red: 0.51, green: 0.83, blue: 0.98),   // 浅天蓝
    ]

    static func theme(for id: String) -> AppTheme {
        all.first { $0.id == id } ?? all[0]
    }
}
#endif
