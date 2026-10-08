#!/usr/bin/env python3
"""确定性放大成品图里的 AI：给定中心 + 目标字号重画，然后重测输出确认变大。
不依赖 vision —— 用像素测量闭环验证。
用法：PYTHONPATH="$PWD/.iconlib" python3 _enlarge_final_ai.py
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

# (源, 中心, AI颜色, 新字号, 输出)
JOBS = [
    # gold: 中心(538,319) 现高327 → 字号 430 (~1.3x)
    ("generated-icons/gold_1_final.png", (538, 319), (15, 108, 157), 430, "generated-icons/gold_1_final_AIbig.png"),
    # gold 更激进一档：字号 470
    ("generated-icons/gold_1_final.png", (538, 319), (15, 108, 157), 470, "generated-icons/gold_1_final_AIbig2.png"),
    # red: 色块中心(435,445) 白字 → 字号 470
    ("generated-icons/red_2_final.png", (435, 445), (255, 255, 255), 470, "generated-icons/red_2_final_AIbig.png"),
]


def measure_ai(arr, text_rgb, tol, region):
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    dist = np.abs(r - text_rgb[0]) + np.abs(g - text_rgb[1]) + np.abs(b - text_rgb[2])
    opaque = arr[..., 3] >= 200
    mask = (dist < tol) & opaque
    x0, y0, x1, y1 = region
    sub = np.zeros_like(mask); sub[y0:y1, x0:x1] = mask[y0:y1, x0:x1]
    mask = sub
    if not mask.any():
        return None
    ys, xs = np.where(mask)
    return (int(xs.mean()), int(ys.mean())), (int(xs.min()), int(xs.min()) if False else int(xs.min()), int(ys.max())), (xs.max() - xs.min(), ys.max() - ys.min())


def main():
    for src, center, color, size, out in JOBS:
        im = Image.open(src).convert("RGBA")
        arr = np.array(im).astype(np.uint8)
        draw = ImageDraw.Draw(im)
        f = ImageFont.truetype(FONT, size)
        bb = draw.textbbox((0, 0), "AI", font=f)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        ox = int(center[0] - (bb[0] + bb[2]) / 2)
        oy = int(center[1] - (bb[1] + bb[3]) / 2)
        draw.text((ox, oy), "AI", font=f, fill=color + (255,))
        im.save(out)
        print(f"✓ {out}: 字号 {size} 中心 {center}")

        # 自验证：重测输出（限定色块区域）
        arr2 = np.array(Image.open(out).convert("RGBA")).astype(int)
        if color[0] > 200:  # 白字 → tol 70
            meas = measure_ai(arr2, (255, 255, 255), 70, (130, 126, 749, 765))
            tag = "白"
        else:  # 深蓝字 → tol 90
            meas = measure_ai(arr2, (15, 108, 157), 90, (120, 120, 740, 800))
            tag = "深蓝"
        if meas:
            _, _, (w, h) = meas
            print(f"  重测: {tag}字 bbox {w}x{h}px 高{h}px")
        else:
            print(f"  重测: 未找到 {tag}字!")


if __name__ == "__main__":
    main()
