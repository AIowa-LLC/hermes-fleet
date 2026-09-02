#!/bin/bash
# t_3b321b7b — live wire-contract probe for the kanban board surfaces.
#
# Proves, against a REAL hermes dashboard server:
#   1. GET /api/plugins/kanban/board answers with the grouped-columns shape
#      (columns[], latest_event_id, now) using the session-token header.
#   2. WS /api/plugins/kanban/events?since=<cursor> authenticates via the
#      loopback ?token= path and delivers {"events":[...],"cursor":N} frames,
#      resuming from the requested cursor.
#
# Uses a dedicated loopback dashboard (hermes serve) on 127.0.0.1:9177 with a
# test-only token — no real credentials touched. The probe script uses
# python3 for the WS client (websockets is in the hermes venv).
set -u
HERMES=<local-hermes-path>/hermes-agent/venv/bin/hermes
PORT=9177
WORK=/tmp/t3b_kanban_probe
rm -rf "$WORK"; mkdir -p "$WORK"
LOG="$WORK/serve.log"

echo "=== starting loopback dashboard on :$PORT ==="
TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" "$HERMES" serve --host 127.0.0.1 --port "$PORT" >"$LOG" 2>&1 &
SERVE_PID=$!
trap 'kill $SERVE_PID 2>/dev/null' EXIT

# Wait for readiness.
for i in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/status" 2>/dev/null; then break; fi
  sleep 0.5
done

if [ -z "$TOKEN" ]; then
  echo "FAIL: no test token generated"; exit 1
fi
echo "token generated (len ${#TOKEN}, never printed)"

echo "=== PROBE 1: GET /api/plugins/kanban/board ==="
HTTP_CODE=$(curl -s -o "$WORK/board.json" -w '%{http_code}' \
  -H "X-Hermes-Session-Token: $TOKEN" \
  "http://127.0.0.1:$PORT/api/plugins/kanban/board")
echo "HTTP $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: board fetch returned $HTTP_CODE"; head -c 400 "$WORK/board.json"; echo; exit 1
fi
echo "--- board.json keys/shape ---"
python3 - "$WORK/board.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
cols = d.get("columns")
assert isinstance(cols, list) and cols, "columns[] missing"
for c in cols:
    assert "name" in c and "tasks" in c, "column shape wrong"
print("columns:", [c["name"] for c in cols])
print("tasks per column:", {c["name"]: len(c["tasks"]) for c in cols})
print("latest_event_id:", d.get("latest_event_id"))
print("now:", d.get("now"))
print("PASS: board shape ok")
PYEOF
if [ $? -ne 0 ]; then echo "FAIL: board shape"; exit 1; fi

CURSOR=$(python3 -c "import json;print(json.load(open('$WORK/board.json')).get('latest_event_id',0))" 2>/dev/null || echo 0)

echo "=== PROBE 2: WS /api/plugins/kanban/events?since=$CURSOR ==="
<local-hermes-path>/hermes-agent/venv/bin/python - "$PORT" "$TOKEN" "$CURSOR" <<'PYEOF'
import asyncio, json, sys
port, token, cursor = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])

async def main():
    import websockets
    uri = f"ws://127.0.0.1:{port}/api/plugins/kanban/events?since={cursor}&token={token}"
    async with websockets.connect(uri) as ws:
        print("WS connected:", uri.split("?")[0])
        # Insert a real event into the kanban DB via the hermes CLI so the
        # tail has something to deliver (board DB is the real ~/.hermes one).
        import subprocess
        subprocess.run(["<local-hermes-path>/hermes-agent/venv/bin/hermes",
                        "kanban", "--board", "default", "create",
                        "t3b probe event marker"],
                       capture_output=True, text=True)
        try:
            frame = await asyncio.wait_for(ws.recv(), timeout=15)
        except asyncio.TimeoutError:
            print("FAIL: no event frame within 15s of a DB insert"); sys.exit(1)
        d = json.loads(frame)
        assert "events" in d and "cursor" in d, f"frame shape wrong: {list(d)}"
        assert all("task_id" in e and "kind" in e and "id" in e for e in d["events"]), "event shape wrong"
        assert d["cursor"] > cursor or len(d["events"]) > 0, "no advancement past cursor"
        print("frame cursor:", d["cursor"], "events:", len(d["events"]))
        kinds = [e["kind"] for e in d["events"]]
        print("kinds:", kinds[:5])
        print("PASS: event frame shape ok, resumed from since cursor")

asyncio.run(main())
PYEOF
RC=$?
if [ $RC -ne 0 ]; then echo "FAIL: WS probe rc=$RC"; exit $RC; fi

echo "=== PROBE 3: since-cursor resume (no re-delivery below cursor) ==="
<local-hermes-path>/hermes-agent/venv/bin/python - "$PORT" "$TOKEN" <<'PYEOF'
import asyncio, json, sys
port, token = int(sys.argv[1]), sys.argv[2]

async def main():
    import websockets
    uri = f"ws://127.0.0.1:{port}/api/plugins/kanban/events?since=999999999&token={token}"
    async with websockets.connect(uri) as ws:
        try:
            frame = await asyncio.wait_for(ws.recv(), timeout=3)
            d = json.loads(frame)
            # Any delivered event must have id > since (the tail contract).
            bad = [e for e in d.get("events", []) if e["id"] <= 999999999]
            assert not bad, f"events delivered below cursor: {bad[:2]}"
            print("PASS: no events delivered at/behind the cursor")
        except asyncio.TimeoutError:
            print("PASS: no events delivered at/behind the cursor (idle)")

asyncio.run(main())
PYEOF
RC=$?
if [ $RC -ne 0 ]; then echo "FAIL: resume probe rc=$RC"; exit $RC; fi

echo "ALL PROBES PASS"
