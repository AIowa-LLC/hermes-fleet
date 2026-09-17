#!/bin/bash
# Card C — live artifact-transport verification against a running Hermes
# gateway (environmental, opt-in). Proves REAL image bytes flow through the
# authenticated `/api/media` contract via the shipped `GatewayArtifactClient`,
# plus the auth / media-root confinement / expiration classifications on the
# wire. The hermetic suites cover the rest; this script is the live evidence.
#
# Required env:
#   FLEET_LIVE_ARTIFACT_TOKEN_FILE  file holding the dashboard session token
#                                   (X-Hermes-Session-Token value)
#   FLEET_LIVE_ARTIFACT_PATH        gateway-local path of an existing image
#                                   under the gateway's media roots
# Optional env (loopback defaults):
#   FLEET_LIVE_ARTIFACT_BASE_URL    default http://127.0.0.1:18923
#   FLEET_LIVE_ARTIFACT_MISSING_PATH  media-root path that does not exist
#   FLEET_LIVE_ARTIFACT_OUTSIDE_PATH  image-suffixed path outside the roots
#   FLEET_LIVE_ARTIFACT_EVIDENCE_OUT  evidence JSON path
#
# Fixture gateway (isolated HERMES_HOME, loopback only) — the media roots are
# <home>/images, <home>/screenshots and <home>/cache (the cache/images dir is
# where image generation writes):
#   HERMES_HOME=<home> HERMES_DASHBOARD_SESSION_TOKEN="$(cat <token-file>)" \
#     python -m hermes_cli.main dashboard --host 127.0.0.1 --port <port>
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"

: "${FLEET_LIVE_ARTIFACT_TOKEN_FILE:?set FLEET_LIVE_ARTIFACT_TOKEN_FILE}"
: "${FLEET_LIVE_ARTIFACT_PATH:?set FLEET_LIVE_ARTIFACT_PATH}"

export FLEET_LIVE_ARTIFACT_BASE_URL="${FLEET_LIVE_ARTIFACT_BASE_URL:-http://127.0.0.1:18923}"
export FLEET_LIVE_ARTIFACT_SHA256="$(shasum -a 256 "$FLEET_LIVE_ARTIFACT_PATH" | awk '{print $1}')"

# The gateway home is two levels up from a media root (<home>/<root>/<file>).
ARTIFACT_DIR="$(cd "$(dirname "$FLEET_LIVE_ARTIFACT_PATH")" && pwd)"
GATEWAY_HOME="$(cd "$ARTIFACT_DIR/../.." && pwd)"
export FLEET_LIVE_ARTIFACT_MISSING_PATH="${FLEET_LIVE_ARTIFACT_MISSING_PATH:-$GATEWAY_HOME/cache/images/__c_missing_artifact__.png}"
export FLEET_LIVE_ARTIFACT_OUTSIDE_PATH="${FLEET_LIVE_ARTIFACT_OUTSIDE_PATH:-/etc/hosts.png}"
export FLEET_LIVE_ARTIFACT_EVIDENCE_OUT="${FLEET_LIVE_ARTIFACT_EVIDENCE_OUT:-${TMPDIR:-/tmp}/c-artifact-evidence.json}"
LOG="${FLEET_LIVE_ARTIFACT_EVIDENCE_OUT%.json}.log"

echo "== C: live artifact transport check =="
echo "gateway base:  $FLEET_LIVE_ARTIFACT_BASE_URL"
echo "artifact:      $(basename "$FLEET_LIVE_ARTIFACT_PATH") (sha256 $FLEET_LIVE_ARTIFACT_SHA256)"
echo "evidence:      $FLEET_LIVE_ARTIFACT_EVIDENCE_OUT"
echo

swift test --package-path "$REPO/Packages/FleetNetworking" \
    --filter ArtifactTransportLiveCheck 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}

echo
grep -m1 "^LIVE-EVIDENCE" "$LOG" | cut -c1-600 || true
echo

if [ -f "$FLEET_LIVE_ARTIFACT_EVIDENCE_OUT" ] \
    && grep -q '"all_pass" : true' "$FLEET_LIVE_ARTIFACT_EVIDENCE_OUT"; then
    echo "VERDICT: ALL PASS ($FLEET_LIVE_ARTIFACT_EVIDENCE_OUT)"
else
    echo "VERDICT: FAIL (see $LOG)"
    STATUS=1
fi
exit "$STATUS"
