#!/bin/bash
# t_f54b722e: final validation on the CLEAN committed state — hosted app tests
# + the T2 tailnet UI test (instrumentation reverted, only Info.plist ATS fix +
# test + scripts remain). Must be green before commit.
set -u
REPO=<repo-root>
cd "$REPO" || exit 1
DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
DD=build/T2FinalDerivedData

echo "=== [1/3] hosted app tests (HermesFleetAppTests) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppTests test 2>&1 \
  | grep -aE "Executed [0-9]+ tests, with|TEST EXECUTE|error:" | tail -4
echo "  hosted tests rc=${PIPESTATUS[0]}"

echo "=== [2/3] T2 tailnet UI test (final state) ==="
bash scripts/t2_uitest_run.sh 2>&1 | grep -aE "Test Case .*(passed|failed)|Executed 1 test|BUILD|error:" | tail -6
echo "  uitest rc=${PIPESTATUS[0]}"

echo "=== [3/3] evidence summary ==="
cat build/t2_evidence/uitest_result.txt 2>/dev/null | head -4
echo "=== Done ==="
