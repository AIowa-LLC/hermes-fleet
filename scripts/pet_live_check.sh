#!/usr/bin/env bash
# #9 — live gateway contract smoke test for the Pet avatar surface.
# Spins a REAL throwaway `hermes serve` on loopback (throwaway HERMES_HOME
# carrying one real installed pet, random token, torn down after) and
# exercises the actual pet.* wire surface the Fleet client speaks:
#   1. pet.gallery (full)        — typed rows (slug/displayName/installed/
#                                  spritesheetUrl), thousands-scale
#   2. pet.gallery {localOnly}   — installed-only subset, no remote fetch
#   3. pet.thumb (installed pet) — PNG data URI, signature-valid
#   4. pet.thumb ok:false path   — unknown slug answers ok:false (never
#                                  an error envelope): honest unavailable
#   5. router -32601             — the method-not-found shape the Swift
#                                  client maps to petsUnavailable
# No tokens, endpoints, or infrastructure details are printed or persisted.
# NOTE: the throwaway HERMES_HOME is REQUIRED — a real ~/.hermes config
# declaring a non-loopback dashboard.public_url puts the server in gated
# auth mode where the legacy ?token= is rejected (403).
set -u
VENV_PY=~/.hermes/hermes-agent/venv/bin/python
HERMES=~/.hermes/hermes-agent/venv/bin/hermes
PORT=9131
WORK=/tmp/pet_live_check
rm -rf "$WORK"; mkdir -p "$WORK/home/pets"

# One REAL installed pet from the live home so pet.thumb has a local
# sheet to render (any installed pet works; teknium ships with Hermes).
for candidate in ~/.hermes/pets/*; do
  [ -d "$candidate" ] && cp -R "$candidate" "$WORK/home/pets/" && break
done

TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"

HERMES_HOME="$WORK/home" \
HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" \
  "$HERMES" serve --host 127.0.0.1 --port "$PORT" > "$WORK/serve.log" 2>&1 &
SERVE_PID=$!
cleanup() {
  kill "$SERVE_PID" 2>/dev/null
  wait "$SERVE_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

OK=""
for i in $(seq 1 40); do
  sleep 1
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then OK=yes; break; fi
done
[ -z "$OK" ] && { echo "FAIL: serve did not start"; tail -20 "$WORK/serve.log"; exit 1; }
sleep 1
echo "live gateway up (loopback, throwaway)"

"$VENV_PY" - "$TOKEN" "$PORT" <<'PYEOF'
import asyncio, json, sys, base64
import websockets

token, port = sys.argv[1], sys.argv[2]
uri = f"ws://127.0.0.1:{port}/api/ws?token={token}"
results = []

def record(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail else ""))

async def main():
    async with websockets.connect(uri, max_size=16 * 1024 * 1024) as ws:
        rid = 0
        async def rpc(method, params):
            nonlocal rid
            rid += 1
            key = f"r{rid}"
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": key, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("id") == key:
                    return msg

        # 1. Full gallery: typed rows at Petdex scale.
        full = await rpc("pet.gallery", {"profile": "default"})
        pets = (full.get("result") or {}).get("pets")
        record("pet.gallery (full) returns typed pets list",
               isinstance(pets, list) and len(pets) > 0, f"{len(pets or [])} entries")
        remote_row = None
        if pets:
            row = pets[0]
            record("gallery row shape (slug/displayName/installed/spritesheetUrl)",
                   all(k in row for k in ("slug", "displayName", "installed", "spritesheetUrl")),
                   f"keys: {sorted(row.keys())}")
            record("gallery reports installed state distinctly",
                   any(p.get("installed") for p in pets) and any(not p.get("installed") for p in pets))
            remote_row = next((p for p in pets if not p.get("installed")), None)

        # 2. localOnly phase: installed-only, no remote manifest fetch.
        local = await rpc("pet.gallery", {"profile": "default", "localOnly": True})
        lpets = (local.get("result") or {}).get("pets") or []
        record("pet.gallery localOnly returns installed-only subset",
               len(lpets) >= 1 and all(p.get("installed") for p in lpets),
               f"{len(lpets)} local entries")

        # 3. pet.thumb for the INSTALLED pet: idle-frame PNG data URI.
        target = lpets[0]["slug"] if lpets else None
        if target:
            thumb = await rpc("pet.thumb", {"profile": "default", "slug": target})
            res = thumb.get("result") or {}
            ok_png = False
            if res.get("ok") and res.get("dataUri", "").startswith("data:image/png;base64,"):
                raw = base64.b64decode(res["dataUri"].split("base64,", 1)[1])
                ok_png = raw[:8] == b"\x89PNG\r\n\x1a\n"
                record("pet.thumb (installed) returns a real PNG data URI", ok_png, f"{len(raw)} bytes")
            else:
                record("pet.thumb (installed) returns a real PNG data URI", False,
                       json.dumps(res)[:120])

        # 4. Unknown slug: ok:false, NOT an error envelope.
        ghost = await rpc("pet.thumb", {"profile": "default", "slug": "fleet-ghost-xyz"})
        gres = ghost.get("result") or {}
        record("pet.thumb unknown slug answers ok:false (no error envelope)",
               gres.get("ok") is False and "error" not in ghost,
               f"keys: {sorted(gres.keys())}")

        # 5. Method-not-found shape (what the Swift client maps to
        #    petsUnavailable, distinct from transient failures).
        bogus = await rpc("pet.fleet_probe", {"profile": "default"})
        record("router answers -32601 for unknown methods",
               (bogus.get("error") or {}).get("code") == -32601)

    failures = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failures)}/{len(results)} checks passed")
    sys.exit(1 if failures else 0)

asyncio.run(main())
PYEOF
RC=$?
[ "$RC" -eq 0 ] && echo "pet live contract: PASS" || echo "pet live contract: FAIL"
exit $RC
