#!/bin/bash
# S2 (B1) regression RED check: run the new launch-stable-identity regression
# tests against the PRE-FIX code. They must FAIL before the fix:
#   - duplicate-text messages must NOT collide on id (hashValue fallback collides)
#   - synthesized id must be a launch-stable UUID (hashValue is a random int)
#   - two fresh model containers from the same persisted store must yield
#     identical ids (pre-fix the seam does not persist a client identity)
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

echo "=== RED run: expect FAILURES on pre-fix code ==="

echo; echo "--- FleetCore: SessionReadDomainTests (identity) ---"
(cd Packages/FleetCore && swift test \
  --filter "testDuplicateTextMessagesKeepDistinctIDs" \
  --filter "testSynthesizedIDIsLaunchStableUUID" \
  --filter "testMessageIdentityPrefersRowID" 2>&1) | \
  grep -E "Test Case|error:|failed|passed|Executed .* tests" | tail -30

echo; echo "--- FleetPersistence: SwiftDataCacheStoreTests (fresh containers) ---"
(cd Packages/FleetPersistence && swift test \
  --filter "testFreshContainersRestoreIdenticalMessageIDs" 2>&1) | \
  grep -E "Test Case|error:|failed|passed|Executed .* tests" | tail -30
