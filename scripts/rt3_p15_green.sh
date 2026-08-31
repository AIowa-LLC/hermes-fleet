#!/bin/bash
# RT3 P1-5 GREEN — conversation initial-recovery regression tests on FIXED VM.
# Expect: BOTH tests PASS (reconnect now opens session + starts subscriptions).
# Run with: bash scripts/rt3_p15_green.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
echo "=== GREEN: P1-5 conversation initial-recovery on fixed VM ==="
echo "worktree: $REPO  branch: $(git rev-parse --abbrev-ref HEAD)  sha: $(git rev-parse --short HEAD)"
grep -q "private func connectAndOpen() async -> Bool" "$REPO/Packages/FleetUI/Sources/FleetUI/ConversationViewModel.swift" \
  && echo "(connectAndOpen present → fixed VM confirmed)" || { echo "(fix NOT found — abort)"; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$REPO/build/RT3GreenP15" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReconnectAfterInitialConnectFailureRecoversToLiveSession \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests/testReconnectAfterInitialOpenFailureReopensSession \
  test >/tmp/rt3_p15_green.log 2>&1
RESULT=$?
echo "--- relevant log lines ---"
grep -E "Test Case|Test Suite|error:|failed" /tmp/rt3_p15_green.log | tail -30
echo "=== exit: $RESULT (0 = GREEN) ==="
