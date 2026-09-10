#!/bin/bash
# C1 units phase — FULL hosted app unit bundle (HermesFleetAppTests) on the
# iOS Simulator, as its own xcodebuild invocation.
#
# P1-7 fix (t_ea9f4624): NEVER mix a bare-bundle `-only-testing:<Bundle>`
# selector with class-level selectors in ONE invocation — xcodebuild then
# runs ONLY the class-level selections and silently drops the bare bundle.
# Units (bare bundle) and UI suites (class-level) are therefore separate
# invocations; UI lives in c1_ui_matrix.sh.
#
# CODE_SIGNING_ALLOWED must NOT be set to NO: the Keychain-backed
# ModuleBoundaryTests require the keychain-access-groups entitlement that
# only gets embedded when the app is signed. Simulator builds ad-hoc sign.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/C1Ci"
# SwiftStreamingMarkdown v0.7.0 transitively uses the reviewed Equatable
# macro. Headless CI has no Xcode UI step to approve that pinned macro, so
# explicitly bypass fingerprint validation; this does not bypass macro
# execution or package resolution.
XC=(-project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" -skipMacroValidation)

printf '\n=== xcodebuild UNIT tests (HermesFleetAppTests) ===\n'
if xcodebuild "${XC[@]}" -only-testing:HermesFleetAppTests \
    build test >/tmp/c1_xctest_unit.log 2>&1; then
  ULINE=$(grep -E 'Executed .* tests' /tmp/c1_xctest_unit.log | tail -1)
  printf 'PASS  xcodebuild UNIT tests (HermesFleetAppTests) SUCCEEDED — %s\n' "$ULINE"
  echo "  $ULINE"
  exit 0
else
  printf 'FAIL  xcodebuild UNIT tests (HermesFleetAppTests) FAILED\n'
  grep -E 'error:|failed|Test Suite|Executed' /tmp/c1_xctest_unit.log | tail -25
  exit 1
fi
