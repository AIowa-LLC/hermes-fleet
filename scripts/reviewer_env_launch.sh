#!/bin/bash
# reviewer_env_launch.sh (v2) — provision the reviewer Hermes gateway INSIDE A
# DISPOSABLE, HARDENED CONTAINER on a dedicated container host (issue #18).
#
# SECURITY ARCHITECTURE (v2 — supersedes the v1 "disposable HERMES_HOME on
# the maintainer Mac" design, which was NOT host isolation):
#
#   reviewer iPhone ──TLS──► cloudflared (operator-run, on the container host)
#                                │ loopback HTTP only
#                                ▼
#              Docker container: hermes-agent image
#                --cap-drop ALL --security-opt no-new-privileges
#                --user 10000:10000 --read-only --tmpfs /tmp
#                HERMES_HOME = named volume (disposable)
#                network: dedicated bridge, egress = public TCP/443 ONLY
#                (provider model APIs); host/LAN/tailnet/docker-net BLOCKED
#
#   Blast radius if the reviewer escapes the Hermes auth layer: the container
#   and its disposable volume. No host filesystem, no host credentials, no
#   Keychain, no maintainer Hermes state, no messaging integrations, no
#   production keys (only the low-limit demo model key), no host shell.
#
# This script runs ON THE CONTAINER HOST (it shells out to `docker`). It never
# creates tunnels and never accepts secrets as arguments. All secrets are
# generated into a 0600 file or a named docker volume outside any repository.
#
# Usage (on the container host, from the repo root):
#   REVIEWER_PUBLIC_URL=https://<host> bash scripts/reviewer_env_launch.sh start
#   bash scripts/reviewer_env_launch.sh status|stop
#   bash scripts/reviewer_env_launch.sh clean [--purge]
#
# Environment:
#   REVIEWER_PUBLIC_URL        required for start (engages the auth gate)
#   REVIEWER_IMAGE             docker image (default hermes-agent:0.21.1-reviewer,
#                              built from the local hermes-agent source Dockerfile)
#   REVIEWER_SERVE_PORT        host loopback port (default 9318)
#   REVIEWER_PROVIDER_ENV_FILE 0600 KEY=value file; ONLY allowlisted provider
#                              keys are forwarded (see reviewer_provider_env_lib.sh)
#   REVIEWER_ENV_DIR           state dir for credentials (default /tmp/…, 0700)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=reviewer_provider_env_lib.sh
. "$SCRIPT_DIR/reviewer_provider_env_lib.sh"

REVIEWER_IMAGE="${REVIEWER_IMAGE:-hermes-agent:0.21.1-reviewer}"
REVIEWER_ENV_DIR="${REVIEWER_ENV_DIR:-${TMPDIR:-/tmp}/hermes-fleet-reviewer}"
CREDS_FILE="$REVIEWER_ENV_DIR/credentials"
CONT_NAME="fleet-reviewer"
VOL_NAME="fleet-reviewer-home"
NET_NAME="fleet-reviewer"
SERVE_PORT="${REVIEWER_SERVE_PORT:-9318}"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found — this launcher must run on the dedicated container host (v2 architecture; the maintainer Mac is NOT the reviewer host)"
  docker info >/dev/null 2>&1 || die "docker daemon unreachable (permissions?)"
  docker image inspect "$REVIEWER_IMAGE" >/dev/null 2>&1 \
    || die "image $REVIEWER_IMAGE absent — build it from the hermes-agent source: cd <hermes-source> && docker build -t $REVIEWER_IMAGE ."
}

