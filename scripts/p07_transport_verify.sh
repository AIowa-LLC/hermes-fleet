#!/bin/bash
# t_8a7f3dce (P0-7): LIVE tailnet verification — build + run the REAL
# FleetCore/FleetNetworking conversation path (GatewayConversationSession over
# GatewayWebSocketTransport, username/password authenticator) against the live
# gateway through the loopback forwarder 19120 -> <tailnet-ip>:9120.
#
# Assertions (scripts/p07_transport_verify_main.swift):
#   [A] connect → session.create → send → reply streams;
#   [B] POP (subscriber cancelled) → RE-ENTER (fresh subscription + connect()
#       on the STILL-OPEN shared session) → send → reply streams, no
#       "connect() from open";
#   [C] NEW session.create → usable.
# Plus a server-side check: exactly ONE gateway WS connection across [A]-[C]
# (counted from the forwarder log window).
#
# Zero-print rule: .cred values are sourced and exported to the verifier as
# env vars only; NEVER echoed. Tooling: script files + bash only.
set -u
REPO=<repo-root>
cd "$REPO" || exit 1
CRED=/tmp/hermes_lan_surface/.cred
[ -r "$CRED" ] || { echo "FATAL: $CRED missing"; exit 1; }
set -a; source "$CRED" 2>/dev/null; set +a
export P07_USER="${username:-}"; export P07_PASS="${password:-}"
unset username password secret
[ -n "$P07_USER" ] && [ -n "$P07_PASS" ] || { echo "FATAL: cred keys incomplete"; exit 1; }
export P07_BASE="http://127.0.0.1:19120"

mkdir -p build
FWD_PID=""
if ! nc -z -w 2 127.0.0.1 19120 2>/dev/null; then
  python3 scripts/t2_tcp_forward.py 19120 <tailnet-ip> 9120 > /tmp/p07_fwd_19120.log 2>&1 &
  FWD_PID=$!
  echo "  forwarder started (pid $FWD_PID)"
fi
trap '[ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null' EXIT
sleep 1
nc -z -w 2 127.0.0.1 19120 || { echo "FATAL: forwarder 19120 DOWN"; exit 1; }

WS_BEFORE=$(grep -ac "GET /api/ws" /tmp/p07_fwd_19120.log 2>/dev/null || echo 0)

echo "=== build verifier (real package sources) ==="
# SwiftPM has already compiled FleetCore/FleetSecurity/FleetNetworking object
# files under Packages/FleetNetworking/.build (its dependency closure). Build
# the driver against the module interfaces and link those REAL objects — no
# recompile, no source duplication, exactly the code the app ships.
BD=Packages/FleetNetworking/.build/arm64-apple-macosx/debug
SEC=Packages/FleetSecurity/.build/arm64-apple-macosx/debug
mkdir -p build/p07_modules
cp scripts/p07_transport_verify_main.swift build/p07_modules/main.swift
swiftc \
  -I "$BD/Modules" -I "$SEC/Modules" \
  build/p07_modules/main.swift \
  "$BD"/FleetCore.build/*.o \
  "$SEC"/FleetSecurity.build/*.o \
  "$BD"/FleetNetworking.build/*.o \
  -o build/p07_verify 2> /tmp/p07_link.log
if [ $? -ne 0 ]; then echo "BUILD FAILED"; head -30 /tmp/p07_link.log; exit 1; fi

echo "=== run live verification ==="
./build/p07_verify
RC=$?

WS_AFTER=$(grep -ac "GET /api/ws" /tmp/p07_fwd_19120.log 2>/dev/null || echo 0)
echo "=== server-side: gateway WS connections during run: $((WS_AFTER - WS_BEFORE)) (expect 1) ==="
if [ "$RC" -eq 0 ] && [ "$((WS_AFTER - WS_BEFORE))" -eq 1 ]; then
  echo "P0-7 LIVE VERIFICATION PASSED (single connection across entry/re-entry/new-session)"
  exit 0
fi
echo "P0-7 LIVE VERIFICATION FAILED (rc=$RC, ws_delta=$((WS_AFTER - WS_BEFORE)))"
exit "$RC"
