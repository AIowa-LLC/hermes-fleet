#!/bin/bash
# C1 static phase — repository guards that need no simulator.
#   xcodegen generate -> drift gate -> FleetUI module boundary ->
#   public-safety residue guard -> gitleaks (tip commit, CI semantics)
# Used standalone by CI (job: static-guards) and by c1_ci_validate.sh.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
FAIL=0
declare -a FAILURES=()
note() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. xcodegen generate ----------------------------------------------------
note "xcodegen generate"
if xcodegen generate >/tmp/c1_xcodegen.log 2>&1; then
  ok "xcodegen generate succeeded"
else
  bad "xcodegen generate FAILED"; tail -5 /tmp/c1_xcodegen.log
fi

# --- 1b. xcodegen drift gate --------------------------------------------------
note "xcodegen drift gate (project.yml authoritative)"
if bash scripts/xcodegen_drift_gate.sh >/tmp/c1_drift.log 2>&1; then
  ok "xcodegen drift gate: committed project matches project.yml"
else
  bad "xcodegen DRIFT: HermesFleetApp.xcodeproj does not match project.yml"; tail -10 /tmp/c1_drift.log
fi

# --- module-boundary check ----------------------------------------------------
note "Module boundary: no 'import FleetNetworking' in FleetUI sources"
UI_SOURCES=$(find Packages/FleetUI/Sources -name '*.swift')
HITS=$(grep -nE '^\s*import\s+FleetNetworking\b' $UI_SOURCES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "FleetUI has 0 'import FleetNetworking' (M0 hard guard preserved)"
else
  bad "FleetUI imports FleetNetworking:"; echo "$HITS"
fi

# --- public-safety residue guard ----------------------------------------------
note "public-safety residue guard"
if bash scripts/public_safety_guard.sh >/tmp/c1_guard.log 2>&1; then
  ok "public-safety guard: tracked tree clean"
else
  bad "public-safety guard FAILED"; tail -20 /tmp/c1_guard.log
fi

# --- secrets scan (gitleaks) --------------------------------------------------
note "gitleaks detect"
# Match CI's depth-1 checkout semantics: scan the TIP commit only. A local
# full-history scan also flags F2's known fixture-password noise in the
# superseded commit 5ed93e3 (files no longer contain those strings at HEAD).
TIP_SHA=$(git -C "$REPO" rev-parse HEAD)
if command -v gitleaks >/dev/null 2>&1 && gitleaks detect --source "$REPO" --no-banner --log-opts="$TIP_SHA -1" >/tmp/c1_gitleaks.log 2>&1; then
  ok "gitleaks: no leaks found"
else
  bad "gitleaks FAILED"; tail -15 /tmp/c1_gitleaks.log
fi

# --- Summary -------------------------------------------------------------------
printf '\n=====================================\n'
printf 'C1 static phase: FAIL=%d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
