#!/bin/bash
# i16 evidence: LOCAL REPRO of the hosted 5-shard condition.
# Shard 1/5 order at dfd4ad7: [01] HermesFleetHappyPathUITests, [02] H1AppLockUITests
# on the SAME simulator, same derived-data, serial xcodebuild invocations
# (exactly how c1_ui_matrix.sh runs them).
set -u
OUT=/tmp/hgoal/i16-evidence/local/repro
UDID=hgoal-i16-UDID-redacted
mkdir -p "$OUT"
cd /tmp/hgoal/i16-evidence
run_suite() {  # cls outname
  local cls=$1 nm=$2
  rm -rf "$OUT/$nm.xcresult"
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
    -skipMacroValidation -resultBundlePath "$OUT/$nm.xcresult" \
    -only-testing:"HermesFleetAppUITests/${cls}UITests" test \
    > "$OUT/$nm.log" 2>&1
  local rc=$?
  echo "$nm rc=$rc | $(grep -E 'Executed .* tests' "$OUT/$nm.log" | tail -1)"
}

ITER=${1:-1}
for i in $(seq 1 "$ITER"); do
  echo "=== REPRO ITERATION $i $(date -u +%H:%M:%S) ==="
  run_suite HermesFleetHappyPath "iter${i}_01_happypath"
  run_suite H1AppLock "iter${i}_02_h1applock"
done
echo "REPRO DONE"
