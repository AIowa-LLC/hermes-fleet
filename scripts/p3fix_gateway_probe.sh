#!/bin/bash
# t_eb5455f2: verify the live LAN gateway is up and the password-login flow
# still works (curl probe, no secrets printed). Read-only.
set -u
H=<lan-ip>
P=9120
CRED=/tmp/hermes_lan_surface/.cred

echo "=== LAN gateway reachability ==="
if ! curl -sS -m 5 -o /dev/null -w "providers HTTP %{http_code}\n" "http://$H:$P/api/auth/providers"; then
  echo "  ERROR: gateway not reachable"
  exit 1
fi

if [ ! -r "$CRED" ]; then
  echo "  ERROR: creds file missing/unreadable: $CRED"
  exit 1
fi
# Load creds WITHOUT printing them; validate shape only.
u=$(sed -n 's/^username=//p' "$CRED")
pw=$(sed -n 's/^password=//p' "$CRED")
if [ -z "$u" ] || [ -z "$pw" ]; then
  echo "  ERROR: .cred missing username/password keys"
  exit 1
fi
echo "  .cred readable (username len=${#u}, password len=${#pw}); values NOT printed"

# Full password flow probe: providers -> password-login (capture cookie) -> ws-ticket.
JAR=$(mktemp /tmp/p3fix_cookie.XXXXXX)
trap 'rm -f "$JAR"' EXIT
code=$(curl -sS -m 5 -o /tmp/p3fix_login.json -w "%{http_code}" \
  -c "$JAR" \
  -H "Content-Type: application/json" \
  -d "{\"provider\":\"basic\",\"username\":\"$u\",\"password\":\"$pw\"}" \
  "http://$H:$P/auth/password-login")
echo "  password-login HTTP $code"
if [ "$code" != "200" ]; then
  echo "  ERROR: password-login failed (creds may have rotated)"
  exit 1
fi
code=$(curl -sS -m 5 -o /tmp/p3fix_ticket.json -w "%{http_code}" \
  -b "$JAR" \
  -H "Content-Type: application/json" \
  -X POST "http://$H:$P/api/auth/ws-ticket")
echo "  ws-ticket HTTP $code (cookie replay)"
if [ "$code" != "200" ]; then
  echo "  ERROR: ws-ticket failed with session cookie"
  exit 1
fi
echo "  FLOW OK: password-login -> ws-ticket (session cookie path live)"
chmod 600 "$JAR"
echo "=== Done ==="
