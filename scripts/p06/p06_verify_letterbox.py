#!/usr/bin/env python3
"""P0-6: verify a splash screenshot shows UNCROPPED aspect-fit artwork.

Reads a PNG screenshot (no PIL — pure zlib/struct decode, handles the
non-interlaced RGBA/RGB screenshots `simctl io screenshot` produces),
finds the bright-content bounding box, and checks:
  1. content aspect ~= asset aspect (941/1672 = 0.5628) -> not cropped
  2. content horizontally centered -> symmetric letterbox bars
  3. letterbox bars exist (width > 0) -> aspect-fit, not fill
Exit 0 = PASS, 1 = FAIL (prints measurements).
"""
import sys, zlib, struct

ASPECT = 941.0 / 1672.0

def load(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8; w = h = None; idat = b""; ct = None; bd = None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, bd, ct, comp, filt, inter = struct.unpack(">IIBBBBB", chunk)
            assert inter == 0, "interlaced PNG unsupported"
        elif typ == b"IDAT":
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    assert bd == 8, f"bitdepth {bd} unsupported"
    bpp = channels
    stride = w * bpp
    rows = []
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i-bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i-bpp] if i >= bpp else 0
                pa = abs(b-c); pb = abs(a-c); pc = abs(a+b-2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, rows, bpp

def luma(row, x, bpp):
    i = x * bpp
    r = row[i] if bpp >= 3 else row[i]
    g = row[i+1] if bpp >= 3 else row[i]
    b = row[i+2] if bpp >= 3 else row[i]
    return (r + g + b) / 3

def main(path):
    w, h, rows, bpp = load(path)
    print(f"screenshot {w}x{h}")
    minx, maxx, miny, maxy = w, -1, h, -1
    TH = 24  # brightness threshold: bg is ~10, artwork content is bright
    for y in range(0, h, 4):
        row = rows[y]
        for x in range(0, w, 4):
            if luma(row, x, bpp) > TH:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0:
        print("FAIL: no bright content found (screenshot not on splash?)")
        return 1
    # 4px sampling granularity — expand to real edges
    minx_e, maxx_e = max(0, minx - 4), min(w - 1, maxx + 4)
    miny_e, maxy_e = max(0, miny - 4), min(h - 1, maxy + 4)
    cw, ch = maxx_e - minx_e + 1, maxy_e - miny_e + 1
    aspect = cw / ch
    left = minx_e; right = w - 1 - maxx_e
    print(f"content bbox x[{minx_e},{maxx_e}] y[{miny_e},{maxy_e}] -> {cw}x{ch}")
    print(f"content aspect {aspect:.4f} vs asset {ASPECT:.4f}")
    print(f"letterbox bars: left {left}px, right {right}px (top {miny_e}px, bottom {h-1-maxy_e}px)")
    ok = True
    if abs(aspect - ASPECT) > 0.05:
        print(f"FAIL: content aspect off by {abs(aspect-ASPECT):.4f} — artwork looks CROPPED")
        ok = False
    else:
        print("PASS: content aspect matches asset — artwork uncropped")
    # Artwork (0.563) is WIDER than a phone screen (~0.46): correct fit is
    # width-limited — full-bleed horizontally, letterbox bars top/bottom.
    top, bottom = miny_e, h - 1 - maxy_e
    if min(top, bottom) < 8:
        print("FAIL: no vertical letterbox bars — looks like aspect-fill full-bleed (cropped)")
        ok = False
    else:
        print(f"PASS: vertical letterbox bars present ({top}px / {bottom}px) — aspect-fit")
    if abs(top - bottom) > max(8, 0.02 * h):
        print(f"FAIL: vertical bars asymmetric ({top} vs {bottom}) — artwork not centered")
        ok = False
    else:
        print("PASS: artwork centered")
    if minx_e > 8 or maxx_e < w - 9:
        print("FAIL: artwork not full-bleed horizontally — unexpected for width-limited fit")
        ok = False
    else:
        print("PASS: artwork spans full width")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
