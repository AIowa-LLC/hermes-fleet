#!/bin/bash
# U4 G1 debt: run the XCUITest happy-path suite on the booted iOS Simulator.
# Evidence: xcodegen regenerates (UI test target present), then the
# HermesFleetAppUITests bundle runs against the DEBUG scripted fleet.
# TOOLING: script file only, run with `bash scripts/u4_xcuitest.sh`
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

note "xcodegen (UI test target must be present)"
if xcodegen generate >/tmp/u4_ui_xcodegen.log 2>&1 \
   && grep -q 'HermesFleetAppUITests' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated with HermesFleetAppUITests target"
else
  bad "xcodegen / UI target missing"; tail -5 /tmp/u4_ui_xcodegen.log
fi

SIM_UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -E 'iPhone 17 Pro \(' | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$SIM_UDID" ]; then
  bad "no booted iPhone 17 Pro simulator"
else
  ok "booted simulator: $SIM_UDID"
fi

DEST="platform=iOS Simulator,id=$SIM_UDID"
DD="$REPO/build/DerivedDataU4UITests"

note "xcodebuild test — HermesFleetAppUITests (happy path)"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppUITests \
    test >/tmp/u4_ui_test.log 2>&1; then
  ok "xcodebuild UI TEST SUCCEEDED"
else
  bad "xcodebuild UI test FAILED"; grep -E 'error:|failed|Test Suite|XCTAssert' /tmp/u4_ui_test.log | tail -30
fi

note "UI test cases (result lines)"
grep -E "Test Case '-\[HermesFleetAppUITests" /tmp/u4_ui_test.log | tail -12 || true
grep -E "Test Suite 'HermesFleetAppUITests" /tmp/u4_ui_test.log | tail -4 || true

printf '\n=====================================\n'
printf 'U4 XCUITest: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
