#!/bin/bash
# t_eb5455f2: consolidate evidence for the review handoff. Copies the Connected
# screenshot + test summaries into build/p3fix_evidence/.
set -u
cd <repo-root> || exit 1
E=build/p3fix_evidence
mkdir -p "$E"

# Connected screenshot from the loopback-forwarder Release-sim test (real gateway).
cp build/p3fix_loopback_att/45C8117A-8101-460E-89F9-344E6C241DE3.png "$E/connected_screenshot.png" 2>/dev/null && echo "  copied connected_screenshot.png"

# Test summaries
{
  echo "FleetCore: $(cd Packages/FleetCore && swift test 2>&1 | grep -aE 'Executed [0-9]+ tests, with' | tail -1)"
  echo "FleetSecurity: $(cd Packages/FleetSecurity && swift test 2>&1 | grep -aE 'Executed [0-9]+ tests, with' | tail -1)"
  echo "FleetNetworking: $(cd Packages/FleetNetworking && swift test 2>&1 | grep -aE 'Executed [0-9]+ tests, with' | tail -1)"
} | tee "$E/test_summary.txt"

# Release-sim loopback test result
grep -aE "Test Case .*(passed|failed)|Executed 1 test" /tmp/p3fix_lb4.log 2>/dev/null | tail -2 | tee "$E/loopback_test_result.txt"

# Auth flow subsystem log (proves app executed password-login -> ws-ticket against real gateway)
xcrun simctl spawn booted log show --last 20m --info --debug \
  --predicate 'subsystem == "<legacy-personal-bundle-id>"' 2>/dev/null \
  | grep -aE "password-login|ws-ticket" | tail -6 | tee "$E/auth_flow.log"

# ATS keys in Release build
P=build/FinalDerivedData/Build/Products/Release-iphonesimulator/HermesFleetApp.app/Info.plist
{
  echo "# ATS + Local Network keys"
  /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$P"
  /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$P"
} | tee "$E/ats_plist.txt"

echo "=== evidence dir ==="
ls -la "$E"
echo "=== Done ==="
