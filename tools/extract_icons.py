#!/usr/bin/env python3
"""从资产总表里切出三个按钮 × 四种状态的图标。

总表约定（与 assets/android_harmony_secondary_display_icons 一致）：
  - PNG 带透明通道，背景透明，图标按网格排布；
  - 目标行默认取最后一排（--row 可指定，从 1 开始）；
  - 每行 12 列（--cols 可改），顺序为
      input × 4 / keyboard × 4 / disconnect × 4
    四种状态依次是 normal / hover / active / disabled，
    disconnect 的第三个状态是 danger。

输出结构：
  <out>/input/{normal,hover,active,disabled}.png
  <out>/keyboard/{normal,hover,active,disabled}.png
  <out>/disconnect/{normal,hover,danger,disabled}.png

每个图标以自身字形为中心放进同样大小的正方形画布，四态不会错位；
透明背景原样保留，不做颜色处理。

用法：
  pip install pillow
  python3 tools/extract_icons.py <sheet.png> <out_dir> [--row N] [--cols N] [--size N] [--preview path.png]
"""
import argparse
import os
import sys

from PIL import Image

ACTIONS = ["input", "keyboard", "disconnect"]
STATES = ["normal", "hover", "active", "disabled"]

# 小于这个 alpha 视为透明
ALPHA_MIN = 16
# 太小的噪点直接丢弃
MIN_AREA = 80


def components(img: Image.Image, box):
    """在 box 区域内按 alpha 找连通块，返回 [(l, t, r, b, area), ...]。"""
    left, top, right, bottom = box
    w, h = right - left, bottom - top
    alpha = img.crop(box).getchannel("A")
    data = alpha.load()
    seen = [[False] * w for _ in range(h)]
    out = []
    for y in range(h):
        for x in range(w):
            if seen[y][x] or data[x, y] <= ALPHA_MIN:
                continue
            stack = [(x, y)]
            seen[y][x] = True
            l = r = x
            t = b = y
            area = 0
            while stack:
                cx, cy = stack.pop()
                area += 1
                l, r = min(l, cx), max(r, cx)
                t, b = min(t, cy), max(b, cy)
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and data[nx, ny] > ALPHA_MIN:
                            seen[ny][nx] = True
                            stack.append((nx, ny))
            if area >= MIN_AREA:
                out.append((l, t, r, b, area))
    return out


def is_label(box, cell_w):
    """文字标签是又宽又扁的小块，单独排除。"""
    l, t, r, b, _ = box
    w, h = r - l + 1, b - t + 1
    return h < 18 or (w > cell_w * 0.45 and w > h * 2.5)


def icon_bbox(img: Image.Image, cell):
    """返回 (核心中心, 核心包围盒宽高)。

    中心与尺寸都只按「笔画核心」算：状态光晕不对称且大小不一，
    用整个连通块会把四态拽偏、尺寸也不一致。
    """
    left, top = cell[0], cell[1]
    cell_w = cell[2] - cell[0]
    boxes = [b for b in components(img, cell) if not is_label(b, cell_w)]
    if not boxes:
        raise SystemExit(f"cell {cell} 没找到图标")

    alpha = img.crop(cell).getchannel("A")
    max_a = max(i for i, n in enumerate(alpha.histogram()) if n)
    core = alpha.point(lambda v: 255 if v > max(80, int(max_a * 0.6)) else 0).getbbox()
    if not core:
        l = min(b[0] for b in boxes)
        t = min(b[1] for b in boxes)
        r = max(b[2] for b in boxes)
        b = max(b[3] for b in boxes)
        core = (l, t, r + 1, b + 1)
    cx = left + (core[0] + core[2] - 1) / 2
    cy = top + (core[1] + core[3] - 1) / 2
    return (cx, cy, core[2] - core[0], core[3] - core[1])


def square_icon(img: Image.Image, center, scale: float, size: int) -> Image.Image:
    """以 center 为中心、按固定缩放比例截取，输出 size 见方。

    四个状态共用同一 scale（取 normal 态计算），核心笔画在画布中固定为
    CORE_TARGET 像素并精确居中，因此三组按钮的视觉大小一致、四态不错位。
    """
    side = size / scale
    half = side / 2
    box = (
        int(round(center[0] - half)),
        int(round(center[1] - half)),
        int(round(center[0] + half)),
        int(round(center[1] + half)),
    )
    icon = Image.new("RGBA", (box[2] - box[0], box[3] - box[1]), (0, 0, 0, 0))
    icon.paste(img.crop(box), (0, 0))
    return icon.resize((size, size), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sheet")
    ap.add_argument("out_dir")
    ap.add_argument("--row", type=int, default=3, help="目标行，从 1 开始；默认最后一行")
    ap.add_argument("--rows", type=int, default=3, help="总表行数")
    ap.add_argument("--cols", type=int, default=12, help="每行图标数")
    ap.add_argument("--size", type=int, default=96, help="输出边长")
    ap.add_argument("--preview", help="额外导出一张预览图")
    args = ap.parse_args()

    sheet = Image.open(args.sheet).convert("RGBA")
    W, H = sheet.size
    if not 1 <= args.row <= args.rows:
        sys.exit(f"--row 超出范围 1..{args.rows}")
    if args.cols % 3:
        sys.exit("--cols 必须是 3 的倍数（input/keyboard/disconnect）")

    row_h = H / args.rows
    top = int(round((args.row - 1) * row_h))
    bottom = int(round(args.row * row_h))
    cell_w = W / args.cols

    per_action = args.cols // 3
    boxes = []
    for idx in range(args.cols):
        cell = (
            int(round(idx * cell_w)),
            top,
            int(round((idx + 1) * cell_w)),
            bottom,
        )
        boxes.append(icon_bbox(sheet, cell))

    # 统一视觉尺寸：核心笔画在输出里固定 CORE_TARGET 像素
    CORE_TARGET = 52
    icons = []
    for action in range(3):
        group = boxes[action * per_action:(action + 1) * per_action]
        base_size = max(group[0][2], group[0][3])
        scale = CORE_TARGET / base_size
        for i in range(per_action):
            cx, cy, _, _ = group[i]
            icons.append(square_icon(sheet, (cx, cy), scale, args.size))

    for idx, icon in enumerate(icons):
        action = ACTIONS[idx // per_action]
        state = STATES[idx % 4]
        if action == "disconnect" and state == "active":
            state = "danger"
        folder = os.path.join(args.out_dir, action)
        os.makedirs(folder, exist_ok=True)
        icon.save(os.path.join(folder, f"{state}.png"))
        print(f"{action}/{state}.png")

    if args.preview:
        gap = 12
        n = len(icons)
        sheet_w = n * args.size + (n + 1) * gap
        preview = Image.new("RGBA", (sheet_w, args.size + gap * 2), (31, 36, 46, 255))
        for idx, icon in enumerate(icons):
            preview.alpha_composite(icon, (gap + idx * (args.size + gap), gap))
        preview.save(args.preview)
        print(f"preview -> {args.preview}")


if __name__ == "__main__":
    main()