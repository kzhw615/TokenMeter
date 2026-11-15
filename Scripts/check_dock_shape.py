#!/usr/bin/env python3
"""检查悬浮坞外形：上下喇叭口是否对称、是否被窗口裁切。

用法：先截图到 /tmp/dock.png（screencapture -x /tmp/dock.png），再运行本脚本。
之前的 bug（底部内缩 10 < 喇叭口半径 26）就是靠这个测出来的：形状在底边还剩
十几像素宽就结束，说明下喇叭口被窗口裁掉了。
"""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dock.png"
im = Image.open(path).convert("RGB")
w, h = im.size
crop = im.crop((w - 260, int(h * 0.10), w, int(h * 0.78)))
W, H = crop.size
px = crop.load()

rows = []
for y in range(H):
    xs = [x for x in range(W) if sum(px[x, y]) < 180]
    if xs:
        rows.append((y, min(xs), max(xs)))

if not rows:
    sys.exit("未找到坞形状（面板/坞可能没显示）")

top, bot = rows[0][0], rows[-1][0]
print(f"形状高度: {bot - top + 1}px")

head = [(y - top, a) for y, a, _ in rows[:30]]
tail = [(y - bot, a) for y, a, _ in rows[-30:]][::-1]
top_w = rows[0][2] - rows[0][1] + 1
bot_w = rows[-1][2] - rows[-1][1] + 1
print(f"首行宽度 {top_w}px / 末行宽度 {bot_w}px（喇叭口正常时应 ≈1–3px，且上下接近）")

if bot_w > 4 or top_w > 4:
    print("✗ 有一端被窗口裁切：喇叭口没收尖，说明该侧内缩小于喇叭口半径")
    sys.exit(1)

diff = max(abs(t - o) for (_, t), (_, o) in zip(head, tail))
print(f"上下喇叭口最大偏差: {diff}px  {'✓ 对称' if diff <= 3 else '✗ 不对称'}")
sys.exit(0 if diff <= 3 else 1)
