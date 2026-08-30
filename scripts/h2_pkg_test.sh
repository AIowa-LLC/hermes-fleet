#!/usr/bin/env bash
# h2_pkg_test.sh — H2: run the host-side swift test suites for the three
# packages this card touches (FleetCore accumulator + FleetPersistence store +
# FleetNetworking transport health stream). Runs via `bash scripts/h2_pkg_test.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

run_pkg() {
  local name=$1
  echo "=== $name swift test ==="
  if (cd "Packages/$name" && swift test) > "/tmp/h2_${name}.log" 2>&1; then
    echo "  $name GREEN"
    grep -E "Executed .* tests" "/tmp/h2_${name}.log" | tail -1
  else
    echo "  $name FAILED — tail:"
    grep -E "error:|failed|Executed" "/tmp/h2_${name}.log" | tail -30
    return 1
  fi
}

FAIL=0
run_pkg FleetCore || FAIL=1
run_pkg FleetPersistence || FAIL=1
run_pkg FleetNetworking || FAIL=1
exit $FAIL
