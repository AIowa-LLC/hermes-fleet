#!/bin/bash
# S3 (B2) RED check: run the new cleartext-classifier unit tests against the
# PRE-FIX code (no PrivateNetwork.isPrivateOrLoopbackHost yet). They must FAIL
# (compile error: unresolved identifier) before the fix — proving the tests
# target a real missing capability:
#   - RFC1918 / loopback / .local / localhost classification
#   - public IPv4 and bare hostnames classified NOT private
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

echo "=== RED run: expect FAILURE on pre-fix code ==="

echo; echo "--- FleetCore: PrivateNetworkClassifierTests (must fail to compile) ---"
(cd Packages/FleetCore && swift test \
  --filter "PrivateNetworkClassifierTests" 2>&1) | \
  grep -E "error:|cannot find|Test Case|Executed .* tests|failed" | tail -30

echo; echo "NOTE: RED is a compile failure (unresolved 'PrivateNetwork') on base main."
