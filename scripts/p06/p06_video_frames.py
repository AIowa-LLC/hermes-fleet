#!/usr/bin/env python3
"""P0-6: per-frame analysis of the cold-launch video. For each extracted
frame: mean luma + bright% + content-bbox aspect. Timeline shows (1) the
native launch screen geometry, (2) the handoff, (3) the overlay hold, and
whether the artwork bbox ever CHANGES size/position during the splash window
(the 'jitter' defect). Frames matching the home screen (luma>100) are marked.
"""
import glob, zlib, struct

def load(path):
    data = open(path, "rb").read()
    pos = 8; w = h = None; idat = b""; ct = None; bd = None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, bd, ct, comp, filt, inter = struct.unpack(">IIBBBBB", chunk)
        elif typ == b"IDAT":
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = channels; stride = w * bpp
    rows = []; prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(bpp, stride): line[i] = (line[i] + line[i-bpp]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                b = prev[i]; c = prev[i-bpp] if i >= bpp else 0
                pa = abs(b-c); pb = abs(a-c); pc = abs(a+b-2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line); prev = line
    return w, h, rows, bpp

files = sorted(glob.glob("p06_frm_*.png"))
print(f"{len(files)} frames @10fps")
prev_box = None
for path in files:
    w, h, rows, bpp = load(path)
    n = bright = 0; luma_sum = 0
    minx, maxx, miny, maxy = w, -1, h, -1
    for y in range(0, h, 4):
        row = rows[y]
        for x in range(0, w, 4):
            i = x * bpp
            r, g, b = row[i], row[i+1], row[i+2]
            luma = (r + g + b) / 3
            luma_sum += luma; n += 1
            if luma > 60: bright += 1
            if luma > 24:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    mean = luma_sum / n
    tag = "HOME" if mean > 100 else "dark"
    if maxx < 0:
        box = "none"
    else:
        cw = maxx - minx + 1; ch = maxy - miny + 1
        box = f"x[{minx},{maxx}] y[{miny},{maxy}] {cw}x{ch} asp={cw/ch:.3f}"
    change = ""
    if prev_box and box == prev_box:
        change = "stable"
    prev_box = box
    print(f"{path}: luma={mean:6.1f} bright={100*bright//n:3d}% {tag:4s} {box} {change}")
