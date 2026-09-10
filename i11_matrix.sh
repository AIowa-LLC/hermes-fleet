#!/bin/bash
# i11-repro run matrix: P0_7SessionStateMachineUITests x N on hgoal-i11 sim
set -u
cd /tmp/hgoal/i11-repro
UDID=2D2DE77F-68B9-400F-964D-8B614DAAC35C
RESULTS=/tmp/hgoal/i11-repro/build/i11-runs
mkdir -p "$RESULTS"
N="${1:-8}"
SUMMARY="$RESULTS/summary.tsv"
echo -e "run\texit\ttests\tfailures\tstarted\twall_s" > "$SUMMARY"
for i in $(seq 1 "$N"); do
  START=$(date +%s)
  HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
  rm -rf "$RESULTS/run$i.xcresult"
  xcrun simctl bootstatus $UDID -b >/dev/null 2>&1
  xcodebuild test \
    -project HermesFleetApp.xcodeproj \
    -scheme HermesFleetApp \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/C1Ui \
    -only-testing:HermesFleetAppUITests/P0_7SessionStateMachineUITests \
    -skipMacroValidation \
    -resultBundlePath "$RESULTS/run$i.xcresult" \
    > "$RESULTS/run$i.log" 2>&1
  EXIT=$?
  WALL=$(( $(date +%s) - START ))
  # Test suite summary lines
  LINE=$(grep -E "Test Suite 'P0_7SessionStateMachineUITests\.xctest'.*(passed|failed)" "$RESULTS/run$i.log" | tail -1)
  echo "[run $i] exit=$EXIT wall=${WALL}s $LINE" >> "$RESULTS/progress.log"
  echo -e "run$i\t$EXIT\t$HUMAN\t${WALL}\t$LINE" >> "$SUMMARY"
done
echo "MATRIX DONE $(date '+%Y-%m-%d %H:%M:%S')" >> "$RESULTS/progress.log"
