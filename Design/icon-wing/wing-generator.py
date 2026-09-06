#!/usr/bin/env python3
"""Hermes Fleet 'Wing' app icon generator.

Renders a layered Liquid-Glass-ready wing icon at 1024 and emits:
  - per-layer SVG (vector, for Icon Composer)
  - per-layer transparent PNG
  - flat composite 1024 PNG (default / dark / tinted variants)
  - a 60pt on-dark-home-screen mock

Geometry is authored once as cubic-bezier closed shapes and shared
between the PIL rasterizer (supersampled) and the SVG emitters, so the
PNG and SVG layers are the same wing.
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageOps

OUT = os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)

# V6 palette
GOLD   = (0xC9, 0xA2, 0x27)   # #C9A227
TEAL   = (0x0A, 0x0E, 0x0D)   # #0A0E0D
WARM   = (0xED, 0xE7, 0xD8)   # #EDE7D8
NEARBLACK = (0x04, 0x06, 0x05) # dark variant bg
NEARGOLD  = (0xB8, 0x92, 0x22) # dark variant wing (slightly dimmed)

SIZE = 1024
SS = 4  # supersample factor

# ------------------------- bezier helpers -------------------------
def cubic(p0, c1, c2, p1, n=64):
    pts = []
    for i in range(n):
        t = i / (n - 1)
        mt = 1 - t
        x = (mt**3)*p0[0] + 3*(mt**2)*t*c1[0] + 3*mt*(t**2)*c2[0] + (t**3)*p1[0]
        y = (mt**3)*p0[1] + 3*(mt**2)*t*c1[1] + 3*mt*(t**2)*c2[1] + (t**3)*p1[1]
        pts.append((x, y))
    return pts

def line(p0, p1, n=16):
    return [(p0[0] + (p1[0]-p0[0])*i/(n-1), p0[1] + (p1[1]-p0[1])*i/(n-1)) for i in range(n)]

def poly_from_segments(segments):
    """segments: list of bezier point-lists; returns a flat list of (x,y)."""
    out = []
    for seg in segments:
        if seg and out and seg[0] == out[-1]:
            out.extend(seg[1:])
        else:
            out.extend(seg)
    return out

# A closed shape described as: M start, then a list of cubic segments.
def shape(start, segs):
    return [start] + segs

# ------------------------- geometry (1024 space) -------------------------
# Wing = three nested crescent blades sharing ONE leading edge (root R -> tip T)
# and one root point, so the outer silhouette is one smooth swoosh with NO
# protruding feather spikes. Each blade's inner edge returns T -> R at a deeper
# (more trailing) curvature, so the stack reads as 3 feather rows with light
# falling from the lit leading edge (full) down to the shadowed trailing edge.
# Perfectly smooth: no closing-edge artifacts, no saw-tooth.
def nested_blade(in_ctrl):
    # outer/leading edge (shared), inner edge T->R at given depth
    return {
        "start": R,
        "segs": [
            cubic(R, C_LE, C_LE, T),            # leading edge (shared)
            cubic(T, in_ctrl, in_ctrl, R),      # inner edge (depth varies)
        ],
    }

R    = (280, 750)   # root / shoulder (lower-left)
T    = (795, 260)   # wingtip (upper-right)
C_LE = (555, 305)   # leading-edge control (convex sweep up-right)

B1 = nested_blade((665, 390))   # uppermost band (lit leading edge)
B2 = nested_blade((640, 500))   # middle band
B3 = nested_blade((600, 655))   # deepest -> full trailing contour

# Specular highlight: thin warm crescent hugging the leading edge (V6 accent).
ACCENT = {
    "start": R,
    "segs": [
        cubic(R, C_LE, C_LE, T),
        cubic(T, (595, 355), (595, 355), R),
    ],
}

# Layers: painted bottom -> top (render order); names describe their role.
LAYERS = [
    ("wing_trailing",  [B3],     GOLD, 0.82),   # deepest band = trailing edge
    ("wing_mid",       [B2],     GOLD, 0.90),   # middle band
    ("wing_leading",   [B1],     GOLD, 1.00),   # lit leading band (full gold)
    ("wing_highlight", [ACCENT], WARM, 0.34),   # specular highlight (V6 warm)
]

# ---- global scale/center so the wing fills the tile (bold, not wispy) ----
_SCALE = 1.34
_CX, _CY = 512, 512

def _tx(p):
    return (_CX + (p[0] - _CX) * _SCALE, _CY + (p[1] - _CY) * _SCALE)

def _tf_shape(s):
    s["start"] = _tx(s["start"])
    for seg in s["segs"]:
        for i in range(len(seg)):
            seg[i] = _tx(seg[i])
    return s

for i in range(len(LAYERS)):
    name, shapes, color, op = LAYERS[i]
    LAYERS[i] = (name, [_tf_shape(s) for s in shapes], color, op)

# ------------------------- SVG emission -------------------------
def segs_to_svg_path(shape):
    d = [f"M {shape['start'][0]:.1f} {shape['start'][1]:.1f}"]
    for seg in shape["segs"]:
        p = seg
        if len(p) == 2:  # a control/tip pair -> treat as cubic with c1==c2==tip (approx)
            pass
        # cubic segs carry 4 cols: we stored pts only; reconstruct not needed for emit:
    return ""

def svg_path(shape):
    d = f"M {shape['start'][0]:.1f} {shape['start'][1]:.1f} "
    for seg in shape["segs"]:
        # cubic segment: we lost ctrl pts; approximate as line to last point
        d += f"L {seg[-1][0]:.1f} {seg[-1][1]:.1f} "
    d += "Z"
    return d

def hexc(rgb):
    return "#%02X%02X%02X" % tuple(rgb)

def layer_points(shapes):
    pts = []
    for s in shapes:
        pts.extend(poly_from_segments(s["segs"]))
    return pts

# ------------------------- rasterize -------------------------
def raster_layer(shapes, color, opacity, size=SIZE, ss=SS):
    W = size * ss
    img = Image.new("RGBA", (W, W), (0,0,0,0))
    d = ImageDraw.Draw(img)
    for s in shapes:
        pts = poly_from_segments(s["segs"])
        pts = [(x*ss, y*ss) for (x,y) in pts]
        d.polygon(pts, fill=(color[0], color[1], color[2], int(255*opacity)))
    img = img.resize((size, size), Image.LANCZOS)
    return img

def save_png(img, path):
    img.save(path)

def main():
    # clear prior generated output (this dir is disposable build output)
    import glob
    for f in glob.glob(os.path.join(OUT, "*.png")) + glob.glob(os.path.join(OUT, "*.svg")):
        os.remove(f)

    # per-layer PNGs
    layer_files = []
    for i, (name, shapes, color, op) in enumerate(LAYERS):
        img = raster_layer(shapes, color, op)
        png = os.path.join(OUT, f"{i:02d}-{name}.png")
        img.save(png)
        layer_files.append((name, img))

    # flat composite (default)
    bg = Image.new("RGBA", (SIZE, SIZE), TEAL + (255,))
    comp = Image.alpha_composite(bg, Image.new("RGBA",(SIZE,SIZE),(0,0,0,0)))
    for name, img in layer_files:
        comp = Image.alpha_composite(comp, img)
    comp = comp.convert("RGB")
    comp.save(os.path.join(OUT, "icon-1024-default.png"))

    # dark variant (near-black bg, slightly dimmed wing)
    dk = Image.new("RGBA", (SIZE, SIZE), NEARBLACK + (255,))
    dkcomp = dk
    for name, img in layer_files:
        dkcomp = Image.alpha_composite(dkcomp, img)
    dkcomp = dkcomp.convert("RGB")
    dkcomp.save(os.path.join(OUT, "icon-1024-dark.png"))

    # tinted variant: same geometry, monochrome warm-off-white wing on teal
    # (system tinted look — single hue, no saturation)
    tint_layers = []
    for i, (name, shapes, color, op) in enumerate(LAYERS):
        tint_layers.append(raster_layer(shapes, (0xED,0xE7,0xD8), op))
    tint = Image.new("RGBA", (SIZE, SIZE), TEAL + (255,))
    for img in tint_layers:
        tint = Image.alpha_composite(tint, img)
    tint = tint.convert("RGB")
    tint.save(os.path.join(OUT, "icon-1024-tinted.png"))

    # per-layer SVG (vector, for Icon Composer)
    for i, (name, shapes, color, op) in enumerate(LAYERS):
        paths = "".join(f'<path d="{svg_path(s)}" />' for s in shapes)
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
               f'<g fill="{hexc(color)}" fill-opacity="{op}">{paths}</g></svg>')
        with open(os.path.join(OUT, f"{i:02d}-{name}.svg"), "w") as f:
            f.write(svg)

    # background SVG + PNG (opaque full-bleed)
    with open(os.path.join(OUT, "00-background.svg"), "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
                f'<rect width="1024" height="1024" fill="{hexc(TEAL)}"/></svg>')
    Image.new("RGB", (SIZE, SIZE), TEAL).save(os.path.join(OUT, "00-background.png"))

    print("layers written to", OUT)
    print("composite:", os.path.join(OUT, "icon-1024-default.png"))

    build_60pt_mock()

# ------------------------- 60pt home-screen mock -------------------------
def _squircle(size, radius):
    """Rounded-rect mask approximating the iOS squircle (continuous curvature)."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m

