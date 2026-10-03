#!/bin/bash
# Copy exported L1 xcresult screenshots to stable evidence filenames.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
SRC=build/l1/attachments_1788073234
OUT=build/l1
mkdir -p "$OUT"
cp "$SRC/BF7B5020-B10A-4BC0-8191-20E5B61B60FD.png" "$OUT/l1-step1-open-gateways.png"
cp "$SRC/EC174061-DBA8-4115-AB7C-D193559C1A98.png" "$OUT/l1-step2-add-form-filled.png"
cp "$SRC/66B9FE8E-D931-4FF5-AD1B-F2EE3BFE1BC7.png" "$OUT/l1-step2-add-form-strategy-token.png"
cp "$SRC/EDA33820-745F-4FFD-BFC5-F177144C1A54.png" "$OUT/l1-step3-gateway-added-row.png"
cp "$SRC/24D80F27-9D04-48EB-B167-5F02E41D9789.png" "$OUT/l1-step3-test-connection-result.png"
cp "$SRC/DAF4E958-F7C2-4BA2-9778-1901F385A87B.png" "$OUT/l1-step4-roster-live.png"
cp "$SRC/58663D26-F7CF-4D67-B041-27C6E198D456.png" "$OUT/l1-final-state.png"
ls -la "$OUT"/l1-*.png
echo "=== copied ==="
