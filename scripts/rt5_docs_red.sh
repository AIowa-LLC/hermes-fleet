#!/bin/bash
# rt5_docs_red.sh — RT5 P2-11 + ADR regression test (RED side).
# Asserts the CURRENT docs-truth contract and FAILS on the pre-fix state
# (stale README/M0 + missing ADRs). Run BEFORE the RT5 fix:
#   bash scripts/rt5_docs_red.sh   -> exits non-zero (RED), each check reported.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# --- P2-11: README must not claim the current app is an M0 skeleton ---------
if grep -qE "Status:\*\* M0 Foundation \(module boundaries \+ skeleton\)\. No live" README.md; then
  bad "README still claims 'M0 Foundation ... No live connection' (P2-11 reproduces)"
else
  ok "README no longer claims M0-skeleton current status"
fi
if grep -qiE "no live.*connection.*no JSON-RPC.*no auth" README.md; then
  bad "README still lists 'no live connection / no JSON-RPC / no auth' as current"
else
  ok "README status no longer lists no-live/no-auth/no-persistence"
fi

# --- P2-11: README must publish a current milestone map ---------------------
if grep -qE "^## Milestone map" README.md; then
  ok "README has a Milestone map section"
else
  bad "README lacks a current Milestone map section"
fi
if grep -qE "RT4|M15|U4|89c2c55|working fleet client|CI green" README.md; then
  ok "README milestone map references current-state milestones"
else
  bad "README milestone map does not reference landed milestones (M15/U4/RT4/CI)"
fi

# --- P2-11: M0 notes must be marked historical ------------------------------
if grep -qiE "historical|HISTORICAL|superseded|foundation evidence" docs/M0-foundation.md; then
  ok "docs/M0-foundation.md marked historical/superseded"
else
  bad "docs/M0-foundation.md not marked historical (P2-11 reproduces)"
fi
if grep -qE "M1–M15 are gated and NOT started" docs/M0-foundation.md; then
  bad "docs/M0-foundation.md still claims 'M1–M15 gated and NOT started'"
else
  ok "docs/M0-foundation.md no longer claims M1–M15 not started"
fi

# --- Report rec #4: 5 ADRs in docs/adr/ with Context/Decision/Consequences ---
EXPECTED=(
  "0001-per-gateway-session-ownership"
  "0002-replay-validation-idempotence"
  "0003-endpoint-trust-redaction"
  "0004-transcript-retention"
  "0005-credential-failure-semantics"
)
for adr in "${EXPECTED[@]}"; do
  if [ -f "docs/adr/$adr.md" ]; then
    ok "docs/adr/$adr.md exists"
    for section in "Context" "Decision" "Consequences"; do
      if grep -qE "^## $section" "docs/adr/$adr.md"; then
        ok "  $adr has '$section' section"
      else
        bad "  $adr missing '$section' section"
      fi
    done
  else
    bad "docs/adr/$adr.md missing"
  fi
done

echo
echo "=== rt5_docs_red: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
