#!/bin/bash
# RT4 compile check — regenerate the project and build for testing (no test
# execution) to catch any compile errors in the edited sources quickly.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
echo "=== RT4 compile check ==="
echo "sha: $(git rev-parse --short HEAD)"
xcodegen generate >/tmp/rt4_cc_xcodegen.log 2>&1 || { echo "xcodegen FAILED"; tail -5 /tmp/rt4_cc_xcodegen.log; exit 2; }
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ [(].*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/RT4Compile"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$DD" \
  build-for-testing >/tmp/rt4_cc.log 2>&1
RC=$?
grep -E "error:|BUILD SUCCEEDED|BUILD FAILED|warning: .*unused" /tmp/rt4_cc.log | tail -30
echo "=== compile exit=$RC (0 = BUILD SUCCEEDED) ==="
exit $RC