# ---------------------------------------------------------------- credentials
resolve_credentials() {
  mkdir -p "$REVIEWER_ENV_DIR" && chmod 700 "$REVIEWER_ENV_DIR" || die "cannot create $REVIEWER_ENV_DIR"
  if [ -s "$CREDS_FILE" ]; then
    REVIEWER_USERNAME="$(sed -n 's/^username=//p' "$CREDS_FILE")"
    REVIEWER_PASSWORD="$(sed -n 's/^password=//p' "$CREDS_FILE")"
    REVIEWER_SECRET="$(sed -n 's/^secret=//p' "$CREDS_FILE")"
    [ -n "$REVIEWER_USERNAME" ] && [ -n "$REVIEWER_PASSWORD" ] && [ -n "$REVIEWER_SECRET" ] \
      || die "credentials file $CREDS_FILE malformed — delete to regenerate"
    info "reusing generated credentials from $CREDS_FILE"
  else
    umask 077
    REVIEWER_USERNAME="reviewer"
    REVIEWER_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | head -c 24)"
    REVIEWER_SECRET="$(openssl rand -hex 32)"
    printf 'username=%s\npassword=%s\nsecret=%s\n' \
      "$REVIEWER_USERNAME" "$REVIEWER_PASSWORD" "$REVIEWER_SECRET" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE" || die "chmod 600 $CREDS_FILE failed"
    info "generated fresh reviewer credentials (0600) at $CREDS_FILE"
  fi
}

