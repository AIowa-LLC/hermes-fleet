#!/bin/bash
# RT3 P1-5 RED — conversation initial-recovery regression tests on CURRENT
# (unfixed) ConversationViewModel. Expect: BOTH new tests FAIL (reconnect sets
# .ready without re-opening session/subscriptions → dead composer).
# Run with: bash scripts/rt3_p15_red.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
echo "=== RED: P1-5 conversation initial-recovery on unfixed VM ==="
echo "worktree: $REPO  branch: $(git rev-parse --abbrev-ref HEAD)  sha: $(git rev-parse --short HEAD)"
grep -n "guard !hasStarted else { return }" "$REPO/Packages/FleetUI/Sources/FleetUI/ConversationViewModel.swift" \
  && echo "(old start() guard present → unfixed VM confirmed)" || echo "(unfixed VM guard NOT found — abort)"
xcodegen generate >/tmp/rt3_xcodegen.log 2>&1 || { echo "xcodegen FAILED"; tail -5 /tmp/rt3_xcodegen.log; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$REPO/build/RT3RedP15" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReconnectAfterInitialConnectFailureRecoversToLiveSession \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReconnectAfterInitialOpenFailureReopensSession \
  test >/tmp/rt3_p15_red.log 2>&1
RESULT=$?
echo "--- relevant log lines ---"
grep -E "Test Case|Test Suite|error:|failed" /tmp/rt3_p15_red.log | tail -30
echo "=== exit: $RESULT (nonzero = RED reproduced) ==="
