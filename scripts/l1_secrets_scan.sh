#!/bin/bash
# L1: secrets hygiene scan before committing — flag any hardcoded token-like
# literals in the new L1 files. The test token is generated at runtime, chmod
# 600, never printed; nothing should be hardcoded.
set -u
cd ~/code/hermes-fleet-ios

echo "=== L1: pre-commit secrets scan ==="
FILES=$(git status --short | grep -E '^\?\?' | awk '{print $2}' | grep -E 'L1|l1')
for f in $FILES; do
  # look for long random-looking literals, token= assignments, or bearer values
  HITS=$(grep -nE "([A-Za-z0-9_-]{24,})|token *= *['\"][^'\"]{12,}|bearer [A-Za-z0-9]" "$f" 2>/dev/null | grep -vE "tokenPath|tokenField|testToken|\.token|tokens|sessionToken|tokenText|HERMES_DASHBOARD_SESSION_TOKEN|readTestToken|L1_TOKEN|ws-ticket|ticket=" | head -5)
  if [ -n "$HITS" ]; then
    echo "  $f:"
    echo "$HITS" | sed 's/^/    /'
  fi
done

echo
echo "--- verify no committed token value: scan /tmp/l1_live_test/.token vs repo ---"
if [ -f /tmp/l1_live_test/.token ]; then
  TOK=$(cat /tmp/l1_live_test/.token)
  CNT=$(grep -rF "$TOK" docs/L1-live-dogfood.md HermesFleetAppUITests/L1LiveGatewayUITests.swift scripts/l1_*.sh 2>/dev/null | wc -l | tr -d ' ')
  echo "  occurrences of the test token in evidence files: $CNT (must be 0)"
else
  echo "  token file already cleaned (as expected)"
fi
echo "=== Done ==="