# ------------------------------------------------------------- network setup
# Dedicated bridge with egress limited to public TCP/443 (model provider APIs).
# Implemented in DOCKER-USER so it survives docker restarts of this network.
# On the reviewer network's subnet: allow established, allow DNS (docker
# internal resolver is not on this subnet), allow NEW outbound tcp/443 to
# NON-private destinations, drop everything else.
setup_network() {
  if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    docker network create --driver bridge --internal=false "$NET_NAME" >/dev/null \
      || die "cannot create docker network $NET_NAME"
    info "created dedicated bridge network $NET_NAME"
  fi
  SUBNET="$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  [ -n "$SUBNET" ] || die "cannot read subnet of $NET_NAME"
  # FAIL CLOSED on IPv6: the egress pinning below is iptables (IPv4) only. The
  # network is created IPv4-only, so there is no IPv6 address or route in the
  # container; if that ever changes the pinning would silently not apply.
  # (Independent QA finding, 2026-09-10.)
  if [ "$(docker network inspect "$NET_NAME" --format '{{.EnableIPv6}}')" != "false" ]; then
    die "network $NET_NAME has IPv6 enabled — the egress pinning is IPv4-only; refusing to launch (recreate the network without IPv6)"
  fi
  # Docker's internal resolver address. When the host's /etc/resolv.conf is a
  # loopback stub (systemd-resolved at 127.0.0.53), dockerd cannot use it from
  # a container netns and points containers at its own resolver proxy on the
  # default bridge gateway (visible as `# ExtServers: [<addr>]` in a
  # container's /etc/resolv.conf). That single docker-owned address is the
  # ONLY port-53 destination this environment allows — never a LAN router, a
  # public resolver, or a tailnet address.
  RESOLVER_ADDR="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  [ -n "$RESOLVER_ADDR" ] || die "cannot determine docker's internal resolver address (default bridge gateway)"
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO=sudo
  else
    # FAIL CLOSED: without programmable iptables the egress pinning cannot be
    # applied, and an unpinned reviewer network is unacceptable. (Passwordless
    # sudo for the operator account on the single-purpose container host is a
    # documented prerequisite — see REVIEWER-ENVIRONMENT.md.)
    die "cannot program iptables (passwordless sudo required on the container host) — refusing to launch without egress lockdown"
  fi
  # Idempotent egress pinning (chain per network; recreate from scratch).
  $SUDO iptables -N "RV_$NET_NAME" 2>/dev/null || true
  $SUDO iptables -F "RV_$NET_NAME" 2>/dev/null || true
  $SUDO iptables -C DOCKER-USER -s "$SUBNET" -j "RV_$NET_NAME" 2>/dev/null \
    || $SUDO iptables -I DOCKER-USER -s "$SUBNET" -j "RV_$NET_NAME"
  $SUDO iptables -A "RV_$NET_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # DNS: docker's OWN resolver address only (see RESOLVER_ADDR above). An
  # earlier revision allowed udp/53 to ANY destination before the
  # private-range DROPs, which an independent QA challenge (2026-09-10)
  # falsified live — the container reached the LAN router's resolver and
  # 1.1.1.1 over UDP/53 (a DNS-tunnel exfil channel). Blanket DNS is gone;
  # every port-53 destination other than docker's resolver stays dropped.
  $SUDO iptables -A "RV_$NET_NAME" -p udp -d "$RESOLVER_ADDR"/32 --dport 53 -j RETURN
  $SUDO iptables -A "RV_$NET_NAME" -p tcp -d "$RESOLVER_ADDR"/32 --dport 53 -j RETURN
  $SUDO iptables -A "RV_$NET_NAME" -p tcp -d 10.0.0.0/8 -j DROP
  $SUDO iptables -A "RV_$NET_NAME" -p tcp -d 172.16.0.0/12 -j DROP
  $SUDO iptables -A "RV_$NET_NAME" -p tcp -d 192.168.0.0/16 -j DROP
  $SUDO iptables -A "RV_$NET_NAME" -p tcp -d 169.254.0.0/16 -j DROP
  $SUDO iptables -A "RV_$NET_NAME" -p tcp -d 127.0.0.0/8 -j DROP
  $SUDO iptables -A "RV_$NET_NAME" -p tcp --dport 443 -j RETURN          # provider APIs over HTTPS
  $SUDO iptables -A "RV_$NET_NAME" -j DROP                               # everything else: DROP (fail closed)
  # Container→HOST traffic lands in INPUT, not FORWARD — DOCKER-USER never
  # sees it. Block NEW connections from the reviewer subnet to host services
  # (SSH, DNS, any local listener): the reviewer demo has no legitimate
  # host-service need. ESTABLISHED,RELATED must be accepted BEFORE the drop
  # jump — the published :9318 port's reply path (host curl / cloudflared →
  # DNAT → container → reply) enters INPUT sourced from this subnet.
  $SUDO iptables -C INPUT -s "$SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || $SUDO iptables -I INPUT 1 -s "$SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # (re-run safe) drop jump: remove any prior, then insert directly under the
  # established-accept so replies to the published port always pass first
  $SUDO iptables -D INPUT -s "$SUBNET" -j "RV_HOST_$NET_NAME" 2>/dev/null || true
  $SUDO iptables -N "RV_HOST_$NET_NAME" 2>/dev/null || true
  $SUDO iptables -F "RV_HOST_$NET_NAME" 2>/dev/null || true
  # The container's DNS query to docker's resolver arrives on the host INPUT
  # path: accept port 53 to that ONE docker-owned address (again, never a LAN
  # router, public resolver, or tailnet address), then drop everything else.
  $SUDO iptables -A "RV_HOST_$NET_NAME" -p udp -d "$RESOLVER_ADDR"/32 --dport 53 -j ACCEPT
  $SUDO iptables -A "RV_HOST_$NET_NAME" -p tcp -d "$RESOLVER_ADDR"/32 --dport 53 -j ACCEPT
  $SUDO iptables -A "RV_HOST_$NET_NAME" -j DROP      # fail closed: nothing else on the host reachable
  $SUDO iptables -I INPUT 2 -s "$SUBNET" -j "RV_HOST_$NET_NAME"
  info "egress pinned on $SUBNET: established + public tcp/443 + DNS to docker's resolver ($RESOLVER_ADDR) only; host INPUT from subnet otherwise blocked"
}

