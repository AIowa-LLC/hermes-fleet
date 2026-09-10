#!/bin/bash
# i12-repro: repeat FOS8 Latest-control test; record per-run pass/fail + xcresult path
set -u
cd /tmp/hgoal/i12-repro
SIM="hgoal-i12"
DEST="platform=iOS Simulator,name=${SIM}"
PROJ="HermesFleetApp.xcodeproj"
SCHEME="HermesFleetApp"
DD="build/C1Ui"
TEST="HermesFleetAppUITests/FOS8AccessibilityUITests/testGroupConversationShowsLatestControlWhenReadingHistory"
mkdir -p results
SUMMARY=results/summary.tsv
echo -e "run\texit\tresult\tstart\tend\txcresult" > "$SUMMARY"
N="${1:-8}"
for i in $(seq 1 "$N"); do
  RB="results/fos8latest_run${i}.xcresult"
  rm -rf "$RB"
  S=$(date +%s)
  xcodebuild test-without-building -project "$PROJ" -scheme "$SCHEME" \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:"$TEST" -skipMacroValidation \
    -resultBundlePath "$RB" > "results/fos8latest_run${i}.log" 2>&1
  RC=$?
  E=$(date +%s)
  RES=$(grep -c "Test Case.*passed" "results/fos8latest_run${i}.log" | tr -d ' ')
  echo -e "run${i}\t${RC}\tpassed_lines=${RES}\t${S}\t${E}\t${RB}" >> "$SUMMARY"
  echo "RUN $i done rc=${RC} elapsed=$((E-S))s"
done
echo ALLDONE
