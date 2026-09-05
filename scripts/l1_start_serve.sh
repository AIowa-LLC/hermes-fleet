#!/bin/bash
# L1 live gateway dogfood — start a PERSISTENT real Hermes gateway surface
# (loopback, fresh serve) for the Phase 2/3 UI dogfood. Writes the test-only
# token to /tmp/l1_live_test/.token (chmod 600) for the XCUITest to consume.
# The token is never printed. Prints the serve PID for later teardown.
set -u
VENV=~/.hermes/hermes-agent/venv/bin
HERMES=$VENV/hermes
PORT=9119
WORK=/tmp/l1_live_test
mkdir -p "$WORK"

echo "=== L1: start persistent live gateway surface on :$PORT ==="

# Refuse to double-start. Scope the liveness check to LOOPBACK: a serve
# bound to the tailnet IP on the same port is a DIFFERENT surface and must
# not satisfy this check (t_8fd26e02/Q1: the unscoped check reused a
# tailnet-bound listener while the app's 127.0.0.1:9119 endpoint was dead).
# The token file is likewise only reusable when it belongs to OUR serve pid.
if lsof -nP -iTCP@127.0.0.1:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
   && [ -f "$WORK/.token" ] && [ -f "$WORK/.servepid" ] \
   && kill -0 "$(cat "$WORK/.servepid")" 2>/dev/null; then
  echo "  already listening on 127.0.0.1:$PORT — reusing"
  lsof -nP -iTCP@127.0.0.1:$PORT -sTCP:LISTEN -t | head -1 > "$WORK/.servepid"
  cat "$WORK/.servepid"
  exit 0
fi

TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
umask 077
echo "$TOKEN" > "$WORK/.token"
chmod 600 "$WORK/.token"

HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN" nohup "$HERMES" serve --host 127.0.0.1 --port "$PORT" \
  > "$WORK/serve-persist.log" 2>&1 &
echo $! > "$WORK/.servepid"
echo "  serve pid $(cat "$WORK/.servepid")"

OK=""
for i in $(seq 1 30); do
  sleep 1
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then OK=yes; break; fi
done
[ -z "$OK" ] && { echo "  ERROR: serve failed"; tail -15 "$WORK/serve-persist.log"; exit 1; }
echo "  serve ready on loopback :$PORT (token file at $WORK/.token, chmod 600)"
echo "=== Done ==="