teardown_network() {
  local subnet
  subnet="$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    if [ -n "$subnet" ]; then
      sudo iptables -D DOCKER-USER -s "$subnet" -j "RV_$NET_NAME" 2>/dev/null || true
      sudo iptables -D INPUT -s "$subnet" -j "RV_HOST_$NET_NAME" 2>/dev/null || true
      sudo iptables -D INPUT -s "$subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    fi
    sudo iptables -F "RV_$NET_NAME" 2>/dev/null || true
    sudo iptables -X "RV_$NET_NAME" 2>/dev/null || true
    sudo iptables -F "RV_HOST_$NET_NAME" 2>/dev/null || true
    sudo iptables -X "RV_HOST_$NET_NAME" 2>/dev/null || true
  fi
  docker network rm "$NET_NAME" >/dev/null 2>&1 || true
}

# -------------------------------------------------------------- home seeding
# Runs INSIDE a throwaway container on the named volume (never on the host).
seed_home() {
  local assets_dir="$SCRIPT_DIR/reviewer_env_assets"
  docker run --rm \
    -v "$VOL_NAME:/opt/data" \
    -v "$assets_dir:/assets:ro" \
    -e HERMES_HOME=/opt/data/home -e HOME=/opt/data \
    --network none \
    --cap-drop ALL --security-opt no-new-privileges \
    --user 10000:10000 \
    --entrypoint /bin/bash "$REVIEWER_IMAGE" -c '
      set -eu
      mkdir -p /opt/data/home
      for bot in oracle scribe; do
        HERMES_HOME=/opt/data/home hermes profile create "reviewer-demo-$bot" \
          --description "Synthetic demo bot on the disposable reviewer gateway." >/dev/null 2>&1 || true
        mkdir -p "/opt/data/home/profiles/reviewer-demo-$bot"
        if [ -f "/assets/reviewer-demo-$bot.SOUL.md" ]; then
          cp "/assets/reviewer-demo-$bot.SOUL.md" "/opt/data/home/profiles/reviewer-demo-$bot/SOUL.md"
        else
          printf "You are reviewer-demo-%s, a synthetic demo bot on a disposable Hermes review gateway. Be brief and friendly. Never claim to have personal data or production access.\n" "$bot" \
            > "/opt/data/home/profiles/reviewer-demo-$bot/SOUL.md"
        fi
      done
      if [ -f /assets/reviewer-demo/SKILL.md ]; then
        mkdir -p /opt/data/home/skills/reviewer-demo
        cp /assets/reviewer-demo/SKILL.md /opt/data/home/skills/reviewer-demo/SKILL.md
      fi
      echo seeded
    ' >/dev/null || die "home seeding failed"
  info "seeded synthetic demo home (profiles oracle+scribe, demo skill) in volume $VOL_NAME"
}

