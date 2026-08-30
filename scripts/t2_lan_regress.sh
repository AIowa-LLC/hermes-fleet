#!/bin/bash
# t_f54b722e: isolation experiment — run the KNOWN-PASSING P3 LAN gateway UI
# test against the CURRENT build (with the T2 ATS change). If the LAN gateway
# still reaches Connected on the simulator, the hang is tailnet-specific
# (100.x gating); if it ALSO hangs, the regression is general.
set -u
REPO=<repo-root>
cd "$REPO" || exit 1
SIM="iPhone 17 Pro"
DEST="platform=iOS Simulator,name=${SIM},OS=latest"
DD=build/T2DerivedData
UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$UDID" ] || { echo "no booted sim"; exit 1; }

# The current build's UI bundle was built with -only-testing T2, but
# test-without-building can still select the P3 test class if it's compiled
# in (it is — all UITest sources compile together). Reinstall the app fresh.
BUNDLE=<legacy-personal-bundle-id>
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$DD/Build/Products/Release-iphonesimulator/HermesFleetApp.app"

echo "=== run P3 LAN test (regression) against current build ==="
set -o pipefail
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination "$DEST" -derivedDataPath "$DD" \
  -resultBundlePath build/t2_lanregress.xcresult \
  -only-testing:HermesFleetAppUITests/P3FixLANGatewayUITests \
  test-without-building 2>&1 | grep -aE "Test Case .*(passed|failed)|Executed 1 test|error:|TEST EXECUTE" | tail -8
echo "EXIT=${PIPESTATUS[0]}"
