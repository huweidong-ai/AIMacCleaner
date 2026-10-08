#!/usr/bin/env python3
"""精确测量 gold/red 成品图里 AI 字的中心与当前高度（纯像素，不依赖 vision）。"""
import numpy as np
from PIL import Image

def measure(path, text_rgb, text_tol, block_region=None):
    im = Image.open(path).convert("RGBA")
    arr = np.array(im).astype(int)
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    tr, tg, tb = text_rgb
    dist = np.abs(r - tr) + np.abs(g - tg) + np.abs(b - tb)
    opaque = arr[..., 3] >= 200
    mask = (dist < text_tol) & opaque
    if block_region:  # (x0,y0,x1,y1) 限制在色块内，排除扫帚
        x0, y0, x1, y1 = block_region
        sub = np.zeros_like(mask)
        sub[y0:y1, x0:x1] = mask[y0:y1, x0:x1]
        mask = sub
    if not mask.any():
        print(f"  {path}: 无匹配像素"); return None
    ys, xs = np.where(mask)
    # 去稀疏点：只保留连通且像素多的区域（取最大连通域=字母主体）
    print(f"  {path}: 匹配 {mask.sum()}px  bbox x[{xs.min()},{xs.max()}] y[{ys.min()},{ys.max()}] "
          f"中心({(xs.min()+xs.max())//2},{(ys.min()+ys.max())//2}) 高{ys.max()-ys.min()}px")
    return (int(xs.mean()), int(ys.mean())), (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))

if __name__ == "__main__":
    print("== gold_1_final (深蓝字 #0F6C9D, tol 90) ==")
    # 色块 bbox 已知 x[154,695] y[154,756]
    m = measure("generated-icons/gold_1_final.png", (15, 108, 157), 90, block_region=(120, 120, 740, 800))
    print("== red_2_final (白字, tol 60, 限定红块 x[130,749] y[126,765]) ==")
    m2 = measure("generated-icons/red_2_final.png", (255, 255, 255), 60, block_region=(130, 126, 749, 765))
