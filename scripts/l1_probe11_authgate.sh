#!/bin/bash
# L1 live gateway dogfood — investigate the dashboard auth gate: what flips
# auth_required for `hermes serve`/`dashboard` on loopback, and whether the
# loopback token path (X-Hermes-Session-Token) is accepted anywhere.
# No secrets printed.
set -u

HERMES_SRC=~/.hermes/hermes-agent

echo "=== L1 auth gate investigation ==="

echo
echo "--- should_require_auth definition ---"
grep -rn "def should_require_auth" "$HERMES_SRC/hermes_cli/" 2>/dev/null | head -5

echo
echo "--- start_server: how auth_required is set ---"
grep -n "auth_required" "$HERMES_SRC/hermes_cli/web_server.py" | head -40

echo
echo "--- config: any dashboard/auth keys in default profile config ---"
grep -niE "auth_required|dashboard:|dashboard.auth|public_url|password" ~/.hermes/config.yaml | head -20

echo
echo "--- serve start log from earlier test (fresh instance) ---"
tail -30 /tmp/l1_live_test/serve.log 2>/dev/null

echo
echo "--- how do the RUNNING serve instances differ? check their start lines ---"
ps -eo pid,command | grep -E "hermes.*(serve|dashboard)" | grep -v grep | cut -c1-220 | head

echo "=== Done ==="
