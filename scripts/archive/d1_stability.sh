#!/bin/bash
# D1 stability: run the new regression tests 6x to confirm determinism
# (the original defect was intermittent).
set -u
cd "$(dirname "$0")/.."
cd Packages/FleetNetworking
for i in 1 2 3 4 5 6; do
  OUT=$(swift test --filter testSocketDeathDuringHandshake 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "run $i: $OUT"
done
