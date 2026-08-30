#!/bin/bash
# L1: re-export xcresult attachments to a fresh directory (no destructive ops).
set -u
cd ~/code/hermes-fleet-ios
STAMP=$(date +%s)
OUT="build/l1/attachments_$STAMP"
mkdir -p "$OUT"
XC=$(ls -dt build/DerivedDataL1/Logs/Test/*.xcresult | head -1)
echo "xcresult: $XC"
echo "out: $OUT"
xcrun xcresulttool export attachments --path "$XC" --output-path "$OUT" 2>&1 | tail -3
python3 - "$OUT" <<'PYEOF'
import json, os, sys
out = sys.argv[1]
m = json.load(open(os.path.join(out, "manifest.json")))
for item in m:
    fn = item.get("exportedFileName")
    size = os.path.getsize(os.path.join(out, fn)) if fn and os.path.exists(os.path.join(out, fn)) else "?"
    print(f"{item.get('suggestedHumanReadableName',''):60s} {fn}  ({size} bytes)")
PYEOF
echo "OUT_DIR=$OUT"
