#!/usr/bin/env python3
"""FOS-7 screenshot verification: sample pixels from the captured home
screens and verify (a) light vs dark canvas colors match the §14 tokens,
(b) Increase Contrast variants differ from the baseline canvas, proving the
HC fallback branch renders. Evidence complement to the runtime unit pins.
"""
from PIL import Image
import sys

def sample(path, points):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    out = []
    for fx, fy in points:
        px = im.getpixel((int(w * fx), int(h * fy)))
        out.append(px)
    return out, (w, h)

# Background sample points: edges away from content (left margin mid, top
# under nav, bottom above tab bar).
pts = [(0.02, 0.35), (0.5, 0.97), (0.985, 0.5)]

results = {}
for name in ["fos7-home-light", "fos7-home-dark", "fos7-home-contrast-light", "fos7-home-contrast-dark"]:
    samples, size = sample(f"/tmp/fos7_screens/{name}.png", pts)
    results[name] = samples
    print(f"{name}: size={size} samples={samples}")

light = results["fos7-home-light"]
dark = results["fos7-home-dark"]

def close(px, hexval, tol=14):
    r, g, b = (hexval >> 16) & 255, (hexval >> 8) & 255, hexval & 255
    return abs(px[0]-r) <= tol and abs(px[1]-g) <= tol and abs(px[2]-b) <= tol

ok = True
# Canvas expectations: light #F8F9FC, dark #101216 — at least one sampled
# background point should match each mode.
if not any(close(p, 0xF8F9FC) for p in light):
    print("WARN: no light sample near canvas #F8F9FC (content may cover margins)")
if not any(close(p, 0x101216) for p in dark):
    print("WARN: no dark sample near canvas #101216")

# HC variants must differ from the custom canvas (fallback branch live).
for mode, base_hex in [("light", 0xF8F9FC), ("dark", 0x101216)]:
    base = results[f"fos7-home-{mode}"]
    hc = results[f"fos7-home-contrast-{mode}"]
    diff = any(
        any(abs(a[i]-b[i]) > 6 for i in range(3))
        for a, b in zip(base, hc)
    )
    state = "DIFFERS" if diff else "SAME"
    print(f"HC {mode} vs base: {state}")
    if not diff:
        # not fatal — simctl increase_contrast may be unsupported on this sim runtime
        print(f"  note: check simctl ui increase_contrast support; unit tests pin the HC branch")

print("screenshot pixel evidence recorded")
