#!/bin/bash
# i16 evidence: baseline H1AppLockUITests standalone, N iterations on hgoal-i16.
# Args: N (iterations), OUTDIR
set -u
N=${1:-5}
OUT=${2:-/tmp/hgoal/i16-evidence/local/baseline}
UDID=hgoal-i16-UDID-redacted
mkdir -p "$OUT"
cd /tmp/hgoal/i16-evidence
for i in $(seq 1 "$N"); do
  echo "=== BASELINE RUN $i/$(seq 1 $N | tail -1) $(date -u +%H:%M:%S) ==="
  rm -rf "$OUT/run$i.xcresult"
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
    -skipMacroValidation -resultBundlePath "$OUT/run$i.xcresult" \
    -only-testing:HermesFleetAppUITests/H1AppLockUITests test \
    > "$OUT/run$i.log" 2>&1
  rc=$?
  summary=$(grep -E "Executed .* tests" "$OUT/run$i.log" | tail -1)
  echo "run$i rc=$rc | $summary"
done
echo "BASELINE DONE"
