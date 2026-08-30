#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #5: find EVERY surface serving the
# JSON-RPC /api/ws + /api/auth/ws-ticket routes among all Hermes listeners.
# No secrets printed.
set -u

echo "=== L1 probe 5: locate real /api/ws surface ==="

# Gather all unique IPv4 listener tuples for python/hermes processes
LISTENERS=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$1=="python" || $1=="python3" || $1=="python3.1" || $1=="node" {print $9}' | sort -u)

for ADDR in $LISTENERS; do
  # ADDR like "127.0.0.1:9900" or "<tailnet-ip>:8642" or "*:4750"
  HOST="${ADDR%:*}"
  PORT="${ADDR##*:}"
  [ -z "$PORT" ] && continue
  BASE="http://$HOST:$PORT"
  WS=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "$BASE/api/ws" 2>/dev/null)
  TK=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "$BASE/api/auth/ws-ticket" 2>/dev/null)
  AUTH=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "$BASE/api/auth/status" 2>/dev/null)
  echo "  $ADDR  /api/ws=$WS  /api/auth/ws-ticket=$TK  /api/auth/status=$AUTH"
done

echo
echo "--- hermes-webui /api/auth/status body (non-secret) ---"
curl -s -m 3 "http://127.0.0.1:8642/api/auth/status" 2>&1 | head -c 800; echo

echo
echo "--- hermes-webui is it a proxy or standalone? (route dispatch) ---"
grep -n "api/ws\|api/auth\|/ws\b\|websocket\|upgrade\|proxy\|subprocess\|Popen\|hermes" ~/hermes-webui/server.py 2>/dev/null | head -30
echo "=== Done ==="
