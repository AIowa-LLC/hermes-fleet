#!/bin/bash
# RT3 P1-5 GREEN (final) — full ConversationViewModelTests suite on FIXED VM.
# Expect: ALL ConversationViewModelTests pass, including the 2 new P1-5
# regressions and the pre-existing start/reconnect/replay/reauth tests.
# Run with: bash scripts/rt3_p15_green_full.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
echo "=== GREEN (full): ConversationViewModelTests on fixed VM ==="
echo "worktree: $REPO  branch: $(git rev-parse --abbrev-ref HEAD)  sha: $(git rev-parse --short HEAD)"
grep -q "private func connectAndOpen() async -> Bool" "$REPO/Packages/FleetUI/Sources/FleetUI/ConversationViewModel.swift" \
  && echo "(connectAndOpen present → fixed VM confirmed)" || { echo "(fix NOT found — abort)"; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$REPO/build/RT3GreenP15Full" \
  -only-testing:HermesFleetAppTests/ConversationViewModelTests \
  test >/tmp/rt3_p15_green_full.log 2>&1
RESULT=$?
echo "--- summary ---"
grep -E "Test Suite 'ConversationViewModelTests' (passed|failed)|Executed .* tests" /tmp/rt3_p15_green_full.log | tail -8
echo "=== exit: $RESULT (0 = GREEN) ==="
