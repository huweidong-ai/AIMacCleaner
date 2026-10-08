#!/usr/bin/env python3
"""按用户要求重新生成候选图标：把「AI」字放大。
原理：把色块膨胀目标占比调大（block_pct），再让字自动适配更大的色块 → AI 变大且仍在色块内。
用法：PYTHONPATH="$PWD/.iconlib" python3 _regenerate_icon.py
"""
import os
import numpy as np
from PIL import Image
from _process_multicolor import (remove_white_bg, detect_largest_color,
                                 expand_color, draw_text_in_mask, apply_squircle_mask)

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
OUT_DIR = "generated-icons"

# 用户选的候选 + 放大配置（block_pct 越大 → 色块越大 → AI 越大）
JOBS = [
    # (color_key, n, block_pct, 备注)
    ("gold", 1, 0.38, "gold_1 色块扩到38%"),
    ("gold", 1, 0.44, "gold_1 色块扩到44%"),
    ("red",  2, 0.38, "red_2 色块扩到38%"),
    ("red",  2, 0.44, "red_2 色块扩到44%"),
]

TARGETS = {
    "red":    {"hex": (255, 107, 91),  "hue": [(0, 25), (335, 360)], "text": (255, 255, 255)},
    "gold":   {"hex": (245, 166, 35),  "hue": [(28, 55)],            "text": (14, 108, 158)},
    "yellow": {"hex": (255, 214, 0),   "hue": [(40, 70)],            "text": (14, 108, 158)},
    "green":  {"hex": (52, 199, 89),   "hue": [(95, 165)],           "text": (255, 255, 255)},
}


def regenerate(color_key, n, block_pct, tag):
    src = f"{OUT_DIR}/_raw/{color_key}_{n}.png"
    out = f"{OUT_DIR}/{color_key}_{n}_final_AI{int(block_pct*100)}.png"
    if not os.path.exists(src):
        print(f"✗ 缺源图 {src}")
        return None
    im = Image.open(src).convert("RGBA")
    arr = np.array(im).astype(np.int32)
    H, W = arr.shape[:2]
    print(f"\n处理 {os.path.basename(src)} → {os.path.basename(out)} ({tag})")

    arr = remove_white_bg(arr)
    cmask = detect_largest_color(arr, color_key)
    print(f"  色块 {int(cmask.sum())} ({cmask.sum()/(W*H)*100:.0f}%)")
    if cmask.sum() < 5000:
        print("  ✗ 色块太小"); return None

    target = TARGETS[color_key]["hex"]
    arr[cmask, 0], arr[cmask, 1], arr[cmask, 2] = target

    new_mask, broom = expand_color(arr, cmask, max_layers=200, target_pct=block_pct)
    added = new_mask & ~cmask
    arr[added, 0], arr[added, 1], arr[added, 2] = target
    print(f"  膨胀后 {int(new_mask.sum())} ({new_mask.sum()/(W*H)*100:.0f}%) 扫帚 {int(broom.sum())}px")

    text_color = TARGETS[color_key]["text"]
    before = arr.copy()
    arr = draw_text_in_mask(arr, new_mask, "AI", text_color, strict=True)
    if np.array_equal(arr, before):
        arr = draw_text_in_mask(arr, new_mask, "AI", text_color, strict=False)

    arr = apply_squircle_mask(arr, radius_factor=0.225)
    Image.fromarray(arr.astype(np.uint8), "RGBA").save(out)
    print(f"  ✓ {out}")


if __name__ == "__main__":
    for key, n, pct, tag in JOBS:
        try:
            regenerate(key, n, pct, tag)
        except Exception as e:
            import traceback; traceback.print_exc()
            print(f"  ✗ {key}_{n}: {e}")
    print("\n完成")
