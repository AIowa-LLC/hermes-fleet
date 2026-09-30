#!/bin/bash
# U3 full hosted test run — ALL app-level tests on the iOS Simulator
# (regression check that U1/U2 suites stay green alongside U3).
# Run with: bash scripts/u3_hosted_all.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU3All"

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    test 2>&1 | grep -E 'Test Suite|Test Case.*(passed|failed)|error:|BUILD' | tail -140
