#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #7: per-profile WS prefixes on the
# multiplexed gateway surface (:9900), api_server platform (:8642 Tailscale),
# and hermes-webui WS path. Also check device + simulator state.
# No secrets printed.
set -u
VENV_PY=~/.hermes/hermes-agent/venv/bin/python

echo "=== L1 probe 7: per-profile WS surfaces + device state ==="

echo
echo "--- HTTP route probes on multiplexed gateway :9900 ---"
for P in "api/ws" "apple/api/ws" "apple-dev/api/ws" "apple-release/api/ws" "default/api/ws" "api/auth/ws-ticket" "apple/api/auth/ws-ticket"; do
  C=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:9900/$P" 2>/dev/null)
  echo "  /$P -> $C"
done

echo
echo "--- WS JSON-RPC on per-profile prefixes (with ticket where needed) ---"
"$VENV_PY" - <<'PYEOF'
import asyncio, json, sys
try:
    import websockets
except ImportError:
    print("no websockets"); sys.exit(0)

TARGETS = [
    ("ws://127.0.0.1:9900/apple/api/ws", ":9900/apple/api/ws"),
    ("ws://127.0.0.1:9900/default/api/ws", ":9900/default/api/ws"),
    ("ws://127.0.0.1:9900/api/ws", ":9900/api/ws"),
]

async def main():
    for url, label in TARGETS:
        try:
            async with websockets.connect(url, open_timeout=3, close_timeout=2) as ws:
                await ws.send(json.dumps({"jsonrpc":"2.0","id":1,"method":"profiles.list","params":{}}))
                try:
                    resp = await asyncio.wait_for(ws.recv(), timeout=4)
                    print(f"  {label}: connected, RPC resp {str(resp)[:160]}")
                except asyncio.TimeoutError:
                    print(f"  {label}: connected, no RPC resp")
        except Exception as e:
            print(f"  {label}: {type(e).__name__}: {str(e)[:110]}")

asyncio.run(main())
PYEOF

echo
echo "--- simulator + device state ---"
xcrun simctl list devices booted 2>/dev/null | head -8
echo "device (iPhone 16 Pro Max):"
xcrun devicectl list devices 2>/dev/null | grep -iE "iphone|connected" | head -8 || echo "  devicectl: no devices listed"

echo
echo "=== Done ==="
