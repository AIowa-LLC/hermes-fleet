#!/bin/bash
# RT4 RED — demonstrate each new regression test FAILS on the PRE-FIX source
# (worktree at a1c43bb = main before RT4 edits). Run with: bash scripts/rt4_red.sh
#
# Three RED shapes, one per finding:
#   P2-3  testReappearAfterTeardownRestartsSubscriptions      -> RUNTIME RED (compiles on base; fails: no subs after reappear)
#   P2-8  testTranscriptWindowIsCappedAndPreservesAuthoritativeHistory -> RUNTIME RED (compiles on base; fails: transcript unbounded)
#   P2-5/P2-7/P3-1 RT4LogicRegressionTests                    -> COMPILE RED (new public APIs absent on base: sections(from:), accessibilityLabel, FleetSessionDateText)
#   P2-5 UI RT4RosterEmptyStateUITests                        -> RUNTIME RED (zero-bots knob ignored on base -> normal fleet -> no No-Bots state)
#   P2-6 UI RT4FormSaveFailureUITests                         -> RUNTIME RED (save-fail knob ignored on base -> sheet dismisses)
#   P2-7 UI RT4VoiceOverUITests                               -> RUNTIME RED (no accessibilityLabel on base -> no 'Assistant' label)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE=a1c43bb
WORK=/tmp/rt4-red-base
echo "=== RT4 RED on base $BASE ==="
echo "repo: $REPO  current sha: $(git -C "$REPO" rev-parse --short HEAD)"

git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git -C "$REPO" worktree add --detach "$WORK" "$BASE" >/tmp/rt4_red_wt.log 2>&1 || { echo "worktree add FAILED"; tail -5 /tmp/rt4_red_wt.log; exit 2; }

# Overlay ONLY the tests that compile against the base API surface (runtime
# REDs). The logic-regression file (new-API tests) is deliberately NOT copied
# here — its compile-RED is demonstrated separately below.
cp "$REPO/HermesFleetAppTests/ConversationViewModelTests.swift" "$WORK/HermesFleetAppTests/"
cp "$REPO/HermesFleetAppUITests/RT4RosterEmptyStateUITests.swift" "$WORK/HermesFleetAppUITests/"
cp "$REPO/HermesFleetAppUITests/RT4FormSaveFailureUITests.swift" "$WORK/HermesFleetAppUITests/"
cp "$REPO/HermesFleetAppUITests/RT4VoiceOverUITests.swift" "$WORK/HermesFleetAppUITests/"

cd "$WORK"
echo "--- xcodegen (base project) ---"
xcodegen generate >/tmp/rt4_red_xcodegen.log 2>&1 || { echo "xcodegen FAILED"; tail -5 /tmp/rt4_red_xcodegen.log; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ [(].*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"

run_unit() {
  local label=$1; shift
  echo ""
  echo "=== $label ==="
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$WORK/build" "$@" \
    test >/tmp/rt4_red_unit.log 2>&1
  local rc=$?
  grep -E "Test Case .* (passed|failed)|error:|BUILD FAILED" /tmp/rt4_red_unit.log | tail -10
  echo "  exit=$rc (nonzero = RED reproduced)"
  return $rc
}

run_ui() {
  local label=$1; shift
  echo ""
  echo "=== $label ==="
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$WORK/build" "$@" \
    test >/tmp/rt4_red_ui.log 2>&1
  local rc=$?
  grep -E "Test Case .* (passed|failed)|error:|BUILD FAILED|failed -" /tmp/rt4_red_ui.log | tail -10
  echo "  exit=$rc (nonzero = RED reproduced)"
  return $rc
}

# Runtime REDs (compile on base, fail at runtime).
run_unit "P2-3 reappear-restarts-subscriptions (expect FAIL on base)" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReappearAfterTeardownRestartsSubscriptions
run_unit "P2-8 transcript-window-capped (expect FAIL on base)" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testTranscriptWindowIsCappedAndPreservesAuthoritativeHistory
run_ui "P2-5 roster empty state (expect FAIL on base)" \
  -only-testing:HermesFleetAppUITests/RT4RosterEmptyStateUITests
run_ui "P2-6 form save failure (expect FAIL on base)" \
  -only-testing:HermesFleetAppUITests/RT4FormSaveFailureUITests
run_ui "P2-7 VoiceOver speaker label (expect FAIL on base)" \
  -only-testing:HermesFleetAppUITests/RT4VoiceOverUITests

# Compile RED: the logic-regression tests reference NEW public APIs that do not
# exist on base. Copy the file into the base worktree, REGENERATE the project so
# it joins the test target, then show the unit bundle cannot build -> the
# regression tests cannot even compile against old code.
echo ""
echo "=== P2-5/P2-7/P3-1 logic-regression tests (expect COMPILE failure on base) ==="
cp "$REPO/HermesFleetAppTests/RT4LogicRegressionTests.swift" "$WORK/HermesFleetAppTests/"
xcodegen generate >/tmp/rt4_red_xcodegen2.log 2>&1 || { echo "xcodegen2 FAILED"; tail -5 /tmp/rt4_red_xcodegen2.log; exit 2; }
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$WORK/build2" \
  -only-testing:HermesFleetAppTests/RT4LogicRegressionTests \
  build-for-testing >/tmp/rt4_red_api.log 2>&1
API_RC=$?
grep -E "error:|cannot find|has no member|'sections'|'accessibilityLabel'|'FleetSessionDateText'" /tmp/rt4_red_api.log | head -12
echo "  build-for-testing exit=$API_RC (nonzero = compile RED reproduced)"

echo ""
echo "=== RED summary ==="
echo "P2-3: runtime FAIL expected | P2-8: runtime FAIL expected"
echo "P2-5/P2-6/P2-7 UI: runtime FAIL expected (knobs/labels absent on base)"
echo "P2-5/P2-7/P3-1 logic: compile FAIL expected (new APIs absent on base)"
git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
