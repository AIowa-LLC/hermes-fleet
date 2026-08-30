#!/bin/bash
# t_f54b722e: full WS chain through the tailnet forwarder (127.0.0.1:19120),
# matching the app exactly: cookie jar login -> ws-ticket -> WS connect +
# gateway.ready. Diagnoses whether the forwarder passes the WS upgrade.
set -u
umask 077
WORK=/tmp/hermes_lan_surface
CRED="$WORK/.cred"
VENV_PY=~/.hermes/hermes-agent/venv/bin/python
JAR=$(mktemp /tmp/t2w_cookies.XXXXXX)
TICKET=$(mktemp /tmp/t2w_ticket.XXXXXX)
trap 'rm -f "$JAR" "$TICKET"' EXIT
set -a; source "$CRED" 2>/dev/null; set +a
U="${username:-}"; P="${password:-}"
unset username password

echo "=== WS chain via forwarder 127.0.0.1:19120 -> <tailnet-ip>:9120 ==="
code=$(curl -s -m 8 -c "$JAR" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"provider\":\"basic\",\"username\":\"$U\",\"password\":\"$P\"}" \
  http://127.0.0.1:19120/auth/password-login)
echo "[login] HTTP $code (expect 200)"
code=$(curl -s -m 8 -b "$JAR" -o "$TICKET" -w '%{http_code}' -H 'Accept: application/json' -X POST \
  http://127.0.0.1:19120/api/auth/ws-ticket)
echo "[ticket] HTTP $code"
T=$(grep -o '"ticket":"[^"]*"' "$TICKET" | sed 's/.*"ticket":"//;s/"$//')
[ -n "$T" ] || { echo "  no ticket"; exit 1; }
echo "[ws] connecting through forwarder..."
"$VENV_PY" - "$T" <<'PYEOF'
import asyncio, json, sys
ticket = sys.argv[1]
url = f"ws://127.0.0.1:19120/api/ws?ticket={ticket}"
async def main():
    try:
        import websockets
    except ImportError:
        print("  no websockets"); return
    try:
        async with websockets.connect(url, open_timeout=8) as ws:
            f = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
            print("  [first frame] " + str(f.get("params", {}).get("type"))[:60])
            await ws.send(json.dumps({"jsonrpc":"2.0","id":"rpc-1","method":"gateway.ping","params":{}}))
            while True:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
                if f.get("id") == "rpc-1":
                    print("  gateway.ping -> " + str(f.get("result"))[:60]); break
    except Exception as e:
        print(f"  WS FAILED: {type(e).__name__}: {str(e)[:200]}")
asyncio.run(main())
PYEOF
echo "=== END ==="
