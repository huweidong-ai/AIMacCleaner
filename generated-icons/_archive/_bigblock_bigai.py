#!/usr/bin/env python3
"""放大 AI 的正确组合：先扩色块（自动避开扫帚）→ 再画 AI 填满新色块宽度。
自验证：AI 尺寸应明显超过原图（gold 原 405x323 / red 原 611x637）。
用法：PYTHONPATH="$PWD/.iconlib" python3 _bigblock_bigai.py
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from _process_multicolor import detect_largest_color, expand_color, apply_squircle_mask

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

# (源, color_key, 新色块占比, 输出)
JOBS = [
    ("generated-icons/gold_1_final.png", "gold", 0.32, "generated-icons/gold_1_final_AIXL.png"),
    ("generated-icons/red_2_final.png",  "red",  0.32, "generated-icons/red_2_final_AIXL.png"),
]
TARGETS = {
    "red":  {"hex": (255, 107, 91),  "text": (255, 255, 255)},
    "gold": {"hex": (245, 166, 35),  "text": (15, 108, 157)},
}


def main():
    for src, key, pct, out in JOBS:
        im = Image.open(src).convert("RGBA")
        arr = np.array(im).astype(np.int32)
        H, W = arr.shape[:2]
        print(f"\n{src} → {out} 目标色块 {pct}")

        cmask = detect_largest_color(arr, key)
        target = TARGETS[key]["hex"]
        arr[cmask, 0], arr[cmask, 1], arr[cmask, 2] = target

        new_mask, broom = expand_color(arr, cmask, max_layers=260, target_pct=pct)
        added = new_mask & ~cmask
        arr[added, 0], arr[added, 1], arr[added, 2] = target
        print(f"  色块 {int(new_mask.sum())} ({new_mask.sum()/(W*H)*100:.1f}%) 扫帚 {int(broom.sum())}px")

        ys, xs = np.where(new_mask)
        bx0, bx1, by0, by1 = xs.min(), xs.max(), ys.min(), ys.max()
        print(f"  新色块bbox x[{bx0},{bx1}] y[{by0},{by1}] 宽{bx1-bx0} 高{by1-by0}")

        # 画 AI：填满新色块宽度(95%)，居中于新色块中心
        cx, cy = (bx0 + bx1) // 2, (by0 + by1) // 2
        max_w = (bx1 - bx0) * 0.95
        draw = ImageDraw.Draw(Image.fromarray(arr.astype(np.uint8), "RGBA"))
        f = None; bb = None
        for size in range(700, 200, -4):
            f = ImageFont.truetype(FONT, size)
            tmp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            dd = ImageDraw.Draw(tmp)
            bb = dd.textbbox((0, 0), "AI", font=f)
            tw, th = bb[2] - bb[0], bb[3] - bb[1]
            if tw <= max_w:
                break
        text_color = TARGETS[key]["text"]
        ox = int(cx - (bb[0] + bb[2]) / 2)
        oy = int(cy - (bb[1] + bb[3]) / 2)
        # 重开一张直接画（避免 tmp 干扰）
        im2 = Image.fromarray(arr.astype(np.uint8), "RGBA")
        draw2 = ImageDraw.Draw(im2)
        f = ImageFont.truetype(FONT, size)
        bb = draw2.textbbox((0, 0), "AI", font=f)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        ox = int(cx - (bb[0] + bb[2]) / 2)
        oy = int(cy - (bb[1] + bb[3]) / 2)
        draw2.text((ox, oy), "AI", font=f, fill=text_color + (255,))
        arr2 = np.array(im2).astype(np.int32)
        arr2 = apply_squircle_mask(arr2, radius_factor=0.225)
        Image.fromarray(arr2.astype(np.uint8), "RGBA").save(out)
        print(f"  AI 字号 {size} bbox {tw}x{th} 中心({cx},{cy}) → {out}")

        # 自验证
        am = np.array(Image.open(out).convert("RGBA")).astype(int)
        rr, gg, bb2 = am[..., 0], am[..., 1], am[..., 2]
        dist = np.abs(rr - text_color[0]) + np.abs(gg - text_color[1]) + np.abs(bb2 - text_color[2])
        mask = (dist < (70 if text_color[0] > 200 else 90)) & (am[..., 3] >= 200)
        sub = np.zeros_like(mask); sub[by0:by1, bx0:bx1] = mask[by0:by1, bx0:bx1]
        mask = sub
        if mask.any():
            ys2, xs2 = np.where(mask)
            print(f"  重测 AI bbox {xs2.max()-xs2.min()}x{ys2.max()-ys2.min()}px")


if __name__ == "__main__":
    main()
