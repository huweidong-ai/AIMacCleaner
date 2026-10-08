#!/usr/bin/env python3
"""直接在现有成品图标上放大「AI」字。
对每个候选：检测色块中心 → 用更大字号重画 AI（仍在色块 bbox 内），保留其余像素不动。
用法：PYTHONPATH="$PWD/.iconlib" python3 _enlarge_ai.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

# (源文件, 色块色相范围, AI文字颜色, 字号相对放大倍数, 输出后缀)
JOBS = [
    ("generated-icons/gold_1_final.png",   [(28, 55)],            (14, 108, 158), 1.35, "gold1_AI13"),
    ("generated-icons/gold_1_final.png",   [(28, 55)],            (14, 108, 158), 1.55, "gold1_AI15"),
    ("generated-icons/red_2_final.png",    [(335, 360), (0, 25)], (255, 255, 255), 1.30, "red2_AI13"),
    ("generated-icons/red_2_final.png",    [(335, 360), (0, 25)], (255, 255, 255), 1.50, "red2_AI15"),
]


def block_bbox(arr, hue_ranges):
    """返回色块（目标色相、不透明）的包围盒与中心。"""
    import colorsys
    H, W = arr.shape[:2]
    r, g, b = arr[..., 0].astype(int), arr[..., 1].astype(int), arr[..., 2].astype(int)
    opaque = arr[..., 3] >= 200
    mask = np.zeros((H, W), dtype=bool)
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            if not opaque[y, x]:
                continue
            hh, _, _ = colorsys.rgb_to_hsv(r[y, x] / 255, g[y, x] / 255, b[y, x] / 255)
            h = hh * 360
            for h0, h1 in hue_ranges:
                if h0 <= h <= h1:
                    mask[y, x] = True
                    break
    # 放大回全分辨率（粗，但 bbox 足够准）
    full = np.zeros((H, W), dtype=bool)
    full[::2, ::2] = mask[::2, ::2]
    full[1::2, ::2] = mask[::2, ::2]
    full[::2, 1::2] = mask[::2, ::2]
    full[1::2, 1::2] = mask[::2, ::2]
    if not full.any():
        return None
    ys, xs = np.where(full)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    return (x0, y0, x1, y1), (xs.mean(), ys.mean())


def draw_ai(im_arr, center, text_color, base_height, scale):
    """以 base_height*scale 字号画 AI，保证不超出图标边界，居中于 center。"""
    H, W = im_arr.shape[:2]
    im = Image.fromarray(im_arr.astype(np.uint8), "RGBA")
    draw = ImageDraw.Draw(im)
    cx, cy = int(center[0]), int(center[1])
    size = int(base_height * scale)
    f = ImageFont.truetype(FONT, size)
    bb = draw.textbbox((0, 0), "AI", font=f)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    # 居中，同时保证不超出图标（内缩 8%）
    max_w, max_h = W * 0.84, H * 0.84
    if tw > max_w or th > max_h:
        # 太大则等比例缩到安全范围
        k = min(max_w / tw, max_h / th)
        size = int(size * k)
        f = ImageFont.truetype(FONT, size)
        bb = draw.textbbox((0, 0), "AI", font=f)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
    ox = int(cx - (bb[0] + bb[2]) / 2)
    oy = int(cy - (bb[1] + bb[3]) / 2)
    draw.text((ox, oy), "AI", font=f, fill=text_color + (255,))
    return np.array(im).astype(np.int32), size


def main():
    for src, hue_ranges, text_color, scale, tag in JOBS:
        if not os.path.exists(src):
            print(f"✗ 缺 {src}"); continue
        im = Image.open(src).convert("RGBA")
        arr = np.array(im).astype(np.int32)
        H, W = arr.shape[:2]

        bb, center = block_bbox(arr, hue_ranges)
        if bb is None:
            print(f"✗ {src} 没找到色块"); continue
        x0, y0, x1, y1 = bb
        block_w, block_h = x1 - x0, y1 - y0
        print(f"\n{src}: 色块bbox x[{x0},{x1}] y[{y0},{y1}] 中心({center[0]:.0f},{center[1]:.0f})")

        # 当前 AI 高度估计 = 色块高度下限（AI 原本几乎占满色块）
        # 用色块高度作为基准，放大后仍在色块内不现实（色块高度=602），
        # 我们直接以「图标高度」为参照，按 scale 决定目标字号。
        # base = 色块高度 → 放大后允许超出色块但限制在图标内。
        new_arr, size = draw_ai(arr, center, text_color, block_h, scale)
        out = src.replace("_final.png", f"_AI{tag}.png")
        Image.fromarray(new_arr.astype(np.uint8), "RGBA").save(out)
        print(f"  字号 {size} → {out}")


if __name__ == "__main__":
    main()
