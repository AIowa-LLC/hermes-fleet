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
#
# Preconditions / verdict:
# - the token file must EXIST and be NON-EMPTY (an empty one makes the test
#   XCTSkip, which would leave nothing to judge);
# - the evidence file is cleared before the run and the verdict is read from
#   the JSON the test writes during THIS run ("verdict"."all_pass"), never from
#   a stale file left by an earlier invocation;
# - a failing `swift test` still reaches the diagnostics below (the status is
#   captured, not left to `set -e`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${1:-http://127.0.0.1:18923}"
HERMES_HOME_DIR="${2:-/tmp/fleet-devgw}"

TOKEN_FILE="$HERMES_HOME_DIR/.env.token"
# -s, not -f: the test XCTSkips on an empty token file, which would look like a
# passing run while no live contract check happened.
if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "token file missing or empty: $TOKEN_FILE" >&2
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
# The evidence dir persists across invocations: clear the old verdict, or a
# stale all_pass JSON would vouch for a run that never reached its verdict.
rm -f "$EVIDENCE_OUT"
# Explicit status capture: with `set -e` an aborted pipeline would skip the
# evidence diagnostics entirely, collapsing "ran and failed" into "no output".
set +e
swift test --filter DashboardCronLiveCheck 2>&1 | tee "$EVIDENCE_DIR/live-run.log" | tail -20
STATUS=${PIPESTATUS[0]}
set -e

if [[ ! -f "$EVIDENCE_OUT" ]]; then
  echo "no evidence file written — the live check did not reach its verdict" >&2
  echo "  (unconfigured/skipped test, no matching test, build failure or crash)" >&2
  echo "  see $EVIDENCE_DIR/live-run.log" >&2
  exit 1
fi
echo "evidence: $EVIDENCE_OUT"

if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: swift test exited $STATUS (see $EVIDENCE_DIR/live-run.log)" >&2
  exit "$STATUS"
fi

# The test records its own verdict; the file merely existing is not a pass.
if ! grep -q '"all_pass" : true' "$EVIDENCE_OUT"; then
  echo "FAIL: evidence verdict is not all_pass — see $EVIDENCE_OUT" >&2
  exit 1
fi
echo "VERDICT: ALL PASS"
