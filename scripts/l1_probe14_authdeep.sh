#!/bin/bash
# L1 live gateway dogfood — determine why loopback serve is gated, whether a
# non-gated loopback surface is achievable, and whether the legacy ?token= WS
# path (the app's .loopbackToken strategy) is accepted on a fresh loopback
# serve. No secrets printed.
set -u
VENV=~/.hermes/hermes-agent/venv/bin
VENV_PY=$VENV/python
HERMES=$VENV/hermes
PORT=9119
WORK=/tmp/l1_live_test
mkdir -p "$WORK"

echo "=== L1 auth-gate deep dive ==="

echo
echo "--- default profile config: auth/dashboard/password/public_url ---"
grep -niE "^auth|^dashboard|public_url|password|auth_required|serve:" ~/.hermes/config.yaml | head -25

echo
echo "--- token_auth_middleware: does loopback token header set request.state.session? ---"
sed -n '980,1040p' ~/.hermes/hermes-agent/hermes_cli/web_server.py

echo
echo "--- serve.log from the last fresh run (full) ---"
cat "$WORK/serve.log" 2>/dev/null | head -40

echo
echo "--- START fresh serve + test ?token= WS path (non-gated loopback expectation) ---"
TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"
HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" "$HERMES" serve --host 127.0.0.1 --port "$PORT" > "$WORK/serve2.log" 2>&1 &
SERVE_PID=$!
OK=""
for i in $(seq 1 30); do
  sleep 1
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then OK=yes; break; fi
done
[ -z "$OK" ] && { echo "  serve failed to open port"; tail -20 "$WORK/serve2.log"; kill $SERVE_PID 2>/dev/null; exit 1; }
sleep 1
echo "  serve pid $SERVE_PID ready"

# Attempt WS connect with ?token= (the loopback legacy path)
"$VENV_PY" - "$TOKEN" <<'PYEOF'
import asyncio, json, sys
try:
    import websockets
except ImportError:
    print("no websockets"); sys.exit(0)
token = sys.argv[1]
async def main():
    for url in (f"ws://127.0.0.1:9119/api/ws?token={token}",
                "ws://127.0.0.1:9119/api/ws"):
        try:
            async with websockets.connect(url, open_timeout=4) as ws:
                await ws.send(json.dumps({"jsonrpc":"2.0","id":1,"method":"gateway.ping","params":{}}))
                r = await asyncio.wait_for(ws.recv(), timeout=5)
                print(f"  CONNECTED {url.split('?')[0]}: resp {str(r)[:100]}")
        except Exception as e:
            print(f"  {url.split('?')[0]}: {type(e).__name__}: {str(e)[:100]}")
asyncio.run(main())
PYEOF

kill $SERVE_PID 2>/dev/null
sleep 1
rm -f "$WORK/.token"
echo
echo "--- serve2.log tail ---"
tail -15 "$WORK/serve2.log" 2>/dev/null
echo "=== Done ==="
