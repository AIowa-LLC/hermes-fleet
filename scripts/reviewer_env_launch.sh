#!/bin/bash
# reviewer_env_launch.sh — provision a disposable, isolated Hermes gateway
# for external TestFlight review (issue #18).
#
# Creates a throwaway HERMES_HOME with synthetic demo content, launches an
# authenticated `hermes serve` bound to loopback with the dashboard auth gate
# engaged via HERMES_DASHBOARD_PUBLIC_URL, and prints (never executes) the
# cloudflared tunnel commands for the operator.
#
# SECRET-FREE BY CONSTRUCTION: no endpoint, credential, or token is committed
# here. Credentials come from env vars, a Keychain item, or are freshly
# generated at runtime into a 0600 file OUTSIDE the repository. The provider
# (model) key is forwarded from a 0600 operator file and never printed.
#
# See docs/release/REVIEWER-ENVIRONMENT.md for the full design.
#
# Usage:
#   REVIEWER_PUBLIC_URL=https://<host> [options] reviewer_env_launch.sh start
#   reviewer_env_launch.sh status|stop
#   reviewer_env_launch.sh clean [--purge]
set -u

HERMES_BIN_DEFAULT="$HOME/.hermes/hermes-agent/venv/bin/hermes"
HERMES_BIN="${REVIEWER_HERMES_BIN:-$HERMES_BIN_DEFAULT}"

# Defaults live under TMPDIR so a forgotten `clean` cannot outlive a reboot.
REVIEWER_ENV_DIR="${REVIEWER_ENV_DIR:-${TMPDIR:-/tmp}/hermes-fleet-reviewer}"
HOME_DIR="$REVIEWER_ENV_DIR/home"
CREDS_FILE="$REVIEWER_ENV_DIR/credentials"
PID_FILE="$REVIEWER_ENV_DIR/serve.pid"
LOG_FILE="$REVIEWER_ENV_DIR/serve.log"
SERVE_PORT="${REVIEWER_SERVE_PORT:-9318}"
KEYCHAIN_ITEM="${REVIEWER_KEYCHAIN_ITEM:-}"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
require_hermes() {
  [ -x "$HERMES_BIN" ] || die "hermes not found at '$HERMES_BIN' (set REVIEWER_HERMES_BIN)"
}

# ---------------------------------------------------------------- credentials
# Resolve reviewer credentials: explicit env, then a Keychain generic password
# (password field only; never echoed), else freshly generated and stored 0600
# in the env dir. Secrets are NEVER accepted as command-line arguments.
resolve_credentials() {
  if [ -n "${REVIEWER_USERNAME:-}" ] && [ -n "${REVIEWER_PASSWORD:-}" ]; then
    REVIEWER_SECRET="${REVIEWER_SECRET:-$(openssl rand -hex 32)}"
    return
  fi
  if [ -n "$KEYCHAIN_ITEM" ]; then
    command -v security >/dev/null 2>&1 || die "security(1) unavailable for Keychain read"
    REVIEWER_USERNAME="${REVIEWER_USERNAME:-$(security find-generic-password -s "$KEYCHAIN_ITEM" -a username -w 2>/dev/null || true)}"
    REVIEWER_PASSWORD="${REVIEWER_PASSWORD:-$(security find-generic-password -s "$KEYCHAIN_ITEM" -w 2>/dev/null || true)}"
    [ -n "$REVIEWER_USERNAME" ] && [ -n "$REVIEWER_PASSWORD" ] \
      || die "Keychain item '$KEYCHAIN_ITEM' missing username/password data"
    REVIEWER_SECRET="${REVIEWER_SECRET:-$(openssl rand -hex 32)}"
    return
  fi
  if ! mkdir -p "$REVIEWER_ENV_DIR"; then die "cannot create $REVIEWER_ENV_DIR"; fi
  chmod 700 "$REVIEWER_ENV_DIR" || die "cannot chmod 700 $REVIEWER_ENV_DIR"
  if [ -s "$CREDS_FILE" ]; then
    REVIEWER_USERNAME="$(sed -n 's/^username=//p' "$CREDS_FILE")"
    REVIEWER_PASSWORD="$(sed -n 's/^password=//p' "$CREDS_FILE")"
    REVIEWER_SECRET="$(sed -n 's/^secret=//p' "$CREDS_FILE")"
    [ -n "$REVIEWER_USERNAME" ] && [ -n "$REVIEWER_PASSWORD" ] && [ -n "$REVIEWER_SECRET" ] \
      || die "credentials file $CREDS_FILE is malformed — delete it to regenerate"
    info "reusing generated credentials from $CREDS_FILE"
  else
    umask 077
    REVIEWER_USERNAME="${REVIEWER_USERNAME:-reviewer}"
    REVIEWER_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | head -c 24)"
    REVIEWER_SECRET="$(openssl rand -hex 32)"
    printf 'username=%s\npassword=%s\nsecret=%s\n' \
      "$REVIEWER_USERNAME" "$REVIEWER_PASSWORD" "$REVIEWER_SECRET" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE" || die "chmod 600 $CREDS_FILE failed"
    info "generated fresh reviewer credentials (0600) at $CREDS_FILE"
  fi
}

