#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #10: probe Arch's known IPs for the
# /api/ws + ws-ticket surfaces from the Mac. No secrets printed.
set -u
VENV_PY=~/.hermes/hermes-agent/venv/bin/python

echo "=== L1 probe 10: Arch WS surfaces from Mac ==="

for IP in <lan-ip> <tailnet-ip>; do
  echo
  echo "--- $IP:8642 ---"
  for P in "api/ws" "api/auth/ws-ticket" "api/auth/status" ""; do
    C=$(curl -s -m 3 -o /tmp/l1arch_${IP}.txt -w "%{http_code}" "http://$IP:8642/$P" 2>/dev/null)
    echo "  /$P -> HTTP $C"
  done
  head -c 300 /tmp/l1arch_${IP}.txt 2>/dev/null; echo
done

echo
echo "--- WS JSON-RPC handshake attempt (unauthenticated, expect 401/403) ---"
"$VENV_PY" - <<'PYEOF'
import asyncio, sys
try:
    import websockets
except ImportError:
    print("no websockets"); sys.exit(0)
async def main():
    for ip in ("<lan-ip>", "<tailnet-ip>"):
        url = f"ws://{ip}:8642/api/ws"
        try:
            async with websockets.connect(url, open_timeout=3) as ws:
                print(f"  {ip}: connected (unexpected)")
        except Exception as e:
            print(f"  {ip}: {type(e).__name__}: {str(e)[:100]}")
asyncio.run(main())
PYEOF

echo
echo "=== Done ==="
