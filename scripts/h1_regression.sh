#!/usr/bin/env bash
# h1_regression.sh — H1 (R4): regression gate. Runs the deterministic DEBUG UI
# suites (HappyPath, Reconnect, S3) plus the new H1 lock suite, so the lock
# gate provably does not break the existing fleet UI automation.
# Runs via `bash scripts/h1_regression.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "ABORT: not on main (on '$BRANCH')." >&2
  exit 2
fi

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/H1DerivedData"

SUITES=(
  "HermesFleetAppUITests/HermesFleetHappyPathUITests"
  "HermesFleetAppUITests/HermesFleetReconnectUITests"
  "HermesFleetAppUITests/S3CleartextWarningUITests"
  "HermesFleetAppUITests/H1AppLockUITests"
)

fail=0
for suite in "${SUITES[@]}"; do
  echo "=== $suite ==="
  log="/tmp/h1_reg_${suite##*/}.log"
  if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
      -destination "$DEST" -derivedDataPath "$DD" \
      -only-testing:"$suite" test \
      > "$log" 2>&1; then
    echo "PASS: $suite"
    grep -E "Test Suite '$suite' (passed|failed)|Executed .* tests" "$log" | tail -2
  else
    echo "FAIL: $suite"
    grep -E "Test Case.*failed|error:" "$log" | tail -10
    fail=1
  fi
done

echo "========================"
if [ "$fail" -eq 0 ]; then
  echo "H1 REGRESSION GATE: ALL SUITES GREEN"
else
  echo "H1 REGRESSION GATE: FAILURES PRESENT"
  exit 1
fi
