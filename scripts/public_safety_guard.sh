#!/bin/bash
# public_safety_guard.sh — public-release residue guard (Issue #2, Pass B).
#
# Fails when known classes of private/maintainer residue appear in the
# TRACKED tree (git grep — generated build products are never tracked, so
# they are naturally excluded):
#   - personal email identities and agent commit identities
#   - absolute home paths of a real user
#   - physical-device UDIDs; tailnet/CGNAT addresses in the onboarding prompt
#   - maintainer-specific values from a PRIVATE out-of-repo denylist
#
# NO PRIVATE DATA IN THIS FILE. A denylist of the exact private values it
# blocks would itself publish them (splitting the literals into fragments does
# not hide them). This public file therefore carries only GENERIC residue
# classes. Maintainer-specific values live in a private denylist outside the
# repository, one extended-regex per line (blank lines and `#` comments ok):
#   $HF_PUBLIC_SAFETY_DENYLIST_FILE, else
#   ${XDG_CONFIG_HOME:-$HOME/.config}/hermes-fleet/public-safety-denylist.txt
# Hosted CI can materialize the same file from a secret. Set
# HF_PUBLIC_SAFETY_REQUIRE_PRIVATE=1 (release/RC runs) to FAIL when it is absent.
set -u
cd "$(dirname "$0")/.."
GUARD_REL="scripts/public_safety_guard.sh"
FAIL=0

# --- Generic residue classes (no private values) -------------------------------
# Absolute home paths of a real user (placeholder accounts are allowed).
HOME_PATH='/Users/[A-Za-z0-9._-]+/'
HOME_ALLOWED='/Users/(dev|user|you|name|example|runner|Shared|me|someone|t)/'
PERSONAL_EMAIL='@(gmail|googlemail|icloud|me|outlook|hotmail|yahoo)\.com'
AGENT_ID='@hermes-fleet\.local'                     # local-only agent commit identity
# Not scanned tree-wide (product code and tests legitimately use RFC 6598
# fixtures); enforced only on the onboarding prompt below.
CGNAT='(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' # tailnet/CGNAT address
DEVICE_UDID='(^|[^0-9A-Fa-f-])[0-9A-F]{8}-[0-9A-F]{16}([^0-9A-Fa-f]|$)' # physical-device UDID form
LIVE_TOKEN='sk-live-'                                # live-looking credential fixture
DESTRUCTIVE_FIXTURE='rm -rf /tmp/scratch'            # destructive approval fixture

PATTERN="${PERSONAL_EMAIL}|${AGENT_ID}|${DEVICE_UDID}|${LIVE_TOKEN}|${DESTRUCTIVE_FIXTURE}"

# --- Private, out-of-repo denylist ---------------------------------------------
PRIVATE_FILE="${HF_PUBLIC_SAFETY_DENYLIST_FILE:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/hermes-fleet/public-safety-denylist.txt}"
PRIVATE_PATTERN=""
if [ -f "$PRIVATE_FILE" ]; then
  PRIVATE_PATTERN=$(grep -v -E '^[[:space:]]*(#|$)' "$PRIVATE_FILE" | paste -sd'|' -)
fi

note() { printf '=== %s ===\n' "$1"; }

# --- 1. tracked-tree scan ------------------------------------------------------
note "tracked-tree residue scan"
# Hit lines are NOT echoed in full for private-denylist matches: printing the
# matched text would copy the private value into logs/CI output.
HITS=$(git grep -n -I -E "$PATTERN" -- . ":!$GUARD_REL" 2>/dev/null || true)
HOME_HITS=$(git grep -n -I -E "$HOME_PATH" -- . ":!$GUARD_REL" 2>/dev/null | grep -v -E "$HOME_ALLOWED" || true)
if [ -n "$HITS$HOME_HITS" ]; then
  echo "FAIL: private residue present in tracked files:"
  printf '%s\n%s\n' "$HITS" "$HOME_HITS" | grep -v '^$' | cut -d: -f1,2 | head -40
  FAIL=1
else
  echo "PASS: no generic private residue in tracked tree"
fi

if [ -n "$PRIVATE_PATTERN" ]; then
  # git grep exits 0 (match), 1 (no match) or >=2 (error, e.g. a malformed
  # regex in the denylist). An error must FAIL: treating it as "no match" would
  # let a typo silently disable the private check.
  PRIVATE_RAW=$(git grep -n -I -E "$PRIVATE_PATTERN" -- . ":!$GUARD_REL" 2>/dev/null); PRIVATE_RC=$?
  if [ "$PRIVATE_RC" -ge 2 ]; then
    echo "FAIL: private denylist could not be evaluated (invalid pattern in the denylist file?)"
    FAIL=1
  elif [ "$PRIVATE_RC" -eq 0 ]; then
    echo "FAIL: private denylist matched in tracked files (file:line only):"
    echo "$PRIVATE_RAW" | cut -d: -f1,2 | head -40
    FAIL=1
  else
    echo "PASS: private denylist not matched in tracked tree"
  fi
elif [ "${HF_PUBLIC_SAFETY_REQUIRE_PRIVATE:-0}" = "1" ]; then
  echo "FAIL: private denylist required but not found (set HF_PUBLIC_SAFETY_DENYLIST_FILE)"
  FAIL=1
else
  echo "NOTE: no private denylist configured; generic checks only"
fi

# --- 1b. local/operator evidence must never be tracked ----------------------
# These paths are intentionally ignored, but the guard also fails closed if a
# future force-add or generated commit attempts to publish them again.
if git ls-files | grep -Eq '^(hosted|local)/|^evidence\.md$'; then
  echo "FAIL: local/hosted operator evidence is tracked; keep it outside the public repository"
  git ls-files | grep -E '^(hosted|local)/|^evidence\.md$' | head -40
  FAIL=1
else
  echo "PASS: local/hosted operator evidence is not tracked"
fi

# --- 2. shipped configuration must not pin an endpoint ------------------------
note "shipped Info.plist endpoint check"
if git ls-files --error-unmatch HermesFleetApp/Info.plist >/dev/null 2>&1; then
  if /usr/libexec/PlistBuddy -c 'Print :FleetDefaultEndpoint' HermesFleetApp/Info.plist >/dev/null 2>&1; then
    echo "FAIL: HermesFleetApp/Info.plist ships a FleetDefaultEndpoint — the public default must not pin any endpoint (inject per build config only)"
    FAIL=1
  else
    echo "PASS: no FleetDefaultEndpoint in shipped Info.plist"
  fi
fi

# --- 3. onboarding prompt hygiene (mirrors OnboardingPrompt forbidden list) ----
note "onboarding prompt source hygiene"
PROMPT="Packages/FleetUI/Sources/FleetUI/OnboardingPrompt.swift"
if git ls-files --error-unmatch "$PROMPT" >/dev/null 2>&1; then
  PROMPT_PATTERN="${CGNAT}${PRIVATE_PATTERN:+|$PRIVATE_PATTERN}"
  if git grep -q -E "$PROMPT_PATTERN" -- "$PROMPT"; then
    echo "FAIL: OnboardingPrompt.swift references maintainer/private endpoints"
    FAIL=1
  else
    echo "PASS: onboarding prompt free of maintainer/private endpoints"
  fi
fi

# --- Summary -------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
  echo "PUBLIC-SAFETY GUARD: FAIL"
  exit 1
fi
echo "PUBLIC-SAFETY GUARD: PASS"
exit 0
