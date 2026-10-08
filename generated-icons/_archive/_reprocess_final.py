#!/usr/bin/env python3
"""在成品图上用原管线逻辑放大 AI：
1. 检测成品图的色块 → 2. expand_color 扩到目标占比（自动避开扫帚）→ 3. 重画 AI 居中适配。
用法：PYTHONPATH="$PWD/.iconlib" python3 _reprocess_final.py <gold|red>
"""
import sys
import numpy as np
from PIL import Image
from _process_multicolor import (detect_largest_color, expand_color,
                                 draw_text_in_mask, apply_squircle_mask)

TARGETS = {
    "red":    {"hex": (255, 107, 91),  "hue": [(0, 25), (335, 360)], "text": (255, 255, 255)},
    "gold":   {"hex": (245, 166, 35),  "hue": [(28, 55)],            "text": (14, 108, 158)},
}

def main():
    key = sys.argv[1] if len(sys.argv) > 1 else "gold"
    src = f"generated-icons/{key}_1_final.png" if key == "gold" else f"generated-icons/{key}_2_final.png"
    target_pct = float(sys.argv[2]) if len(sys.argv) > 2 else 0.15  # 基线 0.15≈现状
    out = f"generated-icons/{key}_{'1' if key=='gold' else '2'}_final_repro{int(target_pct*100)}.png"

    im = Image.open(src).convert("RGBA")
    arr = np.array(im).astype(np.int32)
    H, W = arr.shape[:2]
    print(f"{src} ({W}x{H}) → {out} 目标占比 {target_pct}")

    cmask = detect_largest_color(arr, key)
    print(f"  原色块 {int(cmask.sum())} ({cmask.sum()/(W*H)*100:.1f}%)")
    if cmask.sum() < 5000:
        print("  ✗ 色块太小"); return

    # 归一纯色（成品已是纯色，保险起见再归一）
    target = TARGETS[key]["hex"]
    arr[cmask, 0], arr[cmask, 1], arr[cmask, 2] = target

    new_mask, broom = expand_color(arr, cmask, max_layers=220, target_pct=target_pct)
    added = new_mask & ~cmask
    arr[added, 0], arr[added, 1], arr[added, 2] = target
    print(f"  膨胀后 {int(new_mask.sum())} ({new_mask.sum()/(W*H)*100:.1f}%) 扫帚 {int(broom.sum())}px")

    text_color = TARGETS[key]["text"]
    before = arr.copy()
    arr = draw_text_in_mask(arr, new_mask, "AI", text_color, strict=True)
    if np.array_equal(arr, before):
        arr = draw_text_in_mask(arr, new_mask, "AI", text_color, strict=False)

    arr = apply_squircle_mask(arr, radius_factor=0.225)
    Image.fromarray(arr.astype(np.uint8), "RGBA").save(out)
    print(f"  ✓ {out}")

if __name__ == "__main__":
    main()
