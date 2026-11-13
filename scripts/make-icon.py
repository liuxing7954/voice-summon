#!/usr/bin/env python3
"""生成 app 图标：深色圆角底 + 青蓝渐变声波。"""
from PIL import Image, ImageDraw, ImageFilter
import os, subprocess, shutil

S = 1024
OUT = "Packaging/AppIcon.icns"
ICONSET = "Packaging/AppIcon.iconset"

# 背景垂直渐变
bg = Image.new("RGB", (S, S))
top = (13, 21, 30)
bottom = (28, 52, 70)
for y in range(S):
    t = y / (S - 1)
    color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    ImageDraw.Draw(bg).line([(0, y), (S, y)], fill=color)
bg = bg.convert("RGBA")

# 圆角遮罩（macOS 大圆角）
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=225, fill=255)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
icon.paste(bg, (0, 0), mask)

# 声波条
heights = [150, 300, 480, 700, 480, 300, 150]
bar_w, gap = 54, 38
total = len(heights) * bar_w + (len(heights) - 1) * gap
x = (S - total) // 2

bars = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw = ImageDraw.Draw(bars)
for h in heights:
    y0 = (S - h) // 2
    draw.rounded_rectangle([x, y0, x + bar_w, y0 + h], radius=bar_w // 2, fill=(255, 255, 255, 255))
    x += bar_w + gap

# 水平渐变上色
gradient = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(gradient)
c1, c2 = (42, 245, 200), (30, 144, 255)
for px in range(S):
    t = px / (S - 1)
    gd.line([(px, 0), (px, S)], fill=tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3)))
gradient = gradient.convert("RGBA")

colored = Image.new("RGBA", (S, S), (0, 0, 0, 0))
colored.paste(gradient, (0, 0), bars.split()[3])

# 发光
glow = colored.filter(ImageFilter.GaussianBlur(28))
icon = Image.alpha_composite(icon, glow)
icon = Image.alpha_composite(icon, colored)

# 裁回圆角
final = Image.new("RGBA", (S, S), (0, 0, 0, 0))
final.paste(icon, (0, 0), mask)

shutil.rmtree(ICONSET, ignore_errors=True)
os.makedirs(ICONSET, exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        final.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", OUT], check=True)
shutil.rmtree(ICONSET, ignore_errors=True)
final.resize((512, 512), Image.LANCZOS).save("Packaging/icon-preview.png")
print("生成:", OUT, os.path.getsize(OUT), "bytes")
