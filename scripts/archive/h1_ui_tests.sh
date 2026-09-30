#!/usr/bin/env bash
# h1_ui_tests.sh — H1 (R4): run ONLY the new H1AppLockUITests on the simulator
# (DEBUG build, scripted fleet). These set the H1 launch env
# (HERMES_FLEET_APP_LOCK / HERMES_FLEET_LOCK_AUTH) so the lock gate is
# deterministic: cold-launch requires auth, failed biometric → passcode
# fallback, and the toggle persists across restart.
# Runs via `bash scripts/h1_ui_tests.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "ABORT: not on main (on '$BRANCH')." >&2
  exit 2
fi

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/H1DerivedData"

echo "=== xcodebuild: H1AppLockUITests (UI, Debug) ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppUITests/H1AppLockUITests test \
    > /tmp/h1_ui.log 2>&1; then
  echo "H1 UI TESTS SUCCEEDED"
  grep -E "Test Case.*H1AppLock|Test Suite 'H1AppLock|Executed .* tests" /tmp/h1_ui.log | tail -12
else
  echo "H1 UI TESTS FAILED — tail of log:"
  grep -E "error:|failed|Executed|Test Case.*failed" /tmp/h1_ui.log | tail -40
  exit 1
fi
