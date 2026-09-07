#!/bin/bash
# RT3 P1-4 GREEN — junk-frame liveness regression tests on FIXED code.
# Expect: BOTH tests PASS (bad peer is now closed + classified).
# Run with: bash scripts/rt3_p14_green.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
echo "=== GREEN: P1-4 junk-frame liveness on fixed code ==="
echo "worktree: $REPO  branch: $(git rev-parse --abbrev-ref HEAD)  sha: $(git rev-parse --short HEAD)"
cd "$REPO/Packages/FleetNetworking"
swift test \
  --filter "GatewayWebSocketTransportTests/testPeriodicBinaryFramesDoNotRefreshLiveness" \
  --filter "GatewayWebSocketTransportTests/testMalformedFrameFloodClosesConnectionPastThreshold" \
  2>&1 | tail -25
echo "=== exit: ${PIPESTATUS[0]} (0 = GREEN) ==="
