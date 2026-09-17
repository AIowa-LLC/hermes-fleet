#!/usr/bin/env bash
# Card B — dev-gateway live contract check driver.
#
# Runs the env-gated `DashboardCronLiveCheck` (FleetNetworkingTests) against a
# RUNNING Hermes dashboard, exercising the real DashboardCronClient end to
# end: list → create → get → update(PUT) → pause → resume → trigger → runs →
# delete + the auth/404 classifications.
#
# Usage:
#   bash scripts/b_cron_live_check.sh [dashboard-base-url] [hermes-home]
# Defaults match the mission's scratch dev gateway:
#   base  http://127.0.0.1:18923
#   home  /tmp/fleet-devgw   (its .env.token holds the dashboard session token)
#
# The token is read BY REFERENCE (a file path is passed to the test; the token
# itself is never echoed, logged, or embedded in evidence).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${1:-http://127.0.0.1:18923}"
HERMES_HOME_DIR="${2:-/tmp/fleet-devgw}"

TOKEN_FILE="$HERMES_HOME_DIR/.env.token"
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "token file not found: $TOKEN_FILE" >&2
  exit 2
fi

EVIDENCE_DIR="$REPO_ROOT/build/b-cron-evidence"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_OUT="$EVIDENCE_DIR/live-contract.json"

export FLEET_LIVE_CRON_BASE_URL="$BASE_URL"
export FLEET_LIVE_CRON_TOKEN_FILE="$TOKEN_FILE"
export FLEET_LIVE_CRON_PROFILE="${FLEET_LIVE_CRON_PROFILE:-default}"
export FLEET_LIVE_CRON_EVIDENCE_OUT="$EVIDENCE_OUT"

echo "live cron check: base=$BASE_URL profile=$FLEET_LIVE_CRON_PROFILE"
cd "$REPO_ROOT/Packages/FleetNetworking"
swift test --filter DashboardCronLiveCheck 2>&1 | tee "$EVIDENCE_DIR/live-run.log" | tail -20

if [[ -f "$EVIDENCE_OUT" ]]; then
  echo "evidence: $EVIDENCE_OUT"
else
  echo "no evidence file written — the live check did not reach its verdict" >&2
  exit 1
fi