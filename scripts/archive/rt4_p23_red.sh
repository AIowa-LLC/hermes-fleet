#!/bin/bash
# Re-verify the P2-3 regression test is still RED on the pre-fix base (a1c43bb)
# after the teardown-semantics correction: on OLD code teardown() cancels the
# event task and start() early-returns on reappear, so a pushed event is dropped.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE=a1c43bb
WORK=/tmp/rt4-red-p23
git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
git -C "$REPO" worktree add --detach "$WORK" "$BASE" >/tmp/rt4_p23_wt.log 2>&1 || { echo "worktree add FAILED"; tail -5 /tmp/rt4_p23_wt.log; exit 2; }
cp "$REPO/HermesFleetAppTests/ConversationViewModelTests.swift" "$WORK/HermesFleetAppTests/"
cd "$WORK"
xcodegen generate >/tmp/rt4_p23_xg.log 2>&1 || { echo "xcodegen FAILED"; tail -5 /tmp/rt4_p23_xg.log; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ [(].*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
echo "=== P2-3 RED re-verify on base $BASE ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$WORK/build" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReappearAfterTeardownRestartsSubscriptions \
  test >/tmp/rt4_p23_red.log 2>&1
RC=$?
grep -E "Test Case .* (passed|failed)|error:" /tmp/rt4_p23_red.log | tail -5
echo "  exit=$RC (nonzero = RED reproduced)"
git -C "$REPO" worktree remove --force "$WORK" 2>/dev/null || true
