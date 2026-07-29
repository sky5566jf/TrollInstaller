#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_icon.py — 生成最终打包用的 App 图标。

功能：
  1. 读取源图标（任意模式）
  2. 若传入 --version，在右下角绘制版本号角标（半透明深色圆角胶囊 + 白字）
  3. 转 RGB + 256 色调色板量化 + 最高压缩，最大化缩小体积（类照片图标可省 ~70%）

仓库里的 AppIcon.png 保持干净（无角标）；本脚本只在 CI 打包时对
stage/TrollInstaller.app/AppIcon.png 生成带角标的优化版本。

用法：
  python3 make_icon.py --in AppIcon.png --out out.png [--version 1.1]
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont


def load_font(size):
    """在 windows / ubuntu 上尽量找到一个能用的 TrueType 字体，失败则退回内置点阵字体。"""
    candidates = [
        # ubuntu (CI)
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        # windows (本地)
        "C:/Windows/Fonts/arialbd.ttf",
        "C:/Windows/Fonts/msyhbd.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    # PIL >= 9.2.0 支持 load_default(size)
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def round_rect(draw, box, radius, fill):
    """绘制圆角矩形，兼容旧版 Pillow（<9.2 无 rounded_rectangle）。"""
    x1, y1, x2, y2 = box
    try:
        # Pillow >= 9.2
        draw.rounded_rectangle(box, radius=radius, fill=fill)
    except AttributeError:
        # 手动模拟圆角矩形：4 个角圆弧 + 中间矩形
        r = radius
        draw.rectangle([x1 + r, y1, x2 - r, y2], fill=fill)
        draw.rectangle([x1, y1 + r, x2, y2 - r], fill=fill)
        draw.ellipse([x1, y1, x1 + 2 * r, y1 + 2 * r], fill=fill)
        draw.ellipse([x2 - 2 * r, y1, x2, y1 + 2 * r], fill=fill)
        draw.ellipse([x1, y2 - 2 * r, x1 + 2 * r, y2], fill=fill)
        draw.ellipse([x2 - 2 * r, y2 - 2 * r, x2, y2], fill=fill)


def draw_badge(rgba, version):
    """在右下角绘制半透明深色圆角胶囊 + 白字版本号。"""
    W, H = rgba.size
    font = load_font(int(W * 0.10))  # 字号约图宽 10%
    text = f"v{version}"

    # 文本尺寸
    dummy = Image.new("RGBA", (10, 10))
    d0 = ImageDraw.Draw(dummy)
    bbox = d0.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]

    pad_x = int(W * 0.035)
    pad_y = int(W * 0.022)
    margin = int(W * 0.06)

    pill_w = tw + pad_x * 2
    pill_h = th + pad_y * 2
    x1 = W - margin - pill_w
    y1 = H - margin - pill_h
    x2 = x1 + pill_w
    y2 = y1 + pill_h

    overlay = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    round_rect(od, [x1, y1, x2, y2], radius=int(pill_h * 0.45), fill=(0, 0, 0, 165))
    # 文本描边增强可读性
    tx = x1 + pad_x - bbox[0]
    ty = y1 + pad_y - bbox[1]
    od.text((tx, ty), text, font=font, fill=(255, 255, 255, 255))
    rgba.alpha_composite(overlay)


def make_icon(src, dst, version=None):
    im = Image.open(src).convert("RGBA")
    if version:
        draw_badge(im, version)
    # 扁平化为 RGB，再 256 色调色板量化 + 最高压缩
    rgb = im.convert("RGB")
    quantized = rgb.convert("P", palette=Image.ADAPTIVE, colors=256)
    quantized.save(dst, "PNG", optimize=True, compress_level=9)
    return os.path.getsize(dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--version", default=None, help="如 1.1 —— 在右下角绘制 v1.1 角标")
    args = ap.parse_args()

    if not os.path.exists(args.src):
        print(f"::error::source icon not found: {args.src}", file=sys.stderr)
        sys.exit(1)

    size = make_icon(args.src, args.dst, args.version)
    print(f"[make_icon] wrote {args.dst} ({size} bytes)"
          + (f" with version badge v{args.version}" if args.version else ""))


if __name__ == "__main__":
    main()
