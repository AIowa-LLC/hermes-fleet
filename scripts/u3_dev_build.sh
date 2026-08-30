#!/bin/bash
# U3 dev iteration helper — build the host packages in dependency order, then
# compile the app (including FleetUI) for the iOS Simulator. FleetUI is NOT
# host-buildable on macOS (insetGrouped / SwiftUI iOS-only modifiers), matching
# the M0–U2 validation scripts which build FleetUI only via xcodebuild.
# Run with: bash scripts/u3_dev_build.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

echo "=== FleetCore (host) ==="
(cd Packages/FleetCore && swift build) 2>&1 | tail -20

echo "=== FleetNetworking (host) ==="
(cd Packages/FleetNetworking && swift build) 2>&1 | tail -20

echo "=== FleetSecurity (host) ==="
(cd Packages/FleetSecurity && swift build) 2>&1 | tail -10

echo "=== FleetPersistence (host) ==="
(cd Packages/FleetPersistence && swift build) 2>&1 | tail -10

echo "=== xcodegen generate ==="
xcodegen generate 2>&1 | tail -5

echo "=== xcodebuild build (iOS Simulator, app incl. FleetUI + tests) ==="
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU3Dev"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build 2>&1 | grep -E 'error:|warning: [^n]|BUILD SUCCEEDED|BUILD FAILED' | tail -30

echo "=== done ==="
