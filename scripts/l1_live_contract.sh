#!/bin/bash
# L1 live gateway dogfood — PHASE 1b (retry): start fresh serve on :9119,
# probe its actual HTTP surface, then run the full M11 contract test.
# Test-only token, never printed, instance torn down at the end.
set -u
VENV=~/.hermes/hermes-agent/venv/bin
VENV_PY=$VENV/python
HERMES=$VENV/hermes
PORT=9119
WORK=/tmp/l1_live_test
mkdir -p "$WORK"

echo "=== L1 Phase 1b retry: real gateway end-to-end (test instance on :$PORT) ==="

TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"

HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" \
  "$HERMES" serve --host 127.0.0.1 --port "$PORT" \
  > "$WORK/serve.log" 2>&1 &
SERVE_PID=$!
echo "  serve pid: $SERVE_PID (loopback :$PORT)"

# Wait for TCP readiness (port open)
OK=""
for i in $(seq 1 30); do
  sleep 1
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then OK=yes; break; fi
done
if [ -z "$OK" ]; then
  echo "  ERROR: port never opened. Log tail:"; tail -20 "$WORK/serve.log"
  kill $SERVE_PID 2>/dev/null || true; exit 1
fi
sleep 1
echo "  port open"

# Probe the actual HTTP surface of a fresh loopback serve
echo "  --- fresh serve HTTP surface ---"
for P in "" "api/auth/status" "api/ws" "api/auth/ws-ticket"; do
  C=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/$P" 2>/dev/null)
  echo "    /$P -> $C"
done

# Run the full contract test
"$VENV_PY" - "$TOKEN" <<'PYEOF'
import asyncio, json, sys, urllib.request

token = sys.argv[1]
base = "http://127.0.0.1:9119"
ok = True

req = urllib.request.Request(
    base + "/api/auth/ws-ticket",
    data=b"{}",
    headers={"Accept": "application/json", "Content-Type": "application/json",
             "X-Hermes-Session-Token": token},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=6) as r:
        body = json.loads(r.read())
    ticket = body.get("ticket"); ttl = body.get("ttl_seconds")
    print(f"  ticket mint: HTTP 200, ttl_seconds={ttl}, ticket present={bool(ticket)}")
    if not ticket or ttl != 30:
        print("  FAIL: unexpected ticket envelope"); ok = False
except Exception as e:
    print(f"  ticket mint FAILED: {type(e).__name__}: {e}")
    ok = False; sys.exit(1)

try:
    import websockets
except ImportError:
    print("  no websockets"); ok = False; sys.exit(1)

async def run():
    global ok
    async with websockets.connect(f"ws://127.0.0.1:9119/api/ws?ticket={ticket}", open_timeout=5) as ws:
        try:
            first = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
            print(f"  first frame type: {first.get('params',{}).get('type')}")
        except asyncio.TimeoutError:
            print("  no first frame")
        async def rpc(rid, method, params):
            await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":method,"params":params}))
            while True:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
                if f.get("id") == rid:
                    return f
        r = await rpc(1, "profiles.list", {})
        res = r.get("result")
        if isinstance(res, list):
            print(f"  profiles.list OK: {len(res)} profiles -> {[p.get('name') or p.get('slug') for p in res]}")
        else:
            print(f"  profiles.list: {str(res)[:200]}"); ok = False
        r = await rpc(2, "session.list", {"limit": 20, "offset": 0, "profile": "default", "sort": "recent"})
        print(f"  session.list: {str(r.get('result'))[:200]}")
        r = await rpc(3, "session.create", {"close_on_disconnect": True, "profile": "default"})
        sid = (r.get("result") or {}).get("session_id")
        print(f"  session.create: session_id present={bool(sid)}")
        await ws.send(json.dumps({"jsonrpc":"2.0","id":4,"method":"prompt.submit",
                                  "params":{"session_id": sid, "text": "Reply with exactly: L1-DOGFOOD-OK"}}))
        got_start=got_delta=got_complete=False; collected=[]
        try:
            while True:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=90))
                ev = f.get("params",{}).get("type")
                if f.get("id")==4:
                    print(f"  prompt.submit response: {str(f.get('result'))[:120]}"); continue
                if ev=="message.start": got_start=True
                elif ev=="message.delta":
                    got_delta=True; collected.append(f["params"].get("text",""))
                elif ev=="message.complete":
                    got_complete=True
                    print(f"  message.complete status={f['params'].get('status')}")
                    break
        except asyncio.TimeoutError:
            print("  prompt.submit timed out")
        if got_start and got_delta and got_complete:
            print(f"  STREAMED REPLY OK start={got_start} delta={got_delta} complete={got_complete}")
            print(f"  reply snippet: {''.join(collected)[:160]}")
        else:
            print(f"  STREAM PARTIAL start={got_start} delta={got_delta} complete={got_complete}")
            ok=False

asyncio.run(run())
sys.exit(0 if ok else 2)
PYEOF
RC=$?

kill $SERVE_PID 2>/dev/null || true
sleep 1
rm -f "$WORK/.token"
echo
echo "  RC=$RC (0=full pass, 2=partial)"
echo "=== Done ==="
