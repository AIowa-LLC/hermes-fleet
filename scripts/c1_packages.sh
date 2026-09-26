#!/bin/bash
# C1 packages phase — host `swift test` for the four non-UIKit packages.
#   FleetCore / FleetNetworking / FleetPersistence / FleetSecurity
# FleetUI imports UIKit and cannot `swift test` on the macOS host; it is
# validated by the module-boundary check (static phase) + hosted
# ModuleBoundaryTests (units phase).
# Used standalone by CI (job: packages) and by c1_ci_validate.sh.
set -u
cd "$(dirname "$0")/.."

FAIL=0
declare -a FAILURES=()
expected_test_count() {
  case "$1" in
    FleetCore) echo 415 ;;
    FleetNetworking) echo 418 ;;
    FleetPersistence) echo 31 ;;
    FleetSecurity) echo 37 ;;
    *) return 1 ;;
  esac
}

run_pkg() {
  local name=$1 log expected status summaries summary count
  expected=$(expected_test_count "$name") || {
    FAIL=$((FAIL+1)); FAILURES+=("$name has no expected test count")
    printf 'FAIL  %s swift test has no expected test count\n' "$name"
    return
  }

  printf '\n=== %s swift test ===\n' "$name"
  log=$(mktemp "/tmp/c1_${name}.log.XXXXXX") || {
    FAIL=$((FAIL+1)); FAILURES+=("$name could not create a swift test log")
    printf 'FAIL  %s swift test could not create a log\n' "$name"
    return
  }

  # Capture the command's real exit status separately from its output. Piping
  # swift test through grep/tail can hide a killed or failed test process.
  if (cd "Packages/$name" && swift test) >"$log" 2>&1; then
    status=0
  else
    status=$?
  fi

  summaries=$(grep -E '^[[:space:]]*Executed [0-9]+ tests?, with .* failures?([[:space:](]|$)' "$log" || true)
  summary=$(printf '%s\n' "$summaries" | tail -1)
  echo "  ${summary:-No final XCTest summary found}"
  count=$(printf '%s\n' "$summary" | sed -nE 's/^[[:space:]]*Executed ([0-9]+) tests?, with ([0-9]+ tests? skipped and )?0 failures([[:space:](]|$).*/\1/p')

  # Exact count is intentional: the current declared XCTest inventories are
  # 415/418/31/37. Update these baselines with deliberate test additions or
  # removals; a partial run must never look green merely because its completed
  # subset reported zero failures.
  if [ "$status" -eq 0 ] && [ -n "$count" ] && [ "$count" -eq "$expected" ]; then
    printf 'PASS  %s swift test complete (%s tests)\n' "$name" "$expected"
    printf "Package evidence retained: %s\n" "$log"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$name swift test incomplete or NOT green")
    printf 'FAIL  %s swift test incomplete or NOT green (exit=%s expected=%s got=%s); full log: %s\n' \
      "$name" "$status" "$expected" "${count:-none}" "$log"
    # Print the assertion before the generic final summary, and retain the
    # complete log as an artifact for the exact candidate being tested.
    grep -E 'error:|Test Case.*failed|failed -|XCTAssert' "$log" | tail -40 || true
    tail -20 "$log"
  fi
}
run_pkg FleetCore
run_pkg FleetNetworking
run_pkg FleetPersistence
run_pkg FleetSecurity

printf '\n=====================================\n'
printf 'C1 packages phase: FAIL=%d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