# --------------------------------------------------------------------- start
do_start() {
  require_docker
  [ -n "${REVIEWER_PUBLIC_URL:-}" ] || die "REVIEWER_PUBLIC_URL is required (the tunnel URL, or a rehearsal http://<non-loopback-host>:$SERVE_PORT)"
  case "$REVIEWER_PUBLIC_URL" in
    http://127.0.0.1*|http://localhost*) die "v2 runs the real architecture (container + auth gate) — use a NON-loopback rehearsal hostname with REVIEWER_CONNECT_TO, or the real tunnel URL" ;;
  esac

  # provider env FIRST: a rejected file must have NO side effects at all — no
  # network, no iptables rules, no volume, no seeded home, no credentials
  # (independent QA finding, 2026-09-10: validation used to run after seeding).
  local run_env_args=()
  if [ -n "${REVIEWER_PROVIDER_ENV_FILE:-}" ]; then
    local keys k v
    keys="$(reviewer_provider_env_validate "$REVIEWER_PROVIDER_ENV_FILE")" \
      || die "REVIEWER_PROVIDER_ENV_FILE rejected by the provider allowlist (see errors above) — refusing to launch (nothing was created)"
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      v="$(sed -n "s/^$k=//p" "$REVIEWER_PROVIDER_ENV_FILE")"
      run_env_args+=(-e "$k=$v")
    done <<< "$keys"
    info "forwarding $(printf '%s\n' "$keys" | grep -c .) allowlisted provider variable(s): $(printf '%s ' $keys)"
  else
    info "no REVIEWER_PROVIDER_ENV_FILE — chat replies lack a model key until one is supplied"
  fi

  # Only now — after the allowlist gate has accepted the provider file — do we
  # create anything.
  resolve_credentials
  setup_network

  # ALWAYS fresh state: destroy any prior volume so nothing is inherited.
  docker rm -f "$CONT_NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL_NAME" >/dev/null 2>&1 || true
  docker volume create "$VOL_NAME" >/dev/null || die "cannot create volume"
  seed_home

  # scrypt-hash the password INSIDE a throwaway container; write config.yaml
  # into the volume. Secrets never appear on this script's command line
  # outside docker run internals, never in the repo, never in logs.
  docker run --rm -v "$VOL_NAME:/opt/data" --network none \
    --user 10000:10000 \
    -e HERMES_HOME=/opt/data/home \
    -e "REVIEWER_USERNAME=$REVIEWER_USERNAME" \
    -e "REVIEWER_PASSWORD=$REVIEWER_PASSWORD" \
    -e "REVIEWER_SECRET=$REVIEWER_SECRET" \
    --entrypoint /bin/bash "$REVIEWER_IMAGE" -c '
      set -eu
      python3 - <<PYEOF
from plugins.dashboard_auth.basic import hash_password
import yaml, os
home = "/opt/data/home"
cfg_path = os.path.join(home, "config.yaml")
cfg = {}
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        cfg = yaml.safe_load(f) or {}   # MERGE — never clobber other state
cfg.setdefault("dashboard", {})["basic_auth"] = {
    "username": os.environ["REVIEWER_USERNAME"],
    "password_hash": hash_password(os.environ["REVIEWER_PASSWORD"]),
    "secret": os.environ["REVIEWER_SECRET"],
}
os.makedirs(home, exist_ok=True)
with open(cfg_path, "w") as f:
    f.write(yaml.safe_dump(cfg))
os.chmod(cfg_path, 0o600)
PYEOF
    ' \
    >/dev/null || die "auth config provisioning failed"
  info "auth gate configured (scrypt password hash in container config.yaml; plaintext never stored at rest)"

  # Build the argv as an array: a conditional `"${arr[@]+"${arr[@]}"}"` splice
  # injects literal quote characters into argv under bash 5 (docker then sees a
  # bogus image reference), so the optional provider args are appended instead.
  local run_cmd=(docker run -d --name "$CONT_NAME"
    --network "$NET_NAME"
    --cap-drop ALL
    --security-opt no-new-privileges
    --user 10000:10000
    --read-only
    --tmpfs /tmp:rw,size=64m,mode=1777
    --memory 2g --pids-limit 256
    --health-cmd "curl -fsS -m 5 http://127.0.0.1:9318/api/health || exit 1"
    --health-interval 30s --health-timeout 10s --health-retries 3
    -p "127.0.0.1:$SERVE_PORT:9318"
    -v "$VOL_NAME:/opt/data"
    -e HERMES_HOME=/opt/data/home -e HOME=/opt/data
    -e HERMES_DASHBOARD_PUBLIC_URL="$REVIEWER_PUBLIC_URL"
    -e PYTHONUNBUFFERED=1)
  if [ "${#run_env_args[@]}" -gt 0 ]; then run_cmd+=("${run_env_args[@]}"); fi
  run_cmd+=(--entrypoint /bin/bash "$REVIEWER_IMAGE"
    -c "exec hermes serve --host 0.0.0.0 --port 9318")
  "${run_cmd[@]}" >/dev/null || die "container start failed"

  local ok=""
  for _ in $(seq 1 40); do
    sleep 1
    if curl -fsS -m 3 "http://127.0.0.1:$SERVE_PORT/api/health" >/dev/null 2>&1; then ok=1; break; fi
    docker ps --filter "name=$CONT_NAME" --filter "status=running" -q | grep -q . || break
  done
  if [ -z "$ok" ]; then
    info "container failed — last logs:"; docker logs "$CONT_NAME" 2>&1 | tail -15 >&2
    docker rm -f "$CONT_NAME" >/dev/null 2>&1
    die "reviewer gateway did not come up"
  fi
  info "container $CONT_NAME up: auth-gated serve published to host loopback :$SERVE_PORT only"
  info "container hardening: cap-drop ALL, no-new-privileges, uid 10000, read-only rootfs, 2g/256pids, egress DNS+443-only"
  printf '\nTUNNEL (operator executes — this script never does):\n'
  printf '  quick rehearsal:  cloudflared tunnel --url http://127.0.0.1:%s\n' "$SERVE_PORT"
  printf '  review window:    cloudflared tunnel login && cloudflared tunnel create fleet-reviewer && \\\n'
  printf '                    cloudflared tunnel route dns fleet-reviewer <your-reviewer-host> && \\\n'
  printf '                    cloudflared tunnel run --url http://127.0.0.1:%s fleet-reviewer\n' "$SERVE_PORT"
  printf '  then verify from an OFF-network vantage:\n'
  printf '    REVIEWER_BASE_URL=https://<host> REVIEWER_CRED_FILE=%s bash scripts/reviewer_env_check.sh\n' "$CREDS_FILE"
  printf '  and prove containment:  bash scripts/reviewer_containment_test.sh\n'
}

