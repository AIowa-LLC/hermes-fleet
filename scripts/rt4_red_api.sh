#!/bin/bash
# RT4 compile-RED — demonstrate that the P2-5/P2-7/P3-1 logic-regression tests
# CANNOT COMPILE against the pre-fix source (the new public APIs they reference
# — FleetRosterView.sections(from:), ConversationRow.accessibilityLabel,
# FleetSessionDateText — do not exist on base a1c43bb). This proves the
# regression tests cannot pass on old code (compile-time RED).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE=a1c43bb
WORK=/tmp/rt4-red-api
git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git -C "$REPO" worktree add --detach "$WORK" "$BASE" >/tmp/rt4_api_wt.log 2>&1 || { echo "worktree add FAILED"; tail -5 /tmp/rt4_api_wt.log; exit 2; }
cp "$REPO/HermesFleetAppTests/RT4LogicRegressionTests.swift" "$WORK/HermesFleetAppTests/"
cd "$WORK"
xcodegen generate >/tmp/rt4_api_xcodegen.log 2>&1 || { echo "xcodegen FAILED"; tail -5 /tmp/rt4_api_xcodegen.log; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ [(].*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
echo "=== compile-RED: RT4LogicRegressionTests on base $BASE ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$WORK/build" \
  -only-testing:HermesFleetAppTests/RT4LogicRegressionTests \
  build-for-testing >/tmp/rt4_api.log 2>&1
RC=$?
echo "--- relevant compile errors ---"
grep -E "error:" /tmp/rt4_api.log | head -15
echo "=== compile exit=$RC (nonzero = compile RED reproduced) ==="
git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
