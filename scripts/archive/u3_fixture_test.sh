#!/bin/bash
# U3 fixture full-loop test run (iOS Simulator).
# Run with: bash scripts/u3_fixture_test.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU3Fixture"

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests/ConversationFixtureLoopTests \
    test 2>&1 | grep -E 'Test Case|Test Suite|error:|XCTAssert|BUILD' | tail -60
