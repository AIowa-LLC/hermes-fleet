#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #2: locate the /api/ws + ws-ticket
# routes, auth mode, and the JSON agent-roster surface. No secrets printed.
set -u

echo "=== L1 probe 2: WS + ticket routes ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

for BASE in "http://127.0.0.1:9900" "http://127.0.0.1:8642" "http://<tailnet-ip>:8642"; do
  echo
  echo "--- $BASE ---"
  # /api/ws should 400/426/redirect on a plain GET (WebSocket handshake only)
  curl -s -m 3 -o /dev/null -w "  GET /api/ws            -> HTTP %{http_code}\n" "$BASE/api/ws" 2>&1 || echo "  /api/ws unreachable"
  # ws-ticket is POST-only; a GET should 405 if the route exists
  curl -s -m 3 -o /dev/null -w "  GET /api/auth/ws-ticket -> HTTP %{http_code}\n" "$BASE/api/auth/ws-ticket" 2>&1 || echo "  /api/auth/ws-ticket unreachable"
  # dashboard auth public paths often expose /api/auth/status
  curl -s -m 3 -o /dev/null -w "  GET /api/auth/status    -> HTTP %{http_code}\n" "$BASE/api/auth/status" 2>&1 || true
  # agent roster JSON (what the app's profiles.list / roster expects to mirror)
  TAG=$(echo "$BASE" | tr -c 'a-zA-Z0-9' '_')
  curl -s -m 3 -o /tmp/l1_roster_$TAG.txt -w "  GET / (roster)          -> HTTP %{http_code}\n" "$BASE/" 2>&1 || true
done

echo
echo "=== Agent roster content (non-secret) ==="
if [ -s /tmp/l1_roster_http___127_0_0_1_9900.txt ]; then
  cat /tmp/l1_roster_http___127_0_0_1_9900.txt | head -c 2000; echo
fi
echo
echo "=== Done (no secrets printed) ==="
