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
run_pkg() {
  local name=$1 out
  printf '\n=== %s swift test ===\n' "$name"
  out=$(cd "Packages/$name" && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "  $out"
  if echo "$out" | grep -q ', with 0 failures'; then
    printf 'PASS  %s swift test green: %s\n' "$name" "$out"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$name swift test NOT green")
    printf 'FAIL  %s swift test NOT green: %s\n' "$name" "$out"
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