# -------------------------------------------------------------------- status
do_status() {
  printf 'reviewer env dir : %s\n' "$REVIEWER_ENV_DIR"
  if docker ps --filter "name=$CONT_NAME" --filter "status=running" -q | grep -q .; then
    printf 'container        : RUNNING (%s)\n' "$(docker inspect -f '{{.State.Health.Status}}' "$CONT_NAME" 2>/dev/null || echo '?')"
  else
    printf 'container        : not running\n'
  fi
  if curl -fsS -m 3 "http://127.0.0.1:$SERVE_PORT/api/health" >/dev/null 2>&1; then
    printf 'loopback :%s : HEALTHY\n' "$SERVE_PORT"
  else
    printf 'loopback :%s : down\n' "$SERVE_PORT"
  fi
  docker volume inspect "$VOL_NAME" >/dev/null 2>&1 && printf 'demo volume      : present\n' || printf 'demo volume      : absent\n'
}

# --------------------------------------------------------------------- stop
do_stop() {
  docker rm -f "$CONT_NAME" >/dev/null 2>&1 && info "removed container $CONT_NAME" || info "no container to remove"
}

# -------------------------------------------------------------------- clean
do_clean() {
  do_stop
  if [ "${1:-}" = "--purge" ]; then
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    case "$REVIEWER_ENV_DIR/" in "$repo_root"/*) die "REFUSING to purge inside the repository" ;; esac
    [ "$REVIEWER_ENV_DIR" = "/" ] && die "REFUSING to purge /"
    docker volume rm "$VOL_NAME" >/dev/null 2>&1 && info "destroyed demo volume $VOL_NAME (home, sessions, config)" \
      || info "no volume to destroy"
    teardown_network
    rm -rf "$REVIEWER_ENV_DIR" && info "removed $REVIEWER_ENV_DIR (credentials, logs)"
    info "teardown complete — disposable environment destroyed"
  else
    info "state kept (volume $VOL_NAME, credentials). To destroy: $0 clean --purge"
  fi
}

cmd="${1:-}"
case "$cmd" in
  start) do_start ;;
  status) do_status ;;
  stop) do_stop ;;
  clean) shift; do_clean "$@" ;;
  *) die "usage: $0 start|status|stop|clean [--purge]" ;;
esac
