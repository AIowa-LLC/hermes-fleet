#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #6: verify the REAL JSON-RPC WS
# surface + ws-ticket flow end-to-end (M11 contract), and Arch reachability.
# Prints status codes and close codes only — never ticket/token values.
set -u

VENV_PY=~/.hermes/hermes-agent/venv/bin/python
echo "=== L1 probe 6: live WS + ticket contract check ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- 1. Which loopback surfaces can mint a ticket (POST), and how ---
echo
echo "--- ws-ticket POST status per surface (no auth header) ---"
for BASE in "http://127.0.0.1:63597" "http://127.0.0.1:52875" "http://127.0.0.1:63474" "http://127.0.0.1:8642"; do
  CODE=$(curl -s -m 3 -o /dev/null -w "%{http_code}" -X POST -H "Accept: application/json" \
    -H "Content-Type: application/json" -d '{}' "$BASE/api/auth/ws-ticket" 2>/dev/null)
  echo "  $BASE/api/auth/ws-ticket -> HTTP $CODE"
done

# --- 2. Full WS handshake + JSON-RPC smoke test on the default serve surface ---
echo
echo "--- WS JSON-RPC smoke test (profiles.list) per surface ---"
"$VENV_PY" - <<'PYEOF'
import asyncio, json, sys

try:
    import websockets
except ImportError:
    print("websockets not importable in venv"); sys.exit(0)

SURFACES = [
    ("127.0.0.1", 63597, "default-serve(8108)"),
    ("127.0.0.1", 52875, "serve(87716)"),
    ("127.0.0.1", 63474, "apple-release-serve(7263)"),
    ("127.0.0.1", 8642, "hermes-webui(1235)"),
]

async def probe(host, port, label):
    url = f"ws://{host}:{port}/api/ws"
    try:
        async with websockets.connect(url, open_timeout=3, close_timeout=2) as ws:
            await ws.send(json.dumps({"jsonrpc":"2.0","id":1,"method":"profiles.list","params":{}}))
            try:
                resp = await asyncio.wait_for(ws.recv(), timeout=5)
                data = json.loads(resp)
                if data.get("id") == 1:
                    profiles = data.get("result") or []
                    print(f"  {label}: profiles.list OK -> {len(profiles) if isinstance(profiles,list) else 'non-list'} entries")
                else:
                    print(f"  {label}: response id mismatch: {str(data)[:120]}")
            except asyncio.TimeoutError:
                print(f"  {label}: connected but no RPC response (5s)")
    except websockets.exceptions.InvalidStatusCode as e:
        print(f"  {label}: WS handshake rejected HTTP {e.status_code}")
    except Exception as e:
        print(f"  {label}: WS error {type(e).__name__}: {str(e)[:120]}")

async def main():
    for host, port, label in SURFACES:
        await probe(host, port, label)

asyncio.run(main())
PYEOF

# --- 3. Arch reachability (multi-gateway check) ---
echo
echo "--- Arch (ssh <private-ssh-target>) reachability ---"
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
  <private-ssh-target> 'echo "arch: ok $(hostname)"; command -v hermes && hermes gateway status 2>&1 | head -8 || echo "arch: no hermes in PATH"' 2>&1 | head -12 || echo "  arch unreachable over ssh"

echo
echo "=== Done (no secrets printed) ==="
