#!/usr/bin/env python3
"""分析候选图标：色块边界 + AI 字像素范围 + 当前字号估计。"""
import sys
import numpy as np
from PIL import Image

def analyze(path, block_hue_ranges, text_color=None):
    im = Image.open(path).convert("RGBA")
    arr = np.array(im)
    H, W = arr.shape[:2]
    print(f"\n=== {path} ({W}x{H}) ===")
    # 色块：按色相找最大连通域（简化：直接按目标色相筛全部像素，取包围盒）
    r, g, b = arr[..., 0].astype(int), arr[..., 1].astype(int), arr[..., 2].astype(int)
    import colorsys
    hsv = np.array([colorsys.rgb_to_hsv(rr/255, gg/255, bb/255) for rr, gg, bb in zip(r.ravel(), g.ravel(), b.ravel())]).reshape(H, W, 3)
    hh = hsv[..., 0] * 360
    opaque = arr[..., 3] >= 200
    mask = opaque.copy()
    for (h0, h1) in block_hue_ranges:
        in_range = (hh >= h0) & (hh <= h1)
        mask &= ~in_range  # mask 是"非色块"
    # 反色块掩码（色块 = 是目标色相）
    block = np.zeros((H, W), dtype=bool)
    for (h0, h1) in block_hue_ranges:
        block |= (hh >= h0) & (hh <= h1) & opaque
    if block.any():
        ys, xs = np.where(block)
        print(f"  色块像素 {block.sum()} ({block.sum()/(W*H)*100:.1f}%) 包围盒 x[{xs.min()},{xs.max()}] y[{ys.min()},{ys.max()}] (宽{xs.max()-xs.min()} 高{ys.max()-ys.min()})")

    # AI 字：找 text_color 附近的像素
    if text_color is not None:
        tc = np.array(text_color)
        dist = np.abs(r - tc[0]) + np.abs(g - tc[1]) + np.abs(b - tc[2])
        tmask = (dist < 90) & opaque
        if tmask.any():
            ys, xs = np.where(tmask)
            print(f"  AI字像素 {tmask.sum()} 包围盒 x[{xs.min()},{xs.max()}] y[{ys.min()},{ys.max()}] (宽{xs.max()-xs.min()} 高{ys.max()-ys.min()})")
            print(f"  字高约 {ys.max()-ys.min()}px（1024 图）；若字号≈字高则当前约 {ys.max()-ys.min()}")

if __name__ == "__main__":
    # gold: 金色相 ~28-55，字为深蓝 PETROL(14,108,158)
    analyze("generated-icons/gold_1_final.png", [(28, 55)], text_color=(14, 108, 158))
    # red: 红/珊瑚 ~335-25 跨越，字为白
    analyze("generated-icons/red_2_final.png", [(335, 360), (0, 25)], text_color=(255, 255, 255))
