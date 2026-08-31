#!/bin/bash
# RT4 GREEN — run the new RT4 regression tests on the FIXED source (current
# worktree). All must PASS. Run with: bash scripts/rt4_green.sh
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
echo "=== RT4 GREEN on fix ==="
echo "sha: $(git rev-parse --short HEAD)  branch: $(git rev-parse --abbrev-ref HEAD)"

grep -q "allRows.append(row)" Packages/FleetUI/Sources/FleetUI/ConversationViewModel.swift \
  && echo "(transcript windowing fix present)" || { echo "window fix NOT found — abort"; exit 2; }

xcodegen generate >/tmp/rt4_xcodegen.log 2>&1 || { echo "xcodegen FAILED"; tail -5 /tmp/rt4_xcodegen.log; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ [(].*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/RT4Green"

echo "--- unit: P2-3 + P2-8 (ConversationViewModelTests) ---"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReappearAfterTeardownRestartsSubscriptions \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testTranscriptWindowIsCappedAndPreservesAuthoritativeHistory \
  test >/tmp/rt4_green_vm.log 2>&1
RC1=$?
grep -E "Test Case .* (passed|failed)|error:|BUILD FAILED" /tmp/rt4_green_vm.log | tail -12
echo "  unit P2-3/P2-8 exit=$RC1"

echo "--- unit: RT4LogicRegressionTests (P2-5/P2-7/P3-1) ---"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppTests/RT4LogicRegressionTests \
  test >/tmp/rt4_green_logic.log 2>&1
RC2=$?
grep -E "Test Case .* (passed|failed)|error:|BUILD FAILED" /tmp/rt4_green_logic.log | tail -12
echo "  unit RT4Logic exit=$RC2"

echo "--- UI: RT4 suites ---"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppUITests/RT4RosterEmptyStateUITests \
  -only-testing:HermesFleetAppUITests/RT4FormSaveFailureUITests \
  -only-testing:HermesFleetAppUITests/RT4VoiceOverUITests \
  test >/tmp/rt4_green_ui.log 2>&1
RC3=$?
grep -E "Test Case .* (passed|failed)|error:|BUILD FAILED|failed -" /tmp/rt4_green_ui.log | tail -15
echo "  UI exit=$RC3"

echo ""
echo "=== GREEN summary: unit=$RC1 logic=$RC2 ui=$RC3 (0 = PASS) ==="
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ]; then
  echo "ALL GREEN"
else
  echo "SOME RED — inspect logs above"
fi
