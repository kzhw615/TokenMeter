#!/usr/bin/env python3
"""生成 TokenMeter 应用图标 (.icns) 与菜单栏模板图标。纯 Pillow 绘制，无外部素材。"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOTAL = 16
ASSETS = os.path.join(ROOT, "Assets")
os.makedirs(ASSETS, exist_ok=True)

S = 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def master_icon() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 圆角方形底板（macOS 超级椭圆近似）
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, S - 1, S - 1], radius=232, fill=255)

    # 垂直渐变背景：深绿 -> 近黑
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    top, bottom = (26, 84, 66), (9, 20, 16)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S) + (255,))

    # 顶部柔光
    glow = Image.new("L", (S, S), 0)
    gld = ImageDraw.Draw(glow)
    gld.ellipse([512 - 520, -320, 512 + 520, 720], fill=46)
    glow = glow.filter(ImageFilter.GaussianBlur(180))
    white = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    white.putalpha(glow)
    base = Image.alpha_composite(grad, white)

    d = ImageDraw.Draw(base)

    # 仪表弧：270° 扫掠，缺口朝下，沿弧渐变
    cx, cy, r, w = 512, 540, 292, 92
    c0, c1 = (20, 184, 166), (167, 243, 208)  # teal -> mint
    steps = 240
    for i in range(steps):
        a0 = 135 + 270 * i / steps
        a1 = 135 + 270 * (i + 1.6) / steps
        col = lerp(c0, c1, i / steps) + (255,)
        d.arc([cx - r, cy - r, cx + r, cy + r], start=a0, end=a1, fill=col, width=w)
    # 圆头端点
    for ang, col in ((135, c0), (45, c1)):
        rad = math.radians(ang)
        ex, ey = cx + r * math.cos(rad), cy + r * math.sin(rad)
        d.ellipse([ex - w / 2, ey - w / 2, ex + w / 2, ey + w / 2], fill=col + (255,))

    # 内部三根用量柱（越右越高越亮），完全落在圆环内圈里
    bar_w, gap, bottom = 92, 54, 716
    heights = [168, 248, 328]
    cols = [(125, 224, 190), (169, 238, 211), (228, 251, 241)]
    x0 = 512 - (3 * bar_w + 2 * gap) / 2
    for i, (h, c) in enumerate(zip(heights, cols)):
        x = x0 + i * (bar_w + gap)
        d.rounded_rectangle([x, bottom - h, x + bar_w, bottom], radius=46, fill=c + (255,))

    # 套圆角掩膜
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out


def menubar_glyph(px: int) -> Image.Image:
    """六边形 + 三根镂空柱的单色模板图（alpha 决定形状）"""
    img = Image.new("L", (px, px), 0)
    d = ImageDraw.Draw(img)
    c = px / 2
    r = px * 0.46
    pts = []
    for k in range(6):
        ang = math.radians(90 + k * 60)
        pts.append((c + r * math.cos(ang), c - r * math.sin(ang)))
    d.polygon(pts, fill=255)
    # 镂空柱
    bw, gap = px * 0.115, px * 0.075
    bottom = c + px * 0.24
    heights = [px * 0.20, px * 0.30, px * 0.40]
    x0 = c - (3 * bw + 2 * gap) / 2
    for i, h in enumerate(heights):
        x = x0 + i * (bw + gap)
        d.rounded_rectangle([x, bottom - h, x + bw, bottom], radius=px * 0.045, fill=0)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 255))
    out.putalpha(img)
    return out


def menubar_flame(px: int, frame: int = 0, total: int = 16) -> Image.Image:
    """彩色火苗（非模板图）：橙红渐变外焰 + 黄色内焰；frame 决定摆动相位"""
    import math
    s = px
    phase = 2 * math.pi * frame / total
    sway = math.sin(phase) * s * 0.06          # 焰尖左右摆
    breathe = 0.92 + 0.12 * math.sin(phase + math.pi / 2)  # 内焰呼吸
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    # 外焰轮廓：底圆 + 中圆 + 尖角（尖部随相位摆动）
    d.ellipse([s * 0.16, s * 0.34, s * 0.84, s * 0.98], fill=255)
    d.ellipse([s * 0.27 + sway * 0.4, s * 0.24, s * 0.73 + sway * 0.4, s * 0.70], fill=255)
    d.polygon([(s * 0.5 + sway, s * 0.02), (s * 0.32, s * 0.46), (s * 0.68, s * 0.46)], fill=255)
    # 外焰垂直渐变：尖部橙黄 -> 底部红橙（相位移一点色温）
    warm = 0.5 + 0.5 * math.sin(phase)
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    top = lerp((255, 159, 10), (255, 120, 0), warm)
    bottom = (255, 69, 58)
    for y in range(s):
        gd.line([(0, y), (s, y)], fill=lerp(top, bottom, y / s) + (255,))
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    # 内焰：黄色小火苗（高度随呼吸变化）
    ih = 0.36 * breathe
    inner = Image.new("L", (s, s), 0)
    idr = ImageDraw.Draw(inner)
    idr.ellipse([s * 0.34, s * (0.92 - ih * 0.8), s * 0.66, s * 0.92], fill=255)
    idr.polygon([(s * 0.5 + sway * 0.3, s * (0.92 - ih - 0.10)), (s * 0.38, s * (0.92 - ih * 0.5)), (s * 0.62, s * (0.92 - ih * 0.5))], fill=255)
    yellow = Image.new("RGBA", (s, s), (255, 224, 92, 255))
    out = Image.alpha_composite(out, Image.composite(yellow, Image.new("RGBA", (s, s), (0, 0, 0, 0)), inner))
    return out


def menubar_flame_intense(px: int, frame: int = 0, total: int = 16) -> Image.Image:
    """旺盛版火苗：更大轮廓 + 侧舌 + 白热内芯 + 飞溅火星；摆幅与帧率由 App 侧配合"""
    import math
    s = px
    phase = 2 * math.pi * frame / total
    sway = math.sin(phase) * s * 0.10
    sway2 = math.sin(phase + 1.3) * s * 0.06
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    # 主焰：更饱满
    d.ellipse([s * 0.10, s * 0.30, s * 0.90, s * 0.99], fill=255)
    d.ellipse([s * 0.22 + sway * 0.5, s * 0.16, s * 0.78 + sway * 0.5, s * 0.66], fill=255)
    d.polygon([(s * 0.5 + sway, 0), (s * 0.28, s * 0.42), (s * 0.72, s * 0.42)], fill=255)
    # 左右侧舌（相位错开，形成舔动）
    d.polygon([(s * 0.16, s * 0.60), (s * 0.05 + sway2, s * 0.36), (s * 0.26, s * 0.46)], fill=255)
    d.polygon([(s * 0.84, s * 0.60), (s * 0.95 - sway2, s * 0.36), (s * 0.74, s * 0.46)], fill=255)
    # 三段渐变：白黄尖 -> 橙 -> 红底
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    c0, c1, c2 = (255, 224, 92), (255, 120, 0), (255, 59, 48)
    for y in range(s):
        t = y / s
        col = lerp(c0, c1, min(1.0, t * 1.8)) if t < 0.55 else lerp(c1, c2, (t - 0.55) / 0.45)
        gd.line([(0, y), (s, y)], fill=col + (255,))
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    # 白热内芯
    core = Image.new("L", (s, s), 0)
    cd = ImageDraw.Draw(core)
    cd.ellipse([s * 0.34, s * 0.50, s * 0.66, s * 0.93], fill=255)
    cd.polygon([(s * 0.5 + sway * 0.4, s * 0.30), (s * 0.38, s * 0.62), (s * 0.62, s * 0.62)], fill=255)
    hot = Image.new("RGBA", (s, s), (255, 244, 180, 255))
    out = Image.alpha_composite(out, Image.composite(hot, Image.new("RGBA", (s, s), (0, 0, 0, 0)), core))
    inner = Image.new("L", (s, s), 0)
    ImageDraw.Draw(inner).ellipse([s * 0.42, s * 0.66, s * 0.58, s * 0.90], fill=255)
    white = Image.new("RGBA", (s, s), (255, 255, 235, 255))
    out = Image.alpha_composite(out, Image.composite(white, Image.new("RGBA", (s, s), (0, 0, 0, 0)), inner))
    # 飞溅火星
    sparks = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sparks)
    p1 = (s * (0.5 + sway / s + 0.16 * math.sin(phase * 2)), s * (0.10 + 0.05 * math.cos(phase * 3)))
    p2 = (s * (0.5 + sway / s - 0.20 * math.cos(phase * 2)), s * (0.20 + 0.06 * math.sin(phase * 2 + 1)))
    for (cx, cy), r in ((p1, s * 0.035), (p2, s * 0.025)):
        sd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 200, 60, 220))
    return Image.alpha_composite(out, sparks)


def main():
    master = master_icon()
    master.save(os.path.join(ASSETS, "icon-1024.png"))

    iconset = os.path.join(ASSETS, "TokenMeter.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for name, size in specs:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
    icns = os.path.join(ASSETS, "TokenMeter.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("wrote", icns)

    menubar_glyph(88).save(os.path.join(ASSETS, "menubar_icon@2x.png"))
    menubar_glyph(44).save(os.path.join(ASSETS, "menubar_icon.png"))
    for i in range(TOTAL):
        menubar_flame(88, i, TOTAL).save(os.path.join(ASSETS, f"menubar_flame_{i}@2x.png"))
        menubar_flame_intense(88, i, TOTAL).save(os.path.join(ASSETS, f"menubar_flame_hot_{i}@2x.png"))
        # 更大尺寸档（高速率时放大显示）
        menubar_flame(112, i, TOTAL).save(os.path.join(ASSETS, f"menubar_flame_big_{i}@2x.png"))
        menubar_flame_intense(112, i, TOTAL).save(os.path.join(ASSETS, f"menubar_flame_hot_big_{i}@2x.png"))
    menubar_flame(88, 0).save(os.path.join(ASSETS, "menubar_flame@2x.png"))
    print(f"wrote menubar icons + {TOTAL} calm + {TOTAL} intense frames (+big variants)")

    master.resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, ".research", "icon-preview.png"))
    print("preview:", os.path.join(ROOT, ".research", "icon-preview.png"))


if __name__ == "__main__":
    sys.exit(main())
