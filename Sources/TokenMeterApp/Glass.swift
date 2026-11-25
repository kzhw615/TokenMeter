#if os(macOS)
import SwiftUI

/// 液态玻璃底（深色）：半透明材质 + 冷色渐变 + 顶部高光 + 虹彩描边 + 泛光投影。
/// 部署目标是 macOS 14（没有系统级 Liquid Glass API），用材质叠层近似。
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .cyan

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            // 压暗：日间模式下 ultraThinMaterial 会偏白，这里统一压成深色玻璃
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.58),
                                 Color(red: 0.03, green: 0.04, blue: 0.07).opacity(0.74)],
                        startPoint: .top, endPoint: .bottom))
            )
            // 冷色调：左上偏青、右下偏紫，模仿玻璃折射的环境色
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [tint.opacity(0.20), .clear,
                                 Color(red: 0.45, green: 0.25, blue: 0.85).opacity(0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            // 顶部镜面高光
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.04), .clear],
                        startPoint: .top, endPoint: .center))
            )
            // 斜向光泽：让玻璃表面有"受光面"而不只是一块色板
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            // 虹彩边缘：青 → 白 → 紫的细描边
            .overlay(
                shape.strokeBorder(
                    AngularGradient(
                        colors: [.white.opacity(0.70), .cyan.opacity(0.60), .white.opacity(0.30),
                                 .purple.opacity(0.60), .white.opacity(0.70)],
                        center: .center),
                    lineWidth: 1)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
            .shadow(color: tint.opacity(0.18), radius: 26)
    }
}

extension View {
    /// 真·液态玻璃：macOS 26+ 用系统 glassEffect，旧系统退回自绘材质叠层
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 22, tint: Color = .clear, opacity: Double = 0.45) -> some View {
        if opacity <= 0 {
            self
        } else if #available(macOS 26.0, *) {
            GlassPanel(opacity: opacity, tint: tint, cornerRadius: cornerRadius, content: self)
        } else {
            glassBackground(cornerRadius: cornerRadius, tint: tint)
        }
    }

    /// 面板/卡片的玻璃底
    func glassBackground(cornerRadius: CGFloat = 18, tint: Color = .cyan) -> some View {
        background(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                tint: tint))
    }

    /// 卡片级玻璃（更薄）
    func glassCard(cornerRadius: CGFloat = 12, tint: Color = .cyan) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.8))
        )
    }
}

/// 真正的液态玻璃面板：底色跟随明暗外观，玻璃层提供边缘折射。
/// - 浅色外观 → 亮底（白），深色外观 → 暗底（近黑），两者不再糊成一片灰
/// - 底色本身给足不透明度，背后文字透不过来；玻璃层只负责质感
@available(macOS 26.0, *)
private struct GlassPanel<V: View>: View {
    let opacity: Double
    let tint: Color
    let cornerRadius: CGFloat
    let content: V
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        let dark = scheme == .dark
        // 不透明度由用户滑块控制；玻璃层始终用 .regular（带模糊），
        // 这样即使拉到很透，背后内容也是糊的，不会把文字叠在数字上
        let v = min(max(opacity, 0), 1)
        // 不再自己铺一层白色（那正是"磨砂贴纸"的来源）。
        // 直接用系统玻璃，滑块控制它的 tint 强度：
        //   v 接近 0 时保留一条细边
        //   v=1  厚实的着色玻璃（接近实体）
        let tintColor = dark
            ? Color(red: 0.10, green: 0.11, blue: 0.14)
            : Color(red: 0.98, green: 0.98, blue: 1.00)
        let effect: Glass = .regular.tint(tintColor.opacity(0.85 * v))

        // 玻璃放在背景层：不能用 glassEffect 包住内容，否则它会把鼠标事件吃掉
        // （表现为面板无法滚动、tab 点不动）
        let _ = (ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil)
            ? FileHandle.standardError.write(Data("DBG glass panel opacity=\(opacity) dark=\(dark)\n".utf8))
            : ()
        return content
            .background {
                if v < 0.04 {
                    shape.strokeBorder(Color.primary.opacity(3 * v), lineWidth: 1)
                } else {
                    ZStack {
                    shape.fill(.clear).glassEffect(effect, in: shape)
                    shape.fill(
                        LinearGradient(colors: [tint.opacity(dark ? 0.10 : 0.05), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                    shape.strokeBorder(
                        LinearGradient(
                            colors: dark
                                ? [.white.opacity(0.45), .white.opacity(0.10), .white.opacity(0.25)]
                                : [.white.opacity(0.85), .white.opacity(0.35), .black.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.2)
                    }
                    .clipShape(shape)
                }
            }
    }
}

#endif

#if os(macOS)
/// 真正的系统液态玻璃背景（AppKit 层）。
/// SwiftUI 的 .glassEffect 在自定义 Shape 上的表现和系统组件不一致（缺边缘折射），
/// 这里直接用 NSGlassEffectView，拿到的就是系统级 Liquid Glass。
struct GlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tint: NSColor?
    /// true = 系统「清澈玻璃」（更透、折射更强），false = 标准磨砂玻璃
    var clearStyle: Bool = false

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let v = NSGlassEffectView()
            v.style = clearStyle ? .clear : .regular
            v.cornerRadius = cornerRadius
            v.tintColor = tint
            return v
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if #available(macOS 26.0, *), let g = v as? NSGlassEffectView {
            g.cornerRadius = cornerRadius
            g.tintColor = tint
            g.style = clearStyle ? .clear : .regular
            return
        }
        if let e = v as? NSVisualEffectView {
            e.layer?.cornerRadius = cornerRadius
        }
    }
}
#endif
