#!/bin/bash
# t_eb5455f2: final full validation — regenerate project, build, hosted tests,
# and all package suites. Must all be green before commit.
set -u
cd <repo-root> || exit 1
DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
DD=build/FinalDerivedData

echo "=== [1/5] xcodegen generate ==="
xcodegen generate 2>&1 | tail -1

echo "=== [2/5] build Release app (sim) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination "$DEST" -derivedDataPath "$DD" \
  build 2>&1 | grep -aE "BUILD (SUCCEEDED|FAILED)|error:" | tail -3

echo "=== [3/5] hosted app tests ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppTests test 2>&1 \
  | grep -aE "Executed [0-9]+ tests, with|TEST EXECUTE" | tail -3

echo "=== [4/5] package suites ==="
(cd Packages/FleetCore && swift test 2>&1 | grep -aE "Executed [0-9]+ tests, with" | tail -1)
(cd Packages/FleetSecurity && swift test 2>&1 | grep -aE "Executed [0-9]+ tests, with" | tail -1)
(cd Packages/FleetNetworking && swift test 2>&1 | grep -aE "Executed [0-9]+ tests, with" | tail -1)

echo "=== [5/5] ATS keys in Release build ==="
P="$DD/Build/Products/Release-iphonesimulator/HermesFleetApp.app/Info.plist"
/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$P" 2>/dev/null
/usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$P" 2>/dev/null
echo "=== Done ==="
