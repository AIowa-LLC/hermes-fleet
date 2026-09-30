#!/bin/bash
# h2_verify_final.sh — H2 (t_5da54f59): full verification before
# kanban_request_review. Mirrors the card's mandated pipeline:
#   xcodegen generate -> swift test (FleetCore/FleetPersistence/FleetNetworking)
#   -> module-boundary check -> xcodebuild build+test (simulator, hosted unit
#   subset incl. ModuleBoundaryTests) -> secrets scan (gitleaks).
# The live-gateway UI test (H2HealthDashboardUITests) runs separately via
# scripts/h2_uitest.sh (needs the LAN surface + forwarders).
# Runs via `bash scripts/h2_verify_final.sh`.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()
note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  bad "not on main (on '$BRANCH')"
fi

# --- 1. xcodegen generate ----------------------------------------------------
note "xcodegen generate"
if xcodegen generate >/tmp/h2_xcodegen.log 2>&1; then
  ok "xcodegen generate succeeded"
else
  bad "xcodegen generate FAILED"; tail -5 /tmp/h2_xcodegen.log
fi

# --- 2. swift test (3 touched packages) --------------------------------------
run_pkg() {
  local name=$1 out
  note "$name swift test"
  out=$(cd "Packages/$name" && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "  $out"
  if echo "$out" | grep -q ', with 0 failures'; then
    ok "$name swift test green: $out"
  else
    bad "$name swift test NOT green: $out"
  fi
}
run_pkg FleetCore
run_pkg FleetPersistence
run_pkg FleetNetworking

# --- 3. module-boundary check ------------------------------------------------
note "Module boundary: no 'import FleetNetworking' in FleetUI sources"
UI_SOURCES=$(find Packages/FleetUI/Sources -name '*.swift')
HITS=$(grep -nE '^\s*import\s+FleetNetworking\b' $UI_SOURCES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "FleetUI has 0 'import FleetNetworking' (M0 hard guard preserved)"
else
  bad "FleetUI imports FleetNetworking:"; echo "$HITS"
fi

# --- 4. xcodebuild build+test (simulator), hosted unit subset ----------------
note "xcodebuild build + test (simulator), only-testing HermesFleetAppTests"
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/H2Ci"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests \
    build test >/tmp/h2_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/h2_xctest.log | tail -1)
  ok "xcodebuild build+test SUCCEEDED — $TESTLINE"
  grep -E 'Executed .* tests' /tmp/h2_xctest.log | tail -1 | sed 's/^/  /'
else
  bad "xcodebuild build+test FAILED"
  grep -E 'error:|failed|Test Suite' /tmp/h2_xctest.log | tail -25
fi

# --- 5. secrets scan (gitleaks) ----------------------------------------------
note "gitleaks detect"
if command -v gitleaks >/dev/null 2>&1 && gitleaks detect --source "$REPO" --no-banner >/tmp/h2_gitleaks.log 2>&1; then
  ok "gitleaks: no leaks found"
else
  bad "gitleaks FAILED"; tail -15 /tmp/h2_gitleaks.log
fi

# --- 6. worktree hygiene ------------------------------------------------------
note "git status"
git status --short | head -40
if [ -z "$(git status --porcelain | grep -E '^ ?[MADRCU]' || true)" ]; then
  ok "no tracked modifications outside this lane"
fi

# --- Summary ------------------------------------------------------------------
printf '\n=====================================\n'
printf 'H2 CI: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
