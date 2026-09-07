#!/bin/bash
# L1 cleanup helper: terminate ONLY the test `hermes serve` bound to :9119
# (never the gateway daemon 87559). Safer than pkill -f.
set -u
PID=$(lsof -nP -iTCP:9119 -sTCP:LISTEN -t 2>/dev/null | head -1)
if [ -z "$PID" ]; then
  echo "  no listener on :9119 (nothing to clean)"
  exit 0
fi
# Safety: refuse if the PID is the canonical gateway daemon
GWPID=$(cat ~/.hermes/gateway.pid 2>/dev/null | tr -d ' \n')
if [ "$PID" = "$GWPID" ]; then
  echo "  REFUSING: pid $PID is the gateway daemon; aborting"
  exit 1
fi
echo "  terminating test serve pid $PID on :9119"
kill "$PID" 2>/dev/null || true
sleep 1
if lsof -nP -iTCP:9119 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "  still listening; sending SIGKILL"
  kill -9 "$PID" 2>/dev/null || true
  sleep 1
fi
echo "  remaining listeners on :9119:"
lsof -nP -iTCP:9119 -sTCP:LISTEN 2>/dev/null | tail -2 || echo "  none"
echo "=== cleanup done ==="
