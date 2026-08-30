#!/bin/bash
# U3 hosted test run — xcodebuild test on the iOS Simulator (Conversation
# view model scripted tests + in-process fixture full-loop tests + module
# boundary). Run with: bash scripts/u3_dev_test.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU3DevTest"

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests/ConversationViewModelTests \
    -only-testing:HermesFleetAppTests/ConversationFixtureLoopTests \
    -only-testing:HermesFleetAppTests/ModuleBoundaryTests \
    test 2>&1 | grep -E 'Test Suite|Test Case|error:|passed|failed|BUILD' | tail -120
