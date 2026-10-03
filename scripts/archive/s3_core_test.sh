#!/bin/bash
# S3 (B2) — incremental: FleetCore classifier unit tests only.
# Run with: bash scripts/s3_core_test.sh
set -u
cd "$(dirname "$0")/.."
echo "=== FleetCore: PrivateNetworkClassifierTests (GREEN expected) ==="
(cd Packages/FleetCore && swift test --filter "PrivateNetworkClassifierTests" 2>&1) | \
  grep -E "Test Case|error:|Executed .* tests|failed" | tail -40