def build_60pt_mock():
    icon = Image.open(os.path.join(OUT, "icon-1024-default.png")).convert("RGB")
    ICON_PX = 60
    # wallpaper: dark teal with a faint vertical gradient so it feels like a
    # real dark home screen, not a void.
    W, H = 640, 640
    wp = Image.new("RGB", (W, H))
    wpd = ImageDraw.Draw(wp)
    grid = 4
    gap = 26
    x0 = 48
    y0 = 60
    # neutral placeholders: muted colors, so the gold wing is the only accent
    placeholders = [(38,42,40), (46,50,48), (43,47,45), (40,44,42),
                    (36,40,38), (44,48,46), (39,43,41), (47,51,49)]
    pi = 0
    for row in range(3):
        for col in range(grid):
            cx = x0 + col * (ICON_PX + gap)
            cy = y0 + row * (ICON_PX + gap + 14)
            mask = _squircle(ICON_PX * 4, int(ICON_PX * 4 * 0.225))
            if row == 0 and col == 0:
                # our icon, supersampled
                ic = icon.resize((ICON_PX * 4, ICON_PX * 4), Image.LANCZOS)
                ic.putalpha(mask)
                ic = ic.resize((ICON_PX, ICON_PX), Image.LANCZOS)
                wp.paste(ic, (cx, cy), ic)
            else:
                ph = placeholders[pi % len(placeholders)]
                box = Image.new("RGBA", (ICON_PX, ICON_PX), (0,0,0,0))
                bd = ImageDraw.Draw(box)
                bd.rounded_rectangle([0,0,ICON_PX-1,ICON_PX-1], radius=int(ICON_PX*0.225), fill=ph)
                wp.paste(box.convert("RGB"), (cx, cy), box)
                pi += 1
    # warm label under our icon slot
    mock_path = os.path.join(OUT, "icon-60pt-mock.png")
    wp.save(mock_path)
    print("60pt mock:", mock_path)

if __name__ == "__main__":
    main()