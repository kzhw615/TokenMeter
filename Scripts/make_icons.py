#!/usr/bin/env python3
"""生成 TokenMeter 应用图标 (.icns) 与菜单栏模板图标。纯 Pillow 绘制，无外部素材。"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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


def menubar_flame(px: int) -> Image.Image:
    """彩色火苗（非模板图）：橙红渐变外焰 + 黄色内焰"""
    s = px
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    # 外焰轮廓：底圆 + 中圆 + 尖角
    d.ellipse([s * 0.16, s * 0.34, s * 0.84, s * 0.98], fill=255)
    d.ellipse([s * 0.27, s * 0.24, s * 0.73, s * 0.70], fill=255)
    d.polygon([(s * 0.5, s * 0.02), (s * 0.32, s * 0.46), (s * 0.68, s * 0.46)], fill=255)
    # 外焰垂直渐变：尖部橙黄 -> 底部红橙
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    top, bottom = (255, 159, 10), (255, 69, 58)
    for y in range(s):
        gd.line([(0, y), (s, y)], fill=lerp(top, bottom, y / s) + (255,))
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    # 内焰：黄色小火苗
    inner = Image.new("L", (s, s), 0)
    idr = ImageDraw.Draw(inner)
    idr.ellipse([s * 0.34, s * 0.56, s * 0.66, s * 0.92], fill=255)
    idr.polygon([(s * 0.5, s * 0.40), (s * 0.38, s * 0.68), (s * 0.62, s * 0.68)], fill=255)
    yellow = Image.new("RGBA", (s, s), (255, 224, 92, 255))
    out = Image.alpha_composite(out, Image.composite(yellow, Image.new("RGBA", (s, s), (0, 0, 0, 0)), inner))
    return out


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
    menubar_flame(88).save(os.path.join(ASSETS, "menubar_flame@2x.png"))
    menubar_flame(44).save(os.path.join(ASSETS, "menubar_flame.png"))
    print("wrote menubar icons")

    master.resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, ".research", "icon-preview.png"))
    print("preview:", os.path.join(ROOT, ".research", "icon-preview.png"))


if __name__ == "__main__":
    sys.exit(main())
