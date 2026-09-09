#!/usr/bin/env python3
"""FOS-7 (SPEC §14) contrast gate.

Verifies the §14 token palette numerically: every status/accent foreground
against BOTH specified opaque backgrounds (canvas light #F8F9FC / dark
#101216, grouped surface light #FFFFFF / dark #1B1E24) in the matching
mode, using WCAG relative luminance — the same method the spec used for
its stated minimums.

Spec minimums (light/dark): interactive 6.84/8.06, online 6.18/9.43,
executing 5.64/10.13, attention 6.08/11.60, degraded 5.96/10.05,
destructive 6.17/8.12.

Exit 0 = PASS (all ratios >= spec minimums, with the spec's numerical
margin), 1 = FAIL, 2 = usage error.
"""
import sys

def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 * 255 / 255 else ((c + 0.055) / 1.055) ** 2.4

def luminance(hexval):
    r = srgb_to_linear((hexval >> 16) & 0xFF)
    g = srgb_to_linear((hexval >> 8) & 0xFF)
    b = srgb_to_linear(hexval & 0xFF)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def ratio(fg, bg):
    l1, l2 = luminance(fg), luminance(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)

# (name, light fg, dark fg, spec min light, spec min dark)
TOKENS = [
    ("interactive  #5B35D5/#BDA7FF", 0x5B35D5, 0xBDA7FF, 6.84, 8.06),
    ("online       #176B46/#73D6A0", 0x176B46, 0x73D6A0, 6.18, 9.43),
    ("executing    #006D87/#65D9F0", 0x006D87, 0x65D9F0, 5.64, 10.13),
    ("attention    #865400/#FFD080", 0x865400, 0xFFD080, 6.08, 11.60),
    ("degraded     #9D4713/#FFBA8A", 0x9D4713, 0xFFBA8A, 5.96, 10.05),
    ("destructive  #B42335/#FF97A3", 0xB42335, 0xFF97A3, 6.17, 8.12),
]

CANVAS = (0xF8F9FC, 0x101216)
GROUPED = (0xFFFFFF, 0x1B1E24)

def main():
    failures = 0
    print(f"{'token':34s} {'bg':10s} {'ratio':>7s} {'min':>6s}  verdict")
    for name, light_fg, dark_fg, min_light, min_dark in TOKENS:
        for bgname, (bg_light, bg_dark) in (("canvas", CANVAS), ("grouped", GROUPED)):
            for mode_idx, mode in enumerate(("light", "dark")):
                fg = light_fg if mode == "light" else dark_fg
                bg = bg_light if mode == "light" else bg_dark
                need = min_light if mode == "light" else min_dark
                r = ratio(fg, bg)
                ok = r >= need - 0.005  # numerical margin for rounding
                verdict = "PASS" if ok else "FAIL"
                if not ok:
                    failures += 1
                print(f"{name:34s} {bgname+' '+mode:10s} {r:7.2f} {need:6.2f}  {verdict}")
    # Filled violet button text: white on light violet, canvas-dark on pale dark violet
    extra = [
        ("button text white on light violet", 0xFFFFFF, 0x5B35D5, 4.5),
        ("button text canvas-dark on dark violet", 0x101216, 0xBDA7FF, 4.5),
    ]
    for name, fg, bg, need in extra:
        r = ratio(fg, bg)
        ok = r >= need
        print(f"{name:34s} {'filled':10s} {r:7.2f} {need:6.2f}  {'PASS' if ok else 'FAIL'}")
        if not ok:
            failures += 1
    if failures:
        print(f"FAIL: {failures} ratio(s) below spec minimum")
        return 1
    print("PASS: all §14 token ratios meet the specified minimums on canvas and grouped surfaces, light and dark")
    return 0

if __name__ == "__main__":
    sys.exit(main())
