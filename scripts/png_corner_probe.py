#!/usr/bin/env python3
"""t_66f36b7f X3: pure-stdlib PNG corner probe (bitdepth 8, colortype 2/6)."""
import zlib, struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/x3_icon/icon-1024.png'
data = open(path, 'rb').read()
assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
# Apple-optimized (CgBI "crushed") PNGs: no zlib header on IDAT, BGRA channel order
cgbi = False
pos = 8; idat = b''; w = h = bd = ct = None
while pos < len(data):
    ln, typ = struct.unpack('>I4s', data[pos:pos+8])
    body = data[pos+8:pos+8+ln]; pos += 12 + ln
    if typ == b'CgBI':
        cgbi = True
    elif typ == b'IHDR':
        w = int.from_bytes(body[0:4], 'big'); h = int.from_bytes(body[4:8], 'big')
        bd, ct = body[8], body[9]
    elif typ == b'IDAT':
        idat += body
    elif typ == b'IEND':
        break
print(f'IHDR {w}x{h} bitdepth={bd} colortype={ct} cgbi={cgbi}')
assert bd == 8 and ct in (2, 6), 'only 8-bit RGB/RGBA supported'
assert isinstance(w, int) and isinstance(h, int) and w > 0 and h > 0, 'missing IHDR'
if cgbi:
    raw = zlib.decompress(idat, -15)   # raw deflate, no zlib header
else:
    raw = zlib.decompress(idat)
ch = 3 if ct == 2 else 4
bgra = cgbi  # crushed PNGs swap R and B
stride = w * ch
out = bytearray(); prev = bytearray(stride); p = 0
for y in range(h):
    f = raw[p]; p += 1
    line = bytearray(raw[p:p+stride]); p += stride
    if f == 1:
        for i in range(ch, stride): line[i] = (line[i] + line[i-ch]) & 255
    elif f == 2:
        for i in range(stride): line[i] = (line[i] + prev[i]) & 255
    elif f == 3:
        for i in range(stride):
            a = line[i-ch] if i >= ch else 0
            line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
    elif f == 4:
        for i in range(stride):
            a = line[i-ch] if i >= ch else 0; b = prev[i]
            c = prev[i-ch] if i >= ch else 0
            pp = a + b - c; pa = abs(pp-a); pb = abs(pp-b); pc = abs(pp-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 255
    out += line; prev = line

def px(x, y):
    i = (y * w + x) * ch
    r, g, b = out[i], out[i+1], out[i+2]
    return (b, g, r) if bgra else (r, g, b)

pts = {'TL': (0, 0), 'TR': (w-1, 0), 'BL': (0, h-1), 'BR': (w-1, h-1), 'C': (w//2, h//2)}
bad = []
for name, (x, y) in pts.items():
    r, g, b = px(x, y)
    print(f'  {name}: rgb({r},{g},{b})')
    if r > 240 and g > 240 and b > 240:
        bad.append(name)
if bad:
    print(f'RING-FAIL: near-white corners {bad}'); sys.exit(1)
print('corner artwork colors OK (no white ring)')
# also verify alpha fully opaque if RGBA
if ch == 4:
    alphas = out[3::4]
    print('max alpha byte:', max(alphas))
    if max(alphas) < 255:
        print('OPACITY-FAIL'); sys.exit(1)
    print('fully opaque OK')
