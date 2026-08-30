#!/bin/bash
# t_f54b722e (T2): prove the TAILNET gateway serves a LIVE CONVERSATION TURN
# over the encrypted tailnet endpoint http://<tailnet-ip>:9120.
#
# Full chain: GET / (no auth -> expect 302) -> POST /auth/password-login (200)
# -> POST /api/auth/ws-ticket (200, ttl) -> WS /api/ws?ticket= (gateway.ready,
# gateway.ping, profiles.list, session.list) -> resume-or-create a session ->
# prompt.submit("Reply with exactly: PONG") -> collect message.*/message.complete
# frames. Then captures serve-tailnet.log frames around the turn as evidence.
#
# Zero-print rule: .cred values are sourced and used but NEVER echoed.
# Tooling: this is a script file run via `bash scripts/t2_tailnet_probe.sh`.
set -u
umask 077

WORK=/tmp/hermes_lan_surface
CRED="$WORK/.cred"
TAILNET_IP=<tailnet-ip>
PORT=9120
BASE="http://$TAILNET_IP:$PORT"
REPO=<repo-root>
E="$REPO/build/t2_evidence"
VENV_PY=~/.hermes/hermes-agent/venv/bin/python
mkdir -p "$E"
JAR=$(mktemp /tmp/t2_cookies.XXXXXX)
TICKET=$(mktemp /tmp/t2_ticket.XXXXXX)
LOGTAIL="$E/serve-tailnet-frame-window.txt"
trap 'rm -f "$JAR" "$TICKET"' EXIT

echo "=== T2 TAILNET PROBE: $(date '+%Y-%m-%d %H:%M:%S %Z') ==="

# --- [0] creds shape (no values) ---
[ -r "$CRED" ] || { echo "FATAL: $CRED missing"; exit 1; }
set -a; source "$CRED" 2>/dev/null; set +a
U="${username:-}"; P="${password:-}"
unset username password
[ -n "$U" ] && [ -n "$P" ] || { echo "FATAL: .cred keys incomplete"; exit 1; }
echo "[0] .cred readable (u_len=${#U} p_len=${#P}); values not printed"

# --- [1] auth gate ---
echo "[1] GET / (no auth) -> $(curl -s -m 6 -o /dev/null -w '%{http_code}' "$BASE/")  (expect 302)"

# --- [2] password-login ---
code=$(curl -s -m 6 -c "$JAR" -o /dev/null -w '%{http_code}' \
  -H "Content-Type: application/json" \
  -d "{\"provider\":\"basic\",\"username\":\"$U\",\"password\":\"$P\"}" \
  "$BASE/auth/password-login")
echo "[2] password-login -> HTTP $code (expect 200)"
[ "$code" = "200" ] || { echo "FATAL: login failed"; exit 1; }

# --- [3] ws-ticket ---
tcode=$(curl -s -m 6 -b "$JAR" -o "$TICKET" -w '%{http_code}' \
  -H "Accept: application/json" -X POST "$BASE/api/auth/ws-ticket")
echo "[3] ws-ticket -> HTTP $tcode"
"$VENV_PY" - "$TICKET" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("    ttl_seconds =", d.get("ttl_seconds"), "| ticket present =", bool(d.get("ticket")))
PYEOF
T=$(grep -o '"ticket":"[^"]*"' "$TICKET" | sed 's/.*"ticket":"//;s/"$//')
[ -n "$T" ] || { echo "FATAL: no ticket"; exit 1; }

# --- [4] snapshot serve-tailnet.log before the turn ---
BEFORE=$(wc -l < "$WORK/serve-tailnet.log" 2>/dev/null || echo 0)
echo "[4] serve-tailnet.log lines before turn: $BEFORE"

# --- [5] WS: ready / ping / profiles.list / session.list / ONE conversation turn ---
echo "[5] WS JSON-RPC over tailnet (gateway.ready, ping, profiles, sessions, PONG turn)"
"$VENV_PY" - "$T" "$TAILNET_IP" "$PORT" "$LOGTAIL" <<'PYEOF'
import asyncio, json, sys, time
ticket, ip, port, logtail = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
url = f"ws://{ip}:{port}/api/ws?ticket={ticket}"
frames = []

