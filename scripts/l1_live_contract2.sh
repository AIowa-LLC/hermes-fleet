#!/bin/bash
# L1 live gateway dogfood — PHASE 1b (final): full server-side protocol proof
# over the REAL WS surface using the legacy ?token= path (the app's
# .loopbackToken strategy). Real profiles.list / session.list / session.create
# / prompt.submit / session.events.since against a fresh loopback serve.
# Test-only token, never printed; instance torn down after.
set -u
VENV=~/.hermes/hermes-agent/venv/bin
VENV_PY=$VENV/python
HERMES=$VENV/hermes
PORT=9119
WORK=/tmp/l1_live_test
mkdir -p "$WORK"

echo "=== L1 Phase 1b: real gateway JSON-RPC via ?token= ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"

HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" "$HERMES" serve --host 127.0.0.1 --port "$PORT" > "$WORK/serve3.log" 2>&1 &
SERVE_PID=$!
OK=""
for i in $(seq 1 30); do
  sleep 1
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then OK=yes; break; fi
done
[ -z "$OK" ] && { echo "serve failed"; kill $SERVE_PID 2>/dev/null; exit 1; }
sleep 1
echo "  serve pid $SERVE_PID ready on loopback :$PORT"

"$VENV_PY" - "$TOKEN" <<'PYEOF'
import asyncio, json, sys
try:
    import websockets
except ImportError:
    print("no websockets"); sys.exit(1)
token = sys.argv[1]
ok = True

async def main():
    global ok
    url = f"ws://127.0.0.1:9119/api/ws?token={token}"
    async with websockets.connect(url, open_timeout=5) as ws:
        # gateway.ready
        try:
            f = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
            print(f"  [event] {f.get('params',{}).get('type')}")
        except asyncio.TimeoutError:
            print("  no ready frame")

        async def rpc(rid, method, params, timeout=20):
            await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":method,"params":params}))
            while True:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
                if f.get("id") == rid:
                    return f

        # profiles.list (roster of real bots)
        r = await rpc(1, "profiles.list", {})
        res = r.get("result")
        if isinstance(res, list):
            slugs = [p.get("slug") or p.get("name") for p in res]
            print(f"  profiles.list OK: {len(res)} profiles -> {slugs}")
        else:
            print(f"  profiles.list: {str(res)[:200]}"); ok = False

        # session.list
        r = await rpc(2, "session.list", {"limit":20,"offset":0,"profile":"default","sort":"recent"})
        print(f"  session.list: {str(r.get('result'))[:160]}")

        # session.create
        r = await rpc(3, "session.create", {"close_on_disconnect":True,"profile":"default"})
        sid = (r.get("result") or {}).get("session_id")
        print(f"  session.create: sid present={bool(sid)}")
        if not sid: ok = False

        # prompt.submit — real agent turn
        await ws.send(json.dumps({"jsonrpc":"2.0","id":4,"method":"prompt.submit",
                                  "params":{"session_id":sid,"text":"Reply with exactly: L1-DOGFOOD-OK"}}))
        got_start=got_delta=got_complete=False; collected=[]
        try:
            while True:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=90))
                ev = f.get("params",{}).get("type")
                if f.get("id")==4:
                    print(f"  prompt.submit resp: {str(f.get('result'))[:100]}"); continue
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
            print(f"  reply: {''.join(collected)[:200]}")
        else:
            print(f"  STREAM PARTIAL start={got_start} delta={got_delta} complete={got_complete}")
            ok = False

        # session.events.since (replay path)
        r = await rpc(5, "session.events.since", {"session_id":sid,"last_seen":0})
        n = len(r.get("result",{}).get("events",[]) or [])
        print(f"  session.events.since: {n} events")
        if n <= 0: ok = False

asyncio.run(main())
sys.exit(0 if ok else 2)
PYEOF
RC=$?

kill $SERVE_PID 2>/dev/null
sleep 1
rm -f "$WORK/.token"
echo
echo "  RC=$RC (0=full pass, 2=partial/fail)"
echo "=== Done ==="
