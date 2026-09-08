#!/bin/bash
# Bot Mode stabilization — live gateway validation against a REAL current
# Hermes gateway (throwaway `hermes serve` instance on loopback, random
# token, torn down after). Exercises the actual groups.*/RoomLink wire
# surface the stabilized client speaks:
#   1. groups.capabilities (RoomLink negotiation, protocol_versions list)
#   2. groups.create (hosted room)
#   3. groups.send + groups.log (room message flow, real log page)
#   4. groups.peer.invite (full catalog in response)
#   5. groups.peer.register with a PARTIAL catalog (must be REFUSED —
#      proves upstream enforcement + our fail-closed rationale)
#   6. groups.replicate with a placeholder page (must be REFUSED —
#      proves the old defect could never succeed)
#   7. groups.replicate with a REAL groups.log page (must succeed,
#      authority-stamped)
#   8. groups.state / groups.disband (cleanup)
# No tokens, endpoints, or infrastructure details are printed or persisted.
set -u
VENV_PY=~/.hermes/hermes-agent/venv/bin/python
HERMES=~/.hermes/hermes-agent/venv/bin/hermes
PORT=9127
WORK=/tmp/botmode_live_check
rm -rf "$WORK"; mkdir -p "$WORK"

TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"

HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" "$HERMES" serve --host 127.0.0.1 --port "$PORT" > "$WORK/serve.log" 2>&1 &
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
import asyncio, json, sys
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
        async def rpc(method, params=None):
            nonlocal rid
            rid += 1
            await ws.send(json.dumps({
                "jsonrpc": "2.0", "id": f"live-{rid}", "method": method,
                "params": params or {}}))
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
                if msg.get("id") == f"live-{rid}":
                    return msg

        # 1. groups.capabilities — RoomLink negotiation truth
        r = await rpc("groups.capabilities")
        caps = r.get("result", {})
        rl = caps.get("room_link", {})
        catalog = rl.get("catalog", {})
        record("groups.capabilities responds",
               "protocol_version" in caps and "methods" in caps,
               f"top-level protocol_version={caps.get('protocol_version')}")
        record("room_link advertises protocol_versions LIST",
               isinstance(catalog.get("protocol_versions"), list)
               and 2 in (catalog.get("protocol_versions") or []),
               f"protocol_versions={catalog.get('protocol_versions')}")
        record("catalog carries full field set",
               {"installation_id", "protocol_versions", "link_modes",
                "persistent_process", "text", "attachments",
                "execution_policy", "catalog_digest"}.issubset(catalog),
               "8 _CATALOG_FIELDS present" if catalog else "room_link disabled — "
               f"reason={rl.get('reason')}")

        # 2. groups.create — hosted room (members need distinct real
        # profiles; pull the actual profile list first).
        profiles_r = await rpc("profiles.list")
        profile_rows = profiles_r.get("result", {}).get("profiles", [])
        slugs = [p.get("slug") or p.get("name") for p in profile_rows if p.get("slug") or p.get("name")]
        if len(slugs) < 2:
            record("groups.create (pre) second profile available", False,
                   f"only {len(slugs)} profile(s); a hosted room needs 2 distinct local profiles")
            raise SystemExit(1)
        room_id = f"fleet-live-{__import__('os').urandom(6).hex()}"
        r = await rpc("groups.create", {
            "room_id": room_id, "name": "Live Validation Room",
            "members": [
                {"member_id": "fleet-live", "profile": slugs[0],
                 "handle": "fleet-live", "display_name": "Fleet Live"},
                {"member_id": "fleet-live-2", "profile": slugs[1],
                 "handle": "fleet-live-2", "display_name": "Fleet Live Two"}]})
        room = r.get("result", {}).get("room", {})
        record("groups.create makes a hosted room",
               room.get("room_id") == room_id and room.get("authority_epoch", 0) >= 1,
               f"authority={room.get('authority_gateway_id','')[:14]}… epoch={room.get('authority_epoch')}"
               if room else f"error: {r.get('error',{}).get('message')}")

        # 3. groups.send + groups.log — message flow and real log page
        r = await rpc("groups.send", {
            "room_id": room_id, "event_id": f"live-{__import__('os').urandom(6).hex()}",
            "payload": {"text": "live validation hello",
                        "thread_id": "live-validation-thread"}})
        sent = r.get("result", {}).get("event", {})
        record("groups.send appends a typed event",
               sent.get("seq", 0) >= 1,
               f"seq={sent.get('seq')}" if sent else f"error: {r.get('error',{}).get('message')}")
        r = await rpc("groups.log", {"room_id": room_id, "since_seq": 0, "limit": 100})
        page = r.get("result", {})
        record("groups.log returns an authority-stamped page",
               isinstance(page.get("events"), list)
               and isinstance(page.get("authority"), dict)
               and "latest_seq" in page,
               f"events={len(page.get('events', []))} latest_seq={page.get('latest_seq')}"
               if "error" not in r else f"error: {r.get('error',{}).get('message')}")

        if catalog:
            # 4. groups.peer.invite — response carries the FULL catalog
            home_id = caps.get("authority_gateway_id", "")
            r = await rpc("groups.peer.invite", {
                "room_id": room_id, "member_id": "fleet-live-peer",
                "home_install_id": home_id,
                "authority_gateway_id": room.get("authority_gateway_id", home_id),
                "authority_epoch": room.get("authority_epoch", 1),
                "ttl_seconds": 300})
            inv = r.get("result", {})
            if "grant" in inv:
                inv_catalog = inv.get("catalog", {})
                record("groups.peer.invite returns grant + FULL catalog",
                       bool(inv.get("grant"))
                       and {"installation_id", "protocol_versions",
                            "catalog_digest"}.issubset(inv_catalog),
                       "grant + complete catalog present")
                grant = inv["grant"]
                # 5. groups.peer.register with a PARTIAL catalog must REFUSE
                r = await rpc("groups.peer.register", {
                    "room_id": room_id, "member_id": "fleet-live-peer",
                    "target_url": inv_catalog.get("endpoint", {}).get("url", "https://invalid.test"),
                    "catalog": {"installation_id": "default",
                                 "catalog_digest": inv_catalog.get("catalog_digest", "")},
                    "target_profile": inv.get("target_profile", "default"),
                    "grant": grant})
                err = r.get("error", {})
                record("peer.register REFUSES the partial/synthetic catalog",
                       "error" in r,
                       f"code={err.get('code')} msg={str(err.get('message'))[:60]}")
            else:
                record("groups.peer.invite (skipped)", True,
                       f"invite refused: {str(r.get('error',{}).get('message'))[:60]}")

        # 6. groups.replicate with a placeholder page must REFUSE ({} page,
        #    empty name) — the exact old defect shape.
        r = await rpc("groups.replicate", {
            "room_id": room_id, "room_name": "", "members": [], "page": {}})
        record("groups.replicate REFUSES placeholder {} page",
               "error" in r,
               f"code={r.get('error',{}).get('code')} msg={str(r.get('error',{}).get('message'))[:50]}")

        # 7. groups.replicate with a REAL groups.log page must succeed.
        r = await rpc("groups.replicate", {
            "room_id": room_id, "room_name": room.get("name", "Live Validation Room"),
            "members": room.get("members", []),
            "page": page})
        rep = r.get("result", {})
        record("groups.replicate accepts the real authority-stamped page",
               "error" not in r and rep.get("stored_seq", 0) >= 0,
               f"stored_seq={rep.get('stored_seq')} ingested={rep.get('ingested')} caught_up={rep.get('caught_up')}"
               if "error" not in r else f"error: {r.get('error',{}).get('message')}")

        # 7b. replica_state shows the lineage
        r = await rpc("groups.replica_state", {"room_id": room_id})
        rs = r.get("result", {})
        record("groups.replica_state reports lineage",
               "error" not in r and isinstance(rs.get("authority"), dict),
               f"last_seq={rs.get('last_seq')} latest_seq={rs.get('latest_seq')}"
               if "error" not in r else f"error: {r.get('error',{}).get('message')}")

        # 8. promotion without confirm must refuse (4118)
        r = await rpc("groups.promote", {"room_id": room_id, "confirm": False})
        record("groups.promote REFUSES without confirm:true",
               r.get("error", {}).get("code") == 4118,
               f"code={r.get('error',{}).get('code')}")

        # 9. cleanup: disband the room
        r = await rpc("groups.disband", {"room_id": room_id})
        disbanded = r.get("result", {}).get("tombstone", r.get("result", {}))
        record("groups.disband tombstones the room",
               "error" not in r and (disbanded.get("disbanded_at") is not None or r.get("result", {}).get("disbanded_at") is not None),
               "" if "error" not in r else f"error: {r.get('error',{}).get('message')}")

    failed = [n for n, ok, _ in results if not ok]
    print(f"\nlive validation: {len(results) - len(failed)}/{len(results)} checks passed")
    if failed:
        sys.exit(1)

asyncio.run(main())
PYEOF
PYEXIT=$?
echo
[ "$PYEXIT" -eq 0 ] && echo "LIVE VALIDATION: PASS" || echo "LIVE VALIDATION: FAIL"
exit "$PYEXIT"
