#!/bin/bash
# RT3 P1-4 RED — junk-frame liveness regression tests on CURRENT (unfixed) code.
# Expect: BOTH tests FAIL (the bug reproduces) — binary/malformed frames still
# refresh liveness, so the bad peer stays connected.
# Run with: bash scripts/rt3_p14_red.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
echo "=== RED: P1-4 junk-frame liveness on unfixed code ==="
echo "worktree: $REPO  branch: $(git rev-parse --abbrev-ref HEAD)  sha: $(git rev-parse --short HEAD)"
cd "$REPO/Packages/FleetNetworking"
swift test \
  --filter "GatewayWebSocketTransportTests/testPeriodicBinaryFramesDoNotRefreshLiveness" \
  --filter "GatewayWebSocketTransportTests/testMalformedFrameFloodClosesConnectionPastThreshold" \
  2>&1 | tail -40
echo "=== exit: ${PIPESTATUS[0]} (nonzero = RED reproduced) ==="
