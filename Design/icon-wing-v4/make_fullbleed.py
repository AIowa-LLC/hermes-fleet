#!/usr/bin/env python3
"""Rebuild the v4 wing previews as full-bleed, opaque 1024 app-icon sources.

The previews in this directory are pre-masked renders (transparent corners,
a glass bevel rim). iOS applies its own mask, so an icon source must be an
opaque square. This keeps each preview's interior (gradient + wing + shadow)
and re-synthesizes the edge from the preview's own per-row background color.

Usage: python3 make_fullbleed.py   (writes fullbleed/<Name>.png)
"""
import os
from statistics import median
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = ["Default", "Dark", "TintedDark", "ClearDark", "ClearLight"]
SIZE = 1024
INSET = 96          # keep the preview inside this inset (clears the bevel rim)
RADIUS = 200
FEATHER = 24
SAMPLE_X = range(120, 240)   # left band, clear of the wing glyph
ROW_MIN, ROW_MAX = 110, 914


def row_colors(im):
    rows = {}
    for y in range(ROW_MIN, ROW_MAX + 1):
        px = [im.getpixel((x, y))[:3] for x in SAMPLE_X]
        rows[y] = tuple(int(median(c[i] for c in px)) for i in range(3))
    return [rows[min(max(y, ROW_MIN), ROW_MAX)] for y in range(SIZE)]


def build(name):
    src = Image.open(os.path.join(HERE, f"{name}.png")).convert("RGBA")
    colors = row_colors(src)
    base = Image.new("RGB", (SIZE, SIZE))
    draw = ImageDraw.Draw(base)
    for y, c in enumerate(colors):
        draw.line([(0, y), (SIZE, y)], fill=c)
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [INSET, INSET, SIZE - INSET, SIZE - INSET], radius=RADIUS, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(FEATHER))
    base.paste(src.convert("RGB"), (0, 0), mask)
    out = os.path.join(HERE, "fullbleed", f"{name}.png")
    base.save(out, optimize=True)
    return out


if __name__ == "__main__":
    for n in SOURCES:
        print(build(n))
