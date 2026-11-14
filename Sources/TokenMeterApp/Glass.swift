#if os(macOS)
import SwiftUI

/// 液态玻璃底：半透明材质 + 顶部高光 + 虹彩描边 + 泛光投影。
/// 部署目标是 macOS 14（没有系统级 Liquid Glass API），这里用材质叠层近似同一观感。
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .clear

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.04), .white.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom)
                )
                .blendMode(.plusLighter)
                .opacity(0.5)
            )
            .overlay(
                shape.fill(LinearGradient(colors: [tint.opacity(0.16), .clear],
                                          startPoint: .top, endPoint: .bottom))
            )
            // 虹彩边缘：模拟玻璃折射出的彩色细线
            .overlay(
                shape.strokeBorder(
                    AngularGradient(
                        colors: [.white.opacity(0.50), .cyan.opacity(0.28), .white.opacity(0.16),
                                 .purple.opacity(0.24), .white.opacity(0.46)],
                        center: .center),
                    lineWidth: 0.8)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.50), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.26), radius: 14, y: 5)
            .shadow(color: tint.opacity(0.22), radius: 20)
    }
}

extension View {
    /// 面板/卡片的玻璃底
    func glassBackground(cornerRadius: CGFloat = 18, tint: Color = .clear) -> some View {
        background(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                tint: tint))
    }
}
#endif