# ------------------------------------------------------------ home validation
# The reviewer home must be a disposable directory — never the maintainer's
# default Hermes home and never inside this repository.
validate_home() {
  case "$HOME_DIR" in
    "$HOME"/.hermes|"$HOME"/.hermes/) die "REFUSING to use the default Hermes home ($HOME/.hermes) as the reviewer environment" ;;
  esac
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  case "$REVIEWER_ENV_DIR/" in
    "$repo_root"/*) die "REFUSING to place the disposable env dir inside the repository" ;;
  esac
}

# --------------------------------------------------------------------- seed
# Synthetic demo content ONLY — no personal data, no production tokens.
seed_demo_content() {
  info "creating demo bot profiles (a Bot IS a Hermes profile)"
  HERMES_HOME="$HOME_DIR" "$HERMES_BIN" profile create reviewer-demo-oracle \
    --description "Answers questions about this disposable demo Hermes gateway." >/dev/null 2>&1 \
    || info "profile reviewer-demo-oracle already exists — reusing"
  HERMES_HOME="$HOME_DIR" "$HERMES_BIN" profile create reviewer-demo-scribe \
    --description "Demonstrates a second synthetic roster entry for review." >/dev/null 2>&1 \
    || info "profile reviewer-demo-scribe already exists — reusing"

  local assets_dir soul
  assets_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewer_env_assets"
  for bot in oracle scribe; do
    mkdir -p "$HOME_DIR/profiles/reviewer-demo-$bot"
    soul="$assets_dir/reviewer-demo-$bot.SOUL.md"
    if [ -f "$soul" ]; then
      cp "$soul" "$HOME_DIR/profiles/reviewer-demo-$bot/SOUL.md"
    else
      printf 'You are %s, a synthetic demo bot on a disposable Hermes review gateway. Be brief and friendly. Never claim to have personal data or production access.\n' \
        "reviewer-demo-$bot" > "$HOME_DIR/profiles/reviewer-demo-$bot/SOUL.md"
    fi
  done

  if [ -f "$assets_dir/reviewer-demo/SKILL.md" ]; then
    mkdir -p "$HOME_DIR/skills/reviewer-demo"
    cp "$assets_dir/reviewer-demo/SKILL.md" "$HOME_DIR/skills/reviewer-demo/SKILL.md"
    info "installed safe demo skill 'reviewer-demo'"
  else
    info "WARN: reviewer_env_assets/reviewer-demo/SKILL.md missing — demo skill not installed"
  fi
}

# -------------------------------------------------------------------- start
do_start() {
  require_hermes
  [ -n "${REVIEWER_PUBLIC_URL:-}" ] || die "REVIEWER_PUBLIC_URL is required (the tunnel URL, or http://127.0.0.1:$SERVE_PORT for a loopback rehearsal)"
  validate_home
  resolve_credentials

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    die "a serve process is already running (pid $(cat "$PID_FILE")); run 'stop' first"
  fi

  mkdir -p "$HOME_DIR" || die "cannot create $HOME_DIR"
  seed_demo_content

  # Optional model-key forwarding from a 0600 operator file outside the repo.
  local provider_env=()
  if [ -n "${REVIEWER_PROVIDER_ENV_FILE:-}" ]; then
    [ -f "$REVIEWER_PROVIDER_ENV_FILE" ] || die "REVIEWER_PROVIDER_ENV_FILE not found (create it with KEY=value lines, chmod 600, outside the repository)"
    [ "$(stat -f '%Lp' "$REVIEWER_PROVIDER_ENV_FILE" 2>/dev/null || echo 000)" = "600" ] \
      || die "REVIEWER_PROVIDER_ENV_FILE must be chmod 600"
    while IFS= read -r line; do
      case "$line" in '#'*|'') continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      provider_env+=("$line")
    done < "$REVIEWER_PROVIDER_ENV_FILE"
    info "forwarding ${#provider_env[@]} provider variables into the serve process (values never printed)"
  else
    info "no REVIEWER_PROVIDER_ENV_FILE — chat replies will lack a model key until one is supplied"
  fi

  # Hermetic launch (pattern proven by scripts/p08_launch_gateways_hermetic.sh):
  # env -i + explicit allowlist so no maintainer session/kanban/profile vars
  # leak into the reviewer gateway process.
  env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$HERMES_BIN")" \
    HOME="$HOME" \
    HERMES_HOME="$HOME_DIR" \
    HERMES_TIMEZONE="${HERMES_TIMEZONE:-America/Chicago}" \
    HERMES_DASHBOARD_PUBLIC_URL="$REVIEWER_PUBLIC_URL" \
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$REVIEWER_USERNAME" \
    HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$REVIEWER_PASSWORD" \
    HERMES_DASHBOARD_BASIC_AUTH_SECRET="$REVIEWER_SECRET" \
    "${provider_env[@]+"${provider_env[@]}"}" \
    "$HERMES_BIN" serve --host 127.0.0.1 --port "$SERVE_PORT" --skip-build \
    >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  info "serve pid $pid -> 127.0.0.1:$SERVE_PORT (log: $LOG_FILE)"

  local ok=""
  for _ in $(seq 1 30); do
    sleep 1
    if lsof -nP -iTCP@127.0.0.1:"$SERVE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then ok=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
  done
  if [ -z "$ok" ]; then
    info "serve failed to come up — last log lines:"
    tail -15 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    die "reviewer gateway did not start"
  fi
  info "backend up on loopback :$SERVE_PORT (auth gate engaged via HERMES_DASHBOARD_PUBLIC_URL)"

  printf '\nTUNNEL (operator/Tony executes — this script never does):\n'
  printf '  quick rehearsal:  cloudflared tunnel --url http://127.0.0.1:%s\n' "$SERVE_PORT"
  printf '  review window:    cloudflared tunnel login && cloudflared tunnel create fleet-reviewer && \\\n'
  printf '                    cloudflared tunnel route dns fleet-reviewer <your-reviewer-host> && \\\n'
  printf '                    cloudflared tunnel run --url http://127.0.0.1:%s fleet-reviewer\n' "$SERVE_PORT"
  printf '  then verify:      REVIEWER_BASE_URL=https://<host> REVIEWER_CRED_FILE=%s \\\n' "$CREDS_FILE"
  printf '                      bash scripts/reviewer_env_check.sh\n'
  printf '\nNext: keep the Mac awake for the window (caffeinate -dimsu) and use a\n'
  printf 'persistent REVIEWER_ENV_DIR if state must survive reboots.\n'
}

# -------------------------------------------------------------------- status
do_status() {
  printf 'reviewer env dir : %s\n' "$REVIEWER_ENV_DIR"
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    printf 'serve process    : RUNNING (pid %s)\n' "$(cat "$PID_FILE")"
  else
    printf 'serve process    : not running\n'
  fi
  if lsof -nP -iTCP@127.0.0.1:"$SERVE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    printf 'loopback :%s : LISTENING\n' "$SERVE_PORT"
  else
    printf 'loopback :%s : down\n' "$SERVE_PORT"
  fi
  [ -d "$HOME_DIR" ] && printf 'demo home        : present (%s)\n' "$HOME_DIR" || printf 'demo home        : absent\n'
}

# --------------------------------------------------------------------- stop
do_stop() {
  local pid
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && info "stopped serve pid $pid"
    else
      info "stale pid file (pid ${pid:-none}) — removing"
    fi
    rm -f "$PID_FILE"
  else
    info "no pid file — nothing recorded to stop"
  fi
  # Belt-and-braces: kill anything still listening on the reviewer port.
  local stragglers
  stragglers="$(lsof -nP -iTCP@127.0.0.1:"$SERVE_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
  if [ -n "$stragglers" ]; then
    # shellcheck disable=SC2086
    kill $stragglers 2>/dev/null || true
    info "killed remaining listener(s) on :$SERVE_PORT"
  fi
}

# -------------------------------------------------------------------- clean
do_clean() {
  do_stop
  local purge=1
  [ "${1:-}" = "--purge" ] && purge=1
  if [ "$purge" = 1 ]; then
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    case "$REVIEWER_ENV_DIR/" in
      "$repo_root"/*) die "REFUSING to purge inside the repository" ;;
    esac
    case "$REVIEWER_ENV_DIR" in
      "$HOME"/.hermes*) die "REFUSING to purge the default Hermes home" ;;
    esac
    [ "$REVIEWER_ENV_DIR" = "/" ] && die "REFUSING to purge /"
    rm -rf "$REVIEWER_ENV_DIR" && info "removed $REVIEWER_ENV_DIR (home, credentials, logs)"
    # Demo bot profiles are Hermes profiles; profile create installs a command
    # alias at ~/.local/bin/<name>. Remove ours so nothing outlives the env.
    for alias in reviewer-demo-oracle reviewer-demo-scribe; do
      if [ -L "$HOME/.local/bin/$alias" ] || [ -f "$HOME/.local/bin/$alias" ]; then
        rm -f "$HOME/.local/bin/$alias" && info "removed profile command alias ~/.local/bin/$alias"
      fi
    done
  else
    info "state kept under $REVIEWER_ENV_DIR"
  fi
}

# --------------------------------------------------------------------- main
cmd="${1:-}"
case "$cmd" in
  start) do_start ;;
  status) do_status ;;
  stop) do_stop ;;
  clean) shift; do_clean "$@" ;;
  *) die "usage: $0 start|status|stop|clean [--purge]" ;;
esac
