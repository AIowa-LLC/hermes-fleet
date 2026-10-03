#!/usr/bin/env python3
"""M14 Visual Identity — contrast acceptance gate.

Computes WCAG 2.1 relative-luminance contrast for every defined
text/background pair in the Black/White/Signal Red theme (light + dark),
then enforces the gate:

  * text (normal, <24px)  >= 4.5 : 1
  * large text / UI       >= 3.0 : 1

Exits non-zero if ANY pair fails. Prints a per-pair table plus a summary.
This is the programmatic half of the M14 "contrast gate" acceptance criterion.
"""
import sys

# ---- theme tokens (single source of truth for the gate) ----
DARK = {
    "background": "#0A0A0B",
    "surface": "#161618",
    "surfaceElevated": "#1F1F22",
    "textPrimary": "#F5F5F7",
    "textSecondary": "#9C9CA4",
    "separator": "#2C2C30",
    "accent": "#FF453A",        # Signal Red (dark-appearance)
    "accentMagenta": "#FF2D55",  # Hot Magenta
    "accentColdBlue": "#0A84FF", # Cold Electric Blue
}
LIGHT = {
    "background": "#FFFFFF",
    "surface": "#F2F2F7",
    "surfaceElevated": "#FFFFFF",
    "textPrimary": "#17171A",
    "textSecondary": "#3C3C43",
    "separator": "#C6C6CC",
    "accent": "#C8102E",        # Signal Red (light-appearance, darkened for contrast)
    "accentMagenta": "#B4003C",  # Hot Magenta (darkened)
    "accentColdBlue": "#0064C8", # Cold Electric Blue (darkened)
}

def hex_to_rgb(h: str):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def luminance(rgb):
    def lin(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)

def contrast(fg_hex, bg_hex):
    l1 = luminance(hex_to_rgb(fg_hex))
    l2 = luminance(hex_to_rgb(bg_hex))
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)

# ---- the pairs under test (role, fg token, bg token, min ratio) ----
PAIRS = [
    ("textPrimary / background (text)", "textPrimary", "background", 4.5),
    ("textSecondary / background (text)", "textSecondary", "background", 4.5),
    ("textPrimary / surface (text)", "textPrimary", "surface", 4.5),
    ("textSecondary / surface (text)", "textSecondary", "surface", 4.5),
    ("textPrimary / surfaceElevated (text)", "textPrimary", "surfaceElevated", 4.5),
    ("accent / background (text-capable)", "accent", "background", 4.5),
    ("accent / surface (text-capable)", "accent", "surface", 4.5),
    ("accent / surfaceElevated (text-capable)", "accent", "surfaceElevated", 4.5),
    ("accentMagenta / background (UI/icon)", "accentMagenta", "background", 3.0),
    ("accentColdBlue / background (UI/icon)", "accentColdBlue", "background", 3.0),
    ("accentMagenta / surface (UI/icon)", "accentMagenta", "surface", 3.0),
    ("accentColdBlue / surface (UI/icon)", "accentColdBlue", "surface", 3.0),
]

def run(name, tokens):
    print(f"\n=== {name} ===")
    failures = 0
    for label, fg, bg, need in PAIRS:
        if fg not in tokens or bg not in tokens:
            print(f"  [skip] {label} (missing token)")
            continue
        ratio = contrast(tokens[fg], tokens[bg])
        ok = ratio >= need
        mark = "PASS" if ok else "FAIL"
        if not ok:
            failures += 1
        print(f"  {mark}  {ratio:6.2f}:1  ({need:4.1f}:1)  {label}  {tokens[fg]} on {tokens[bg]}")
    return failures

def main():
    total = run("DARK", DARK) + run("LIGHT", LIGHT)
    print("\n=== SUMMARY ===")
    if total == 0:
        print("CONTRAST GATE: PASS (all pairs meet 4.5:1 text / 3.0:1 UI)")
        return 0
    print(f"CONTRAST GATE: FAIL ({total} pair(s) below threshold)")
    return 1

if __name__ == "__main__":
    sys.exit(main())
