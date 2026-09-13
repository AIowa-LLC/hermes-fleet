#!/bin/bash
# C1 static phase — repository guards that need no simulator.
#   xcodegen generate -> drift gate -> FleetUI module boundary ->
#   theme call-site audit -> public-safety residue guard -> gitleaks
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

# --- theme call-site audit ----------------------------------------------------
note "Theme call-site audit"
if bash scripts/theme_callsite_audit.sh >/tmp/c1_theme.log 2>&1; then
  ok "theme call-site audit: runtime product colors use FleetThemeValues"
else
  bad "theme call-site audit FAILED"; cat /tmp/c1_theme.log
fi

# --- privacy manifest and required-reason audit -------------------------------
note "Privacy manifest validation"
if bash scripts/privacy_manifest_validate.sh >/tmp/c1_privacy_manifest.log 2>&1; then
  ok "privacy manifest: present, well-formed, and truthful"
else
  bad "privacy manifest validation FAILED"; cat /tmp/c1_privacy_manifest.log
fi

if bash scripts/privacy_manifest_validate_test.sh >/tmp/c1_privacy_manifest_test.log 2>&1; then
  ok "privacy manifest fail-closed tests: disappearance/malformed content rejected"
else
  bad "privacy manifest fail-closed tests FAILED"; cat /tmp/c1_privacy_manifest_test.log
fi

note "Required-reason API audit"
if bash scripts/privacy_required_reason_audit.sh >/tmp/c1_privacy_reason.log 2>&1; then
  ok "required-reason API audit: declarations match production use"
else
  bad "required-reason API audit FAILED"; cat /tmp/c1_privacy_reason.log
fi

if bash scripts/privacy_required_reason_audit_test.sh >/tmp/c1_privacy_reason_test.log 2>&1; then
  ok "required-reason scanner positive/negative fixtures: complete API table covered"
else
  bad "required-reason scanner tests FAILED"; cat /tmp/c1_privacy_reason_test.log
fi

# --- release preflight contract ----------------------------------------------
note "Release preflight contract"
if bash scripts/release_preflight_contract_test.sh >/tmp/c1_release_preflight.log 2>&1; then
  ok "release preflight: archive/export/signing contract fails closed"
else
  bad "release preflight contract tests FAILED"; cat /tmp/c1_release_preflight.log
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
# Scan the WORKING TREE (--no-git). Rationale: in CI's depth-1 checkout the
# old tip-commit git scan silently collapsed to a whole-tree scan anyway
# (shallow clone -> no parent to diff against), so --no-git is the honest
# equivalent of what CI always scanned — and its fingerprints are stable
# across checkouts, unlike git-mode fingerprints that embed the introducing
# commit SHA (unstable on PR merge commits). Known-good exceptions live in
# .gitleaksignore (currently one: the fleet.navigation.v1 UserDefaults
# storage-key string, a generic-api-key rule false positive).
# A full local git-history scan would additionally flag F2's known
# fixture-password noise in the superseded commit 5ed93e3 (files no longer
# contain those strings at HEAD) — not a leak, not a gate concern.
# Scan EXACTLY the tracked tree at HEAD: extract via git archive into a temp
# dir and --no-git scan that. This is deterministic in any clone (shallow or
# full — the old git-mode tip scan silently collapsed to a whole-tree scan in
# CI's depth-1 checkout anyway), never touches untracked build artifacts, and
# yields stable fingerprints (no introducing-commit SHA embedded).
GL_DIR=$(mktemp -d /tmp/c1_gitleaks_tree.XXXXXX)
if git -C "$REPO" archive HEAD | tar -x -C "$GL_DIR" 2>/dev/null; then
  if command -v gitleaks >/dev/null 2>&1 && (cd "$GL_DIR" && gitleaks detect --source . --no-git --no-banner) >/tmp/c1_gitleaks.log 2>&1; then
    ok "gitleaks: no leaks found (tracked tree at HEAD)"
    rm -rf "$GL_DIR"
  else
    bad "gitleaks FAILED"; tail -15 /tmp/c1_gitleaks.log; rm -rf "$GL_DIR"
  fi
else
  bad "gitleaks FAILED: could not extract tracked tree (git archive)"; rm -rf "$GL_DIR"
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
