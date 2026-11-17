#!/usr/bin/env python3
"""生成界面自绘按钮图标（与切图图标同风格）：调试（圆形感叹号）、齿轮、关闭 X。

输出：
  <out>/debug/{normal,disabled}.png
  <out>/gear/{normal,disabled}.png
  <out>/close/normal.png

用法：
  pip install pillow
  python3 tools/gen_extra_icons.py assets/icon
"""
import math
import os
import sys

from PIL import Image, ImageDraw

SIZE = 96
WHITE = (255, 255, 255, 255)
GREY = (142, 142, 147, 150)
STROKE = 6


def blank() -> tuple:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def debug_icon(color) -> Image.Image:
    img, d = blank()
    c, r = SIZE // 2, 26
    d.ellipse((c - r, c - r, c + r, c + r), outline=color, width=STROKE + 1)
    bar_w = STROKE + 2
    d.rounded_rectangle((c - bar_w // 2, c - 14, c + bar_w // 2, c + 4),
                        radius=bar_w // 2, fill=color)
    dot = 4
    d.ellipse((c - dot, c + 10, c + dot, c + 18), fill=color)
    return img


def gear_icon(color) -> Image.Image:
    img, d = blank()
    c = SIZE / 2
    tip, root = 32, 24
    step = 360 / 8
    pts = []
    for k in range(8):
        a = k * step
        for radius, da in ((tip, -8), (tip, 8), (root, 16), (root, step - 16)):
            rad = math.radians(a + da)
            pts.append((c + radius * math.cos(rad), c + radius * math.sin(rad)))
    pts.append(pts[0])
    d.line(pts, fill=color, width=STROKE, joint="curve")
    hole = 10
    d.ellipse((c - hole, c - hole, c + hole, c + hole), outline=color, width=STROKE)
    return img


def close_icon(color) -> Image.Image:
    img, d = blank()
    lo, hi = 32, 64
    w = STROKE + 1
    d.line((lo, lo, hi, hi), fill=color, width=w)
    d.line((hi, lo, lo, hi), fill=color, width=w)
    # 圆角端点
    r = w // 2
    for x, y in ((lo, lo), (hi, hi), (hi, lo), (lo, hi)):
        d.ellipse((x - r, y - r, x + r, y + r), fill=color)
    return img


def save(img: Image.Image, folder: str, name: str):
    os.makedirs(folder, exist_ok=True)
    img.save(os.path.join(folder, name))


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "assets/icon"
    save(debug_icon(WHITE), os.path.join(out_dir, "debug"), "normal.png")
    save(debug_icon(GREY), os.path.join(out_dir, "debug"), "disabled.png")
    save(gear_icon(WHITE), os.path.join(out_dir, "gear"), "normal.png")
    save(gear_icon(GREY), os.path.join(out_dir, "gear"), "disabled.png")
    save(close_icon(WHITE), os.path.join(out_dir, "close"), "normal.png")
    print(f"extra icons -> {out_dir}")


if __name__ == "__main__":
    main()