#!/bin/bash
# P0-8 (t_2432c60a): launch the two dashboard gateway listeners with a CLEAN
# environment — `env -i` minimum, NOT var-by-var unset. Root cause of the
# "wrong session" defect: the prior launchers were started from inside a
# kanban worker, so the gateway inherited HERMES_HOME=profiles/apple-dev,
# HERMES_SESSION_SOURCE=kanban, HERMES_SESSION_ID=<dead worker's session>,
# HERMES_KANBAN_RUN_ID/CLAIM_LOCK/DB etc. The multiplexer then routed the
# app's profile=default chat to an agent built in the apple-dev kanban-worker
# context — replies contained kanban reasoning/tool output (Tony's dogfood).
# A dashboard gateway serving the fleet app must run as a plain user process
# over the REAL default home, with zero kanban/session inheritance.
set -euo pipefail

CRED=/tmp/hermes_lan_surface/.cred
LAN_IP="${HERMES_FLEET_LAN_HOST:?Set HERMES_FLEET_LAN_HOST to YOUR gateway LAN host}"
TAIL_IP="${HERMES_FLEET_TAILNET_HOST:-}"
PORT=9120
VENV_HERMES="${HERMES_FLEET_HERMES_BIN:-$HOME/.hermes/hermes-agent/venv/bin/hermes}"

[ -f "$CRED" ] || { echo "FAIL: $CRED missing"; exit 1; }

USER_NAME=$(grep '^username=' "$CRED" | cut -d= -f2-)
PASS=$(grep '^password=' "$CRED" | cut -d= -f2-)
SECRET=$(grep '^secret=' "$CRED" | cut -d= -f2-)

# The default home's config references provider keys via ${env:...} refs
# (e.g. HERMES_GPT_BEARER_TOKEN in ~/.hermes/.env). Forward the .env lines
# that are actually SET so the model provider works; never echo values.
ENV_ARGS=()
if [ -f "$HOME/.hermes/.env" ]; then
  while IFS= read -r line; do
    case "$line" in
      \#*|"") continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    [ -n "$val" ] && ENV_ARGS+=("$key=$val")
  done < "$HOME/.hermes/.env"
fi
echo "forwarding ${#ENV_ARGS[@]} set vars from ~/.hermes/.env"

# Kill the CURRENT (contaminated) listeners — they hold kanban-worker env.
echo "== stopping contaminated listeners =="
for pid in $(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | sort -u); do
  echo "killing $pid ($(ps -p $pid -o command= | head -c 80))"
  kill "$pid" || true
done
sleep 2
if lsof -nP -iTCP:$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "FAIL: port $PORT still occupied"; exit 1
fi

mkdir -p /tmp/p08_gateways
LOG_LAN=/tmp/p08_gateways/lan.log
LOG_TAIL=/tmp/p08_gateways/tailnet.log

# env -i: hermetic. HERMES_HOME defaults to the real ~/.hermes (default
# profile home). PATH minimal for the venv hermes + system basics.
launch() { # $1=bind-ip $2=log
  env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$VENV_HERMES")" \
    HOME="$HOME" \
    HERMES_HOME="${HERMES_FLEET_HERMES_HOME:-$HOME/.hermes}" \
    HERMES_TIMEZONE=America/Chicago \
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$USER_NAME" \
    HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$PASS" \
    HERMES_DASHBOARD_BASIC_AUTH_SECRET="$SECRET" \
    "${ENV_ARGS[@]}" \
    "$VENV_HERMES" -p default dashboard --host "$1" --port "$PORT" --no-open --skip-build \
    > "$2" 2>&1 &
  echo $!
}

LAN_PID=$(launch "$LAN_IP" "$LOG_LAN")
TAIL_PID=""
if [ -n "$TAIL_IP" ]; then
  TAIL_PID=$(launch "$TAIL_IP" "$LOG_TAIL")
  echo "launched clean: lan=$LAN_PID tailnet=$TAIL_PID"
else
  echo "launched clean: lan=$LAN_PID (no HERMES_FLEET_TAILNET_HOST — single surface)"
fi

count_listeners() {
  { lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null || true; } | sort -u | wc -l | tr -d ' '
}

# Wait for both listeners, then VERIFY the environment is clean.
WANT=2; [ -z "$TAIL_IP" ] && WANT=1
for i in $(seq 1 45); do
  N=$(count_listeners)
  if [ "$N" -ge "$WANT" ]; then break; fi
  sleep 2
done
N=$(count_listeners)
echo "listeners up: $N (want $WANT)"
[ "$N" -ge "$WANT" ] || { echo "FAIL: gateways did not come up"; tail -5 "$LOG_LAN" ${TAIL_IP:+"$LOG_TAIL"}; exit 1; }

echo "== env verification (must show NO kanban/session vars, HERMES_HOME=~/.hermes) =="
FAIL=0
for pid in $(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | sort -u); do
  BAD=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -cE '^HERMES_KANBAN|^HERMES_SESSION_|^HERMES_PROFILE=' || true)
  HOMEV=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep '^HERMES_HOME=' || echo MISSING)
  echo "pid $pid: contaminated_vars=$BAD $HOMEV"
  [ "$BAD" -ne 0 ] && FAIL=1
  echo "$HOMEV" | grep -q "^HERMES_HOME=" || FAIL=1
done
[ "$FAIL" -eq 0 ] && echo "GATEWAY ENV CLEAN" || { echo "GATEWAY ENV STILL DIRTY"; exit 1; }
