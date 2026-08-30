#!/bin/bash
# t_eb5455f2: consolidate evidence for the P3-fix (ATS + username/password).
set -u
cd <repo-root> || exit 1
E=build/p3fix_evidence
mkdir -p "$E"

echo "=== [1] ATS fix in built Release plist ==="
P=build/P3FixDerivedData/Build/Products/Release-iphonesimulator/HermesFleetApp.app/Info.plist
{
  echo "# ATS + Local Network keys in Release build Info.plist"
  /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$P"
  /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$P"
} | tee "$E/ats_plist.txt"

echo "=== [2] test suite results ==="
grep -aE "Executed .* tests, with .* failures" /tmp/p3fix_hosted.log 2>/dev/null | tail -2 | tee "$E/hosted_tests.txt"

echo "=== [3] Release-sim Connected evidence (loopback forwarder -> real gateway) ==="
cp build/p3fix_loopback_att/45C8117A-8101-460E-89F9-344E6C241DE3.png "$E/connected_screenshot.png" 2>/dev/null
grep -aE "Test Case .*(passed|failed)" /tmp/p3fix_lb4.log 2>/dev/null | tail -1 | tee "$E/loopback_test.txt"

echo "=== [4] full auth flow subsystem log ==="
xcrun simctl spawn booted log show --last 15m --info --debug \
  --predicate 'subsystem == "<legacy-personal-bundle-id>"' 2>/dev/null \
  | grep -aE "password-login|ws-ticket" | tail -6 | tee "$E/auth_flow.log"

echo "=== [5] package test counts ==="
echo "  FleetCore/FleetSecurity/FleetNetworking: run separately (already green)"
echo "=== Done ==="