async def main():
    try:
        import websockets
    except ImportError:
        print("  FATAL: no websockets in venv python"); sys.exit(2)
    try:
        async with websockets.connect(url, open_timeout=6) as ws:
            # first frame = gateway.ready (handshake)
            try:
                f = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
                print("  [ready] " + str(f.get("params", {}).get("type"))[:60])
            except asyncio.TimeoutError:
                print("  [no ready frame within 6s]")
            rid = [0]
            def next_id():
                rid[0] += 1
                return f"rpc-{rid[0]}"
            async def rpc(method, params, timeout=30):
                i = next_id()
                await ws.send(json.dumps({"jsonrpc":"2.0","id":i,"method":method,"params":params}))
                while True:
                    f = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
                    if f.get("id") == i:
                        return f
                    # streamed event frames between send and response
                    if f.get("method") and "id" not in f:
                        frames.append(f)
            def evtype(f):
                return ((f.get("params") or {}).get("type") or "")

            async def collect_until(pred, timeout=240):
                # drain inbound event frames until pred satisfied or timeout
                deadline = time.time() + timeout
                while time.time() < deadline:
                    try:
                        f = json.loads(await asyncio.wait_for(ws.recv(), timeout=min(30, max(1, deadline-time.time()))))
                    except asyncio.TimeoutError:
                        continue
                    if f.get("id") is not None:
                        continue  # correlated response handled by rpc()
                    frames.append(f)
                    if pred(f):
                        return f
                return None

            r = await rpc("gateway.ping", {})
            print("  gateway.ping -> " + str(r.get("result"))[:80])
            r = await rpc("profiles.list", {})
            res = r.get("result")
            if isinstance(res, dict) and "profiles" in res:
                plist = res["profiles"]
                slugs = [(p.get("name") or p.get("slug")) for p in plist]
                default = [p for p in plist if p.get("is_default")]
                print(f"  profiles.list OK: {len(plist)} profiles, default={default[0].get('name') if default else '?'}, slugs={slugs[:4]}")
            else:
                print("  profiles.list -> " + str(res)[:200])
            r = await rpc("session.list", {"profile": "default", "limit": 5})
            sessions = (r.get("result") or {}).get("sessions", [])
            print(f"  session.list -> {len(sessions)} sessions for default")
            for s in sessions[:3]:
                print(f"    session id={s.get('id')} title={s.get('title')!r} msgs={s.get('message_count')}")

            # ONE conversation turn over the tailnet endpoint — FRESH session
            # (do not resume a possibly-busy cron session).
            r = await rpc("session.create", {"title": "T2 tailnet PONG", "profile": "default"})
            got = r.get("result") or {}
            sid = got.get("session_id") or (r.get("error") or {}).get("message")
            if "error" in r and r["error"]:
                print("  session.create ERROR: " + str(r["error"])[:200]); sys.exit(3)
            print(f"  session.create -> session_id={str(got.get('session_id'))[:24]} msgs={got.get('message_count')}")
            if not got.get("session_id"):
                print("  FATAL: no session id for turn"); sys.exit(3)

            r = await rpc("prompt.submit", {"session_id": got.get("session_id"), "text": "Reply with exactly: PONG"}, timeout=30)
            print("  prompt.submit result -> " + json.dumps(r.get("result"))[:160])
            if "error" in r and r["error"]:
                print("  prompt.submit ERROR: " + str(r["error"])[:200])

            # Persist the clean session's STORED id (the id session.list rows
            # use in the UI) for the T2 UI test to resume — the runtime
            # session_id from create is NOT the stored row id. We must NOT
            # resume a live cron session.
            import json as _json
            r = await rpc("session.list", {"profile": "default", "limit": 50}, timeout=30)
            all_sessions = (r.get("result") or {}).get("sessions", [])
            target = next((s for s in all_sessions if s.get("title") == "T2 tailnet PONG"), None)
            if target:
                with open("/tmp/t2_session.json", "w") as sf:
                    _json.dump({"session_id": target.get("id"), "title": target.get("title")}, sf)
                print(f"  clean session persisted -> /tmp/t2_session.json id={str(target.get('id'))[:24]}")
            else:
                with open("/tmp/t2_session.json", "w") as sf:
                    _json.dump({"session_id": "", "title": "T2 tailnet PONG"}, sf)
                print("  WARN: fresh session not found in session.list — wrote empty id")

            # Drain until message.complete for THIS session (events are
            # method:"event" with params.type = "message.complete").
            completed = await collect_until(lambda f: evtype(f) == "message.complete" and (f.get("params") or {}).get("session_id") == got.get("session_id"))
            turns = [f for f in frames if evtype(f) in ("message.start", "message.delta", "message.interim", "message.complete", "thinking.delta", "reasoning.delta", "tool.start", "tool.complete", "status.update")]
            if completed is not None:
                cp = completed.get("params") or {}
                print(f"  message.complete -> status={cp.get('payload',{}).get('status') if isinstance(cp.get('payload'),dict) else cp.get('status')} error={cp.get('payload',{}).get('error') if isinstance(cp.get('payload'),dict) else cp.get('error')}")
                print(f"  conversation turn frames captured: {len(turns)}")
            else:
                print(f"  WARN: no message.complete within 240s; captured {len(turns)} turn frames")
                print("  last event: " + str(frames[-1] if frames else None)[:240])

            # Write the captured frames (trimmed) to evidence file
            with open(logtail, "w") as fh:
                for fr in frames:
                    fh.write(json.dumps(fr) + "\n")
    except Exception as e:
        print(f"  WS FAILED: {type(e).__name__}: {str(e)[:200]}")
        sys.exit(1)

asyncio.run(main())
PYEOF
RC=$?

# --- [6] serve-tailnet.log frames around the turn ---
echo "[6] serve-tailnet.log lines after turn: $(wc -l < "$WORK/serve-tailnet.log" 2>/dev/null || echo 0) (before: $BEFORE)"
echo "    frame window captured -> $LOGTAIL ($(wc -l < "$LOGTAIL" 2>/dev/null) frames)"
tail -n 25 "$WORK/serve-tailnet.log" 2>/dev/null | grep -aE "prompt|session.create|session.resume|message\.|gateway\.ready|sessions\.changed" | tail -12 > "$E/serve-tailnet-turn-window.txt"
echo "    serve-log turn window -> $E/serve-tailnet-turn-window.txt ($(wc -l < "$E/serve-tailnet-turn-window.txt") lines)"

echo "=== T2 TAILNET PROBE exit=$RC ==="
exit $RC
