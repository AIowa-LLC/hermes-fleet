#!/bin/bash
# F1 follow-up guards: FleetUI must not import FleetNetworking; gitleaks scan.
set -u
cd "$(dirname "$0")/.."
echo "=== FleetUI -> FleetNetworking imports ==="
COUNT=$(grep -rn "import FleetNetworking" Packages/FleetUI/Sources || true | wc -l | tr -d ' ')
echo "import count: $COUNT"
if [ "$COUNT" != "0" ]; then echo "FAIL"; exit 1; fi
echo "PASS"
if command -v gitleaks >/dev/null 2>&1; then
  echo "=== gitleaks (full worktree) ==="
  if gitleaks detect --source . --no-git --redact -v 2>&1 | tail -3; then
    echo "gitleaks: clean"
  else
    rc=${PIPESTATUS[0]}
    if [ "$rc" = "1" ]; then echo "gitleaks: FINDINGS"; exit 1; fi
  fi
else
  echo "gitleaks not installed — skipped"
fi
