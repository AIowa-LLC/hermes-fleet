#!/bin/bash
# L1 live gateway dogfood — read the auth-gate wiring precisely.
set -u
H=~/.hermes/hermes-agent/hermes_cli/web_server.py

echo "=== should_require_auth (753) ==="
sed -n '753,800p' "$H"

echo
echo "=== _dashboard_public_hosts / _LOOPBACK_HOST_VALUES ==="
grep -n "_dashboard_public_hosts\|_LOOPBACK_HOST_VALUES =" "$H" | head

echo
echo "=== start_server auth_required assignment (19660-19710) ==="
sed -n '19660,19710p' "$H"

echo
echo "=== does serve use a different entry? main.py cmd_dashboard 11947-12060 ==="
sed -n '11947,12000p' ~/.hermes/hermes-agent/hermes_cli/main.py

echo "=== Done ==="
