#!/bin/bash
# public_safety_guard.sh — public-release residue guard (Issue #2, Pass B).
#
# Fails when known classes of private/maintainer residue appear in the
# TRACKED tree (git grep — generated build products are never tracked, so
# they are naturally excluded):
#   - personal email identities (gmail/icloud/hermes-fleet.local)
#   - absolute maintainer home paths
#   - physical-device / retired-simulator UDID prefixes
#   - maintainer-owned production endpoints
#   - real private LAN/tailnet addresses and private machine identifiers
#
# SELF-MATCH AVOIDANCE: every detected string is CONSTRUCTED at runtime from
# fragments, so this file's own source never contains the literals it
# detects; the guard also excludes itself from the scan as belt-and-braces.
set -u
cd "$(dirname "$0")/.."
GUARD_REL="scripts/public_safety_guard.sh"
FAIL=0

# --- Constructed residue patterns (never literal in this file) ---------------
HOME_DIR="Users/""tonysimons"          # absolute maintainer home path
GMAIL="gmail""\\.""com"                 # personal email domain
ICLOUD="icloud""\\.""com"               # personal email domain
ME_COM="""@me.""\\.""com"               # personal email domain
AGENT_ID="hermes-fleet""\\.""local"     # local-only agent commit identity
DEV_UDID="DB3922C1""-05FA"              # physical iPhone UDID prefix
SIM_UDID="393F1335""-2DB1"              # retired simulator UDID prefix
FLEET_HOST="fleet""\\.""tonysimons""\\.""dev"   # maintainer production endpoint
LAN_A="192""\\.""168""\\.""4""\\."       # real LAN subnet
TAIL_A="100""\\.""100""\\.""105""\\."    # real tailnet address
TAIL_B="100""\\.""108""\\.""104""\\."    # real tailnet address
ARCH_HOST="archlinux""-1"               # private machine hostname
TS_TAILNET="taila00fdc"                 # real tailnet name fragment
MAC_HOST="macbook""-m5"                 # maintainer workstation hostname
PERSONAL_APPLE="asimons""1981"          # personal Apple ID local part
KNOWN_LAN="192""\\.""168""\\.""50""\\.(37|58)" # retired operator LAN fixtures
KNOWN_TAIL_A="100""\\.""100""\\.""200""\\.61" # retired operator tailnet fixture
KNOWN_TAIL_B="100""\\.""127""\\.""200""\\.89" # retired operator tailnet fixture
LIVE_TOKEN="sk""-live-"              # live-looking credential fixture
QR_PASSWORD="7f3a""9c21""e8b0"       # retired QR credential fragment
DESTRUCTIVE_FIXTURE="rm"" -rf /tmp/scratch" # destructive approval fixture

# Keep concrete maintainer-specific patterns while allowing generic public
# fixture hosts and RFC/private-range examples.
PATTERN="${HOME_DIR}|${GMAIL}|${ICLOUD}|${ME_COM}|${AGENT_ID}|${DEV_UDID}|${SIM_UDID}|${FLEET_HOST}|${LAN_A}|${TAIL_A}|${TAIL_B}|${ARCH_HOST}|${TS_TAILNET}|${MAC_HOST}|${PERSONAL_APPLE}|${KNOWN_LAN}|${KNOWN_TAIL_A}|${KNOWN_TAIL_B}|${LIVE_TOKEN}|${QR_PASSWORD}|${DESTRUCTIVE_FIXTURE}"

note() { printf '=== %s ===\n' "$1"; }

# --- 1. tracked-tree scan ------------------------------------------------------
note "tracked-tree residue scan"
HITS=$(git grep -n -I -E "$PATTERN" -- . ":!$GUARD_REL" 2>/dev/null || true)
if [ -n "$HITS" ]; then
  echo "FAIL: private residue present in tracked files:"
  echo "$HITS" | head -40
  FAIL=1
else
  echo "PASS: no known private residue in tracked tree"
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
  if git grep -q -E "$FLEET_HOST|${LAN_A}|${TAIL_A}|${TAIL_B}" -- "$PROMPT"; then
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
