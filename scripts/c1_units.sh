#!/bin/bash
# C1 units phase: full hosted app unit bundle, separate from UI selectors.
# Never mix a bare-bundle selector with class-level UI selectors: Xcode can
# silently omit the bare bundle. Keep simulator ad-hoc signing enabled for
# the Keychain-backed ModuleBoundaryTests.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/C1Ci"

# Isolate each invocation so another worker/retry cannot overwrite evidence.
# Expose this exact directory, not a broad temporary-directory glob, to CI.
RESULT_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
UNIT_RESULTS=$(mktemp -d "${RESULT_ROOT%/}/hermes-c1-units.XXXXXX") || exit 1
UNIT_LOG="$UNIT_RESULTS/xcodebuild.log"
UNIT_RESULT="$UNIT_RESULTS/units.xcresult"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'diagnostics_dir=%s\n' "$UNIT_RESULTS" >> "$GITHUB_OUTPUT" || exit 1
fi
printf '  diagnostics: %s\n' "$UNIT_RESULTS"
{
  printf 'source_sha=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf unknown)"
  printf 'destination=%s\n' "$DEST"
  xcodebuild -version 2>&1 || true
} > "$UNIT_RESULTS/metadata.txt"

# SwiftStreamingMarkdown v0.7.0 brings the reviewed Equatable macro.
# The existing headless macro trust and simulator signing policy is unchanged.
XC=(-project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" -skipMacroValidation \
    -resultBundlePath "$UNIT_RESULT")

printf '\n=== xcodebuild UNIT tests (HermesFleetAppTests) ===\n'
if xcodebuild "${XC[@]}" -only-testing:HermesFleetAppTests \
    build test >"$UNIT_LOG" 2>&1; then
  ULINE=$(grep -E 'Executed .* tests' "$UNIT_LOG" | tail -1)
  printf 'PASS  xcodebuild UNIT tests (HermesFleetAppTests) SUCCEEDED: %s\n' "$ULINE"
  echo "  $ULINE"
  exit 0
else
  printf 'FAIL  xcodebuild UNIT tests (HermesFleetAppTests) FAILED\n'
  # Surface failed cases even when later passing suites displace the tail.
  grep -E 'Test Case .* (failed|Failure)|Executed .* with [1-9][0-9]* failure' \
    "$UNIT_LOG" | tail -20 || true
  grep -E 'error:|failed|Test Suite|Executed' "$UNIT_LOG" | tail -25 || true
  if [ -d "$UNIT_RESULT" ]; then
    printf '  xcresult: %s\n' "$UNIT_RESULT"
  fi
  exit 1
fi
