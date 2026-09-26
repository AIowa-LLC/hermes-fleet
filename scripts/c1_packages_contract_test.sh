#!/bin/bash
# Fail-closed contract tests for scripts/c1_packages.sh. A fake `swift` keeps
# these deterministic and verifies interrupted/partial output without building.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNNER=scripts/c1_packages.sh
tmpd=$(mktemp -d /tmp/c1_packages_contract.XXXXXX)
trap 'rm -rf "$tmpd"' EXIT
mkdir -p "$tmpd/bin"

cat >"$tmpd/bin/swift" <<'STUB'
#!/bin/bash
set -u
if [ "${1:-}" != test ]; then
  echo "unexpected swift invocation: $*" >&2
  exit 64
fi

package=${PWD##*/}
case "$package" in
  FleetCore) expected=619 ;;
  FleetNetworking) expected=545 ;;
  FleetPersistence) expected=39 ;;
  FleetSecurity) expected=37 ;;
  *) echo "unexpected package: $package" >&2; exit 65 ;;
esac

case "${SWIFT_CASE:-green}" in
  partial)
    [ "$package" = FleetNetworking ] && expected=11
    ;;
  no_summary)
    if [ "$package" = FleetNetworking ]; then
      echo "Build complete!"
      exit 0
    fi
    ;;
  test_failure)
    if [ "$package" = FleetNetworking ]; then
      printf '\t Executed %s tests, with 1 failure (1 unexpected) in 1.0 seconds\n' "$expected"
      exit 0
    fi
    ;;
  command_failure)
    if [ "$package" = FleetNetworking ]; then
      printf '\t Executed %s tests, with 0 failures (0 unexpected) in 1.0 seconds\n' "$expected"
      exit 9
    fi
    ;;
  green) ;;
  *) echo "unknown SWIFT_CASE" >&2; exit 66 ;;
esac

if [ "${SWIFT_CASE:-green}" = green ] && [ "$package" = FleetNetworking ]; then
  printf '\t Executed %s tests, with 2 tests skipped and 0 failures (0 unexpected) in 1.0 seconds\n' "$expected"
else
  printf '\t Executed %s tests, with 0 failures (0 unexpected) in 1.0 seconds\n' "$expected"
fi
STUB
chmod +x "$tmpd/bin/swift"

FAIL=0
check_case() {
  local mode=$1 expected_status=$2 output status
  if output=$(SWIFT_CASE="$mode" PATH="$tmpd/bin:$PATH" bash "$RUNNER" 2>&1); then
    status=0
  else
    status=$?
  fi

  if [ "$status" -ne "$expected_status" ]; then
    echo "FAIL  $mode (expected exit $expected_status, got $status)"
    echo "$output" | tail -12
    FAIL=$((FAIL+1))
    return
  fi

  if [ "$expected_status" -eq 0 ]; then
    if [ "$(printf '%s\n' "$output" | grep -c '^PASS  .* swift test complete')" -eq 4 ]; then
      echo "PASS  $mode"
    else
      echo "FAIL  $mode (not all four package suites passed)"
      echo "$output" | tail -12
      FAIL=$((FAIL+1))
    fi
  elif printf '%s\n' "$output" | grep -q 'FAIL  FleetNetworking swift test incomplete or NOT green'; then
    echo "PASS  $mode"
  else
    echo "FAIL  $mode (FleetNetworking failure was not reported)"
    echo "$output" | tail -12
    FAIL=$((FAIL+1))
  fi
}

check_case green 0
check_case partial 1
check_case no_summary 1
check_case test_failure 1
check_case command_failure 1

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: C1 package runner fail-closed contract tests"
  exit 0
fi
echo "C1 package runner contract tests: FAIL=$FAIL"
exit 1
