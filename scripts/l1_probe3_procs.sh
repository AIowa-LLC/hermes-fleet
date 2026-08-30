#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #3: identify each Hermes process by
# command line so we know which surface serves /api/ws (dashboard web server).
# No secrets printed.
set -u

echo "=== L1 probe 3: Hermes process identification ==="
for PID in 87559 1235 1229 7263 8108 87716; do
  if ps -p $PID >/dev/null 2>&1; then
    CMD=$(ps -p $PID -o command= | cut -c1-220)
    echo "PID $PID: $CMD"
  fi
done

echo
echo "--- which python processes import web_server / dashboard_auth ---"
ps -eo pid,command | grep -iE "web_server|dashboard_auth|hermes" | grep -v grep | cut -c1-200 | head -20

echo
echo "--- gateway runtime status files (default profile home) ---"
ls -la ~/.hermes/gateway* 2>/dev/null | head -10
find ~/.hermes -maxdepth 1 -name "*.pid" -o -maxdepth 1 -name "*runtime*" 2>/dev/null | head
echo "=== Done ==="
