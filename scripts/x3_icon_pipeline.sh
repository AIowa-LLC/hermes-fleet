#!/bin/bash
# t_66f36b7f X3: App icon from Tony's Hermes artwork.
# 1) Resize 1254x1254 master to exactly 1024x1024 (sips -z, no crop, no alpha,
#    no rounding — iOS applies the superellipse mask itself).
# 2) Verify the produced icon: 1024x1024, no alpha, no baked near-white border
#    ring (corner-pixel scan; dark artwork corners are fine, a white ring would
#    read as a halo under the system mask).
# 3) Version the master in Design/, swap the 1024 into AppIcon.appiconset.
set -u
REPO="<repo-root>"
WS="$REPO/scripts"
SRC="Design/hermes-appicon-master-1254.png"
ICONSET="$REPO/HermesFleetApp/Assets.xcassets/AppIcon.appiconset"
DESIGN="$REPO/Design"
PASS=0; FAIL=0
note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

note "0. Source artwork sanity"
[ -f "$SRC" ] && ok "source exists: $SRC" || { bad "source missing: $SRC"; exit 1; }
sips -g pixelWidth -g pixelHeight -g hasAlpha "$SRC" | sed 's/^/  /'

note "1. Version the master artwork in-repo (Design/)"
mkdir -p "$DESIGN"
cp -p "$REPO/$SRC" "$DESIGN/hermes-appicon-master-1254.png" 2>/dev/null || true
[ -f "$DESIGN/hermes-appicon-master-1254.png" ] && ok "master copied to Design/" || bad "master copy failed"

note "2. Resize to exactly 1024x1024 (full-bleed square, opaque)"
mkdir -p /tmp/x3_icon
cp "$SRC" /tmp/x3_icon/icon-1024.png
sips -z 1024 1024 /tmp/x3_icon/icon-1024.png >/dev/null 2>&1 || { bad "sips resize failed"; exit 1; }
W=$(sips -g pixelWidth /tmp/x3_icon/icon-1024.png | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight /tmp/x3_icon/icon-1024.png | awk '/pixelHeight/{print $2}')
A=$(sips -g hasAlpha /tmp/x3_icon/icon-1024.png | awk '/hasAlpha/{print $2}')
[ "$W" = "1024" ] && [ "$H" = "1024" ] && ok "size 1024x1024 (got ${W}x${H})" || bad "size wrong: ${W}x${H}"
[ "$A" = "no" ] && ok "no alpha channel (App Store-safe)" || bad "ALPHA PRESENT — App Store rejects"

note "3. Corner scan: no baked near-white border ring"
if python3 "$WS/png_corner_probe.py" /tmp/x3_icon/icon-1024.png; then
  ok "corners carry artwork (no border ring)"
else
  bad "corner scan failed — check output above"
fi

note "4. Wire into AppIcon.appiconset"
cp /tmp/x3_icon/icon-1024.png "$ICONSET/icon-1024.png"
[ -f "$ICONSET/icon-1024.png" ] && ok "icon-1024.png swapped into appiconset" || bad "icon copy failed"
python3 - "$ICONSET/Contents.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
imgs = c.get("images", [])
ok_shape = any(
    i.get("filename") == "icon-1024.png"
    and i.get("idiom") == "universal"
    and i.get("platform") == "ios"
    and i.get("size") == "1024x1024"
    for i in imgs
)
print("  Contents.json entries:", json.dumps(imgs))
sys.exit(0 if ok_shape else 1)
PY
[ $? -eq 0 ] && ok "Contents.json: single-size universal 1024 icon wired" || bad "Contents.json wrong shape"

printf '\n=== RESULT: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
