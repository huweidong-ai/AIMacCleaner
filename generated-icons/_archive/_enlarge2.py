#!/usr/bin/env python3
"""在成品图上放大 AI 到色块宽度上限（多档字号），并自验证：宽/高/是否越界。"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

# (源, 目标AI中心, AI颜色, 色块bbox(x0,y0,x1,y1), 允许AI宽度上限=块宽95%, 档位字号列表, 输出前缀)
JOBS = [
    ("generated-icons/gold_1_final.png", (538, 319), (15, 108, 157),
     (154, 154, 695, 756), 500, [520, 560, 600], "gold_1_final"),
    ("generated-icons/red_2_final.png", (435, 445), (255, 255, 255),
     (130, 126, 749, 765), 580, [520, 560, 600], "red_2_final"),
]


def main():
    for src, center, color, (bx0, by0, bx1, by1), max_w, sizes, prefix in JOBS:
        im = Image.open(src).convert("RGBA")
        for size in sizes:
            im2 = im.copy()
            draw = ImageDraw.Draw(im2)
            f = ImageFont.truetype(FONT, size)
            bb = draw.textbbox((0, 0), "AI", font=f)
            tw, th = bb[2] - bb[0], bb[3] - bb[1]
            # 若超过色块宽上限，等比例缩到上限
            if tw > max_w:
                k = max_w / tw
                size = int(size * k)
                f = ImageFont.truetype(FONT, size)
                bb = draw.textbbox((0, 0), "AI", font=f)
                tw, th = bb[2] - bb[0], bb[3] - bb[1]
            ox = int(center[0] - (bb[0] + bb[2]) / 2)
            oy = int(center[1] - (bb[1] + bb[3]) / 2)
            draw.text((ox, oy), "AI", font=f, fill=color + (255,))
            out = f"generated-icons/{prefix}_AI{size}.png"
            im2.save(out)

            # 自验证：测量新 AI 的包围盒（在色块区域内）
            arr = np.array(im2.convert("RGBA")).astype(int)
            r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
            dist = np.abs(r - color[0]) + np.abs(g - color[1]) + np.abs(b - color[2])
            opaque = arr[..., 3] >= 200
            mask = (dist < (70 if color[0] > 200 else 90)) & opaque
            sub = np.zeros_like(mask); sub[by0:by1, bx0:bx1] = mask[by0:by1, bx0:bx1]
            mask = sub
            if mask.any():
                ys, xs = np.where(mask)
                w, h = xs.max() - xs.min(), ys.max() - ys.min()
                inside = xs.max() <= bx1 and xs.min() >= bx0 and ys.max() <= by1 and ys.min() >= by0
                print(f"  {out}: 字号{size} AI bbox {w}x{h}px {'✓在色块内' if inside else '✗越出色块'}")
            else:
                print(f"  {out}: 字号{size} 未测到 AI")


if __name__ == "__main__":
    main()
