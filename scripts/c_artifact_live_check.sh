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
#   FLEET_LIVE_ARTIFACT_HOME        gateway home (the directory that holds the
#                                   media roots); must exist if set. Used only
#                                   to place the default MISSING_PATH below.
#   FLEET_LIVE_ARTIFACT_MISSING_PATH  media-root path that does not exist
#   FLEET_LIVE_ARTIFACT_OUTSIDE_PATH  image-suffixed path outside the roots
#   FLEET_LIVE_ARTIFACT_EVIDENCE_OUT  evidence JSON path
#
# FLEET_LIVE_ARTIFACT_PATH must be shaped <home>/<root>/<file>, with <root> one
# of `images`, `screenshots` or `cache` (generated images land in the nested
# `cache/images`). The gateway home is NEVER inferred from that path: the two
# supported depths differ (`<home>/images/<file>` vs `<home>/cache/images/
# <file>`), so a fixed "two levels up" guess resolves to the PARENT of the home
# for the shallow case, pushing the default MISSING_PATH outside the media
# roots — where the 403 confinement classification would take over from the
# 404 expiration one and make the live evidence lie. Pass
# FLEET_LIVE_ARTIFACT_HOME explicitly, or let MISSING_PATH default to a
# nonexistent sibling of the supplied artifact (inside the same media root by
# construction).
#
# Verdict: the evidence JSON is cleared before the run, and ALL PASS is printed
# only when THIS run exits 0 having written its own `"all_pass" : true` verdict
# — a stale evidence file from an earlier invocation never vouches for a
# failing run.
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

if [ ! -f "$FLEET_LIVE_ARTIFACT_PATH" ]; then
    echo "FLEET_LIVE_ARTIFACT_PATH is not a readable file: $FLEET_LIVE_ARTIFACT_PATH" >&2
    exit 2
fi

export FLEET_LIVE_ARTIFACT_BASE_URL="${FLEET_LIVE_ARTIFACT_BASE_URL:-http://127.0.0.1:18923}"
FLEET_LIVE_ARTIFACT_SHA256="$(shasum -a 256 "$FLEET_LIVE_ARTIFACT_PATH" | awk '{print $1}')"
export FLEET_LIVE_ARTIFACT_SHA256

ARTIFACT_DIR="$(cd "$(dirname "$FLEET_LIVE_ARTIFACT_PATH")" && pwd)"
GATEWAY_HOME="${FLEET_LIVE_ARTIFACT_HOME:-}"
if [ -n "$GATEWAY_HOME" ]; then
    if ! GATEWAY_HOME="$(cd "$FLEET_LIVE_ARTIFACT_HOME" && pwd)"; then
        echo "FLEET_LIVE_ARTIFACT_HOME does not exist: $FLEET_LIVE_ARTIFACT_HOME" >&2
        exit 2
    fi
fi

# MISSING_PATH must stay inside a media root (404 -> .expired): default to a
# nonexistent sibling of the supplied artifact, or to the documented nested
# root when the gateway home is given explicitly.
if [ -z "${FLEET_LIVE_ARTIFACT_MISSING_PATH:-}" ]; then
    if [ -n "$GATEWAY_HOME" ]; then
        FLEET_LIVE_ARTIFACT_MISSING_PATH="$GATEWAY_HOME/cache/images/__c_missing_artifact__.png"
    else
        FLEET_LIVE_ARTIFACT_MISSING_PATH="$ARTIFACT_DIR/__c_missing_artifact__.png"
    fi
fi
export FLEET_LIVE_ARTIFACT_MISSING_PATH
export FLEET_LIVE_ARTIFACT_OUTSIDE_PATH="${FLEET_LIVE_ARTIFACT_OUTSIDE_PATH:-/etc/hosts.png}"
export FLEET_LIVE_ARTIFACT_EVIDENCE_OUT="${FLEET_LIVE_ARTIFACT_EVIDENCE_OUT:-${TMPDIR:-/tmp}/c-artifact-evidence.json}"
LOG="${FLEET_LIVE_ARTIFACT_EVIDENCE_OUT%.json}.log"

echo "== C: live artifact transport check =="
echo "gateway base:  $FLEET_LIVE_ARTIFACT_BASE_URL"
echo "artifact:      $(basename "$FLEET_LIVE_ARTIFACT_PATH") (sha256 $FLEET_LIVE_ARTIFACT_SHA256)"
echo "media root:    $ARTIFACT_DIR"
echo "missing path:  $FLEET_LIVE_ARTIFACT_MISSING_PATH"
echo "evidence:      $FLEET_LIVE_ARTIFACT_EVIDENCE_OUT"
echo

# An evidence file left by an earlier run must never vouch for this one.
rm -f "$FLEET_LIVE_ARTIFACT_EVIDENCE_OUT"
swift test --package-path "$REPO/Packages/FleetNetworking" \
    --filter ArtifactTransportLiveCheck 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}

echo
grep -m1 "^LIVE-EVIDENCE" "$LOG" | cut -c1-600 || true
echo

# The printed verdict and the exit status must agree.
if [ ! -f "$FLEET_LIVE_ARTIFACT_EVIDENCE_OUT" ]; then
    echo "VERDICT: FAIL (no evidence file written — the live check did not reach its verdict; see $LOG)"
    STATUS=1
elif ! grep -q '"all_pass" : true' "$FLEET_LIVE_ARTIFACT_EVIDENCE_OUT"; then
    echo "VERDICT: FAIL (evidence verdict is not all_pass; see $FLEET_LIVE_ARTIFACT_EVIDENCE_OUT)"
    STATUS=1
elif [ "$STATUS" -ne 0 ]; then
    echo "VERDICT: FAIL (swift test exited $STATUS; see $LOG)"
    STATUS=1
else
    echo "VERDICT: ALL PASS ($FLEET_LIVE_ARTIFACT_EVIDENCE_OUT)"
fi
exit "$STATUS"
