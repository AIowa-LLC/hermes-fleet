#!/bin/bash
# Copy exported L1-fix xcresult screenshots to stable evidence filenames under build/l1-fix/.
# The original L1 evidence under build/l1/ is left untouched.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
SRC="build/l1-fix-final-1788076017"
OUT="build/l1-fix"
mkdir -p "$OUT"
cp "$SRC/6DFE31F5-7CCC-4799-82A6-0224F17D2027.png" "$OUT/l1fix-step1-open-gateways.png"
cp "$SRC/A176CBA7-6B0E-46F6-8BB8-1393496220C5.png" "$OUT/l1fix-step2-add-form-filled.png"
cp "$SRC/DA17F23B-6AF8-4E21-8768-DFAA534CD15F.png" "$OUT/l1fix-step2-add-form-strategy-token.png"
cp "$SRC/099CC933-6DA2-4242-B72B-7A418D0FE60C.png" "$OUT/l1fix-step3-gateway-added-row.png"
cp "$SRC/39BF84CE-E259-4707-9D02-4E307D905562.png" "$OUT/l1fix-step3-test-connection-result.png"
cp "$SRC/AC737768-295E-4C1E-BEBB-2433035CD9A9.png" "$OUT/l1fix-step4-roster-live.png"
cp "$SRC/8A8F2454-F66B-4720-AB7D-171E4956E78F.png" "$OUT/l1fix-final-state.png"
ls -la "$OUT"/l1fix-*.png
echo "=== copied ==="
