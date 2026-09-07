#!/bin/bash
# L1 live gateway dogfood — PHASE 1b (lean): prove the REAL JSON-RPC surface
# over ?token= with the FAST RPCs only (gateway.ready, profiles.list,
# session.list, session.create). No agent-turn prompt.submit (slow).
# Test-only token, never printed; instance torn down after.
set -u
VENV=~/.hermes/hermes-agent/venv/bin
VENV_PY=$VENV/python
HERMES=$VENV/hermes
PORT=9119
WORK=/tmp/l1_live_test
mkdir -p "$WORK"

echo "=== L1 Phase 1b lean: live JSON-RPC surface proof (?token=) ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"

HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" "$HERMES" serve --host 127.0.0.1 --port "$PORT" > "$WORK/serve4.log" 2>&1 &
SERVE_PID=$!
OK=""
for i in $(seq 1 30); do
  sleep 1
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then OK=yes; break; fi
done
[ -z "$OK" ] && { echo "serve failed"; tail -20 "$WORK/serve4.log"; kill $SERVE_PID 2>/dev/null; exit 1; }
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
        try:
            f = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
            t = f.get("params",{}).get("type")
            print(f"  [event] {t}")
        except asyncio.TimeoutError:
            print("  no ready frame")

        async def rpc(rid, method, params, timeout=20):
            await ws.send(json.dumps({"jsonrpc":"2.0","id":rid,"method":method,"params":params}))
            while True:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
                if f.get("id") == rid:
                    return f

        r = await rpc(1, "profiles.list", {})
        res = r.get("result")
        if isinstance(res, list):
            slugs = [p.get("slug") or p.get("name") for p in res]
            print(f"  profiles.list OK: {len(res)} profiles -> {slugs}")
        else:
            print(f"  profiles.list: {str(res)[:200]}"); ok=False

        r = await rpc(2, "session.list", {"limit":20,"offset":0,"profile":"default","sort":"recent"})
        res2 = r.get("result")
        n = len(res2) if isinstance(res2, list) else (res2 or {}).get("sessions") and len((res2 or {}).get("sessions")) or 0
        print(f"  session.list: result={str(res2)[:140]}")

        r = await rpc(3, "session.create", {"close_on_disconnect":True,"profile":"default"})
        sid = (r.get("result") or {}).get("session_id")
        print(f"  session.create: sid present={bool(sid)}")

        r = await rpc(4, "session.events.since", {"session_id":sid or "","last_seen":0})
        evs = (r.get("result") or {}).get("events", [])
        print(f"  session.events.since: {len(evs) if evs else 0} events")

        r = await rpc(5, "gateway.ping", {})
        print(f"  gateway.ping: {str(r.get('result'))[:80]}")

asyncio.run(main())
sys.exit(0 if ok else 2)
PYEOF
RC=$?

kill $SERVE_PID 2>/dev/null
sleep 1
rm -f "$WORK/.token"
echo
echo "  RC=$RC"
echo "=== Done ==="
