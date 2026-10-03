#!/bin/bash
# rt5_docs_green.sh — RT5 P2-11 + ADR regression test (GREEN side).
# Runs the SAME docs-truth contract as rt5_docs_red.sh against the FIXED tree.
# Must exit 0 with FAIL=0. Run AFTER the RT5 fix is applied:
#   bash scripts/rt5_docs_green.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

echo "=== rt5_docs_green: docs-truth contract on FIXED tree ==="
echo "sha: $(git rev-parse --short HEAD)  branch: $(git rev-parse --abbrev-ref HEAD)"
echo ""

# Reuse the identical contract; on the fixed tree every check must PASS.
bash scripts/rt5_docs_red.sh
RC=$?

echo ""
if [ "$RC" -eq 0 ]; then
  echo "ALL GREEN — docs truth + 5 ADRs verified"
else
  echo "SOME RED — inspect output above"
fi
exit "$RC"
