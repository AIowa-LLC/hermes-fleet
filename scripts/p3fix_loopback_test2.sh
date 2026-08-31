#!/bin/bash
# t_eb5455f2: rerun the loopback-gateway Release-sim test (cleans stale bundles).
set -u
REPO=<repo-root>
cd "$REPO" || exit 1
for p in build/p3fix_loopback.xcresult build/p3fix_loopback_att; do
  [ -e "$p" ] && rm -r "$p"
done

# Ensure the forwarder is up (start if not).
if ! nc -z -w 2 127.0.0.1 9120; then
  python3 scripts/p3fix_tcp_forward.py 9120 > /tmp/p3fix_fwd.log 2>&1 &
  sleep 1
fi
nc -z -w 2 127.0.0.1 9120 && echo "forwarder UP" || { echo "forwarder DOWN"; exit 1; }
curl -sS -m 5 -o /dev/null -w "  loopback providers HTTP %{http_code}\n" "http://127.0.0.1:9120/api/auth/providers"

SIM="iPhone 17 Pro"
BUNDLE=com.aiowa.hermesfleet
xcrun simctl uninstall "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM" "build/P3FixDerivedData/Build/Products/Release-iphonesimulator/HermesFleetApp.app"

set -o pipefail
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination "platform=iOS Simulator,name=${SIM},OS=latest" \
  -derivedDataPath build/P3FixDerivedData \
  -resultBundlePath build/p3fix_loopback.xcresult \
  -only-testing:HermesFleetAppUITests/P3FixLoopbackGatewayUITests \
  test-without-building 2>&1 | tee build/p3fix_loopback.log | \
  grep -aE "Test Case .*(passed|failed)|Executed 1 test|error:|TEST EXECUTE" | tail -10
echo "EXIT=${PIPESTATUS[0]}"
