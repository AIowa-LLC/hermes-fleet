#!/bin/bash
# T3 (t_94ee6012): regenerate project + build all packages + app (sim).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== xcodegen ==="
xcodegen generate

echo "=== swift test: FleetCore ==="
(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "=== swift test: FleetSecurity ==="
(cd Packages/FleetSecurity && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "=== swift test: FleetNetworking ==="
(cd Packages/FleetNetworking && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "=== swift test: FleetPersistence ==="
(cd Packages/FleetPersistence && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)

echo "=== app build (simulator Debug) ==="
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
echo "sim: $SIM_NAME"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,name=$SIM_NAME,OS=latest" \
  -derivedDataPath build/T3DerivedData build 2>&1 | tail -3
