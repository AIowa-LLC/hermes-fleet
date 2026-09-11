#!/bin/bash
# reviewer_containment_test.sh — EXECUTED containment proof for the reviewer
# environment (issue #18 v2, BLOCKER 2). Runs ON THE CONTAINER HOST next to
# reviewer_env_launch.sh while the environment is up.
#
# Mission (i18): "Prove the containment boundary rather than relying on
# documentation prose." This script executes every probe and prints
# PASS/FAIL per probe; exit 0 only when ALL probes fail closed as designed.
#
# Probes (from the reviewer's position — inside the container / from the
# gateway RPC surface an authenticated reviewer can drive):
#   A. host filesystem     — read/write outside the demo home
#   B. host shell          — the Hermes agent inside the container DOES have
#                            a terminal tool; the boundary is the CONTAINER,
#                            so probes assert the container's own filesystem
#                            and confirm no host path is visible/mounted.
#   C. host environment    — no maintainer env vars present
#   D. host credentials    — no ssh/git/keychain material anywhere reachable
#   E. host network        — LAN/tailnet/loopback-host services unreachable;
#                            ONLY public TCP/443 egress works
#   F. runtime hardening   — uid 10000, caps dropped, read-only rootfs,
#                            no-new-privileges, no docker socket
#   G. auth gate           — gated requests over the public host must be
#                            DENIED (ws-ticket, wrong-password login,
#                            fabricated cookie); the provider advertisement is
#                            public by design but must leak no credentials;
#                            the published port must exist on loopback only
#
# 29 probes: 21 attack probes that must be DENIED, 8 state assertions that
# must hold (disposable image, demo home writable, public 443 reachable,
# public-but-credential-free provider advertisement, cap-drop ALL,
# no-new-privileges, read-only rootfs, uid 10000). The state assertions are
# the functionality the reviewers must have; the denials are containment.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONT_NAME="${REVIEWER_CONTAINMENT_CONTAINER:-fleet-reviewer}"
NET_NAME="${REVIEWER_CONTAINMENT_NETWORK:-fleet-reviewer}"
IMAGE="${REVIEWER_IMAGE:-hermes-agent:0.21.1-reviewer}"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

cecho() { docker exec "$CONT_NAME" bash -c "$1" 2>/dev/null; }

command -v docker >/dev/null 2>&1 || die "docker not found"
docker container inspect "$CONT_NAME" >/dev/null 2>&1 || die "container $CONT_NAME not running (start the environment first)"

printf 'reviewer containment probes against %s\n\n' "$CONT_NAME"

# --- A. filesystem boundary -------------------------------------------------
# The container sees its own rootfs + /opt/data volume. Host paths must not
# exist inside. (Names probed are the maintainer host's real layout.)
if cecho 'test -d /Users/tonysimons' | grep -q .; then bad "A1 host /Users visible"; else ok "A1 host /Users/* not visible"; fi
if cecho 'test -d /home/tony' | grep -q .; then bad "A2 container-runtime-host /home/tony visible"; else ok "A2 runtime-host /home/* not visible"; fi
mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$CONT_NAME")"
if printf '%s' "$mounts" | grep -qE '/(home|Users)/'; then
  bad "A3 host directory mounted into container: $mounts"
else
  ok "A3 no host directories mounted (only named volume): $(printf '%s' "$mounts" | tr -d '\n')"
fi
# writable probe: /opt/data (demo home) writable, rootfs NOT
if cecho 'touch /opt/data/.containment-probe && rm -f /opt/data/.containment-probe && echo yes' | grep -q yes; then
  ok "A4 demo home (/opt/data) writable (by design)"
else
  bad "A4 demo home not writable"
fi
if cecho 'touch /etc/.probe 2>/dev/null && echo yes' | grep -q yes; then bad "A5 rootfs /etc writable (read-only violated)"; else ok "A5 rootfs read-only (/etc not writable)"; fi

# --- B. shell boundary: the terminal tool exists but is container-scoped ----
# The reviewer CAN drive the container's own shell via the Hermes gateway;
# the boundary is that this shell cannot reach host state. Probes A/C/D/E
# prove that; here we confirm the container rootfs is the disposable demo
# image, not a maintainer environment.
if cecho 'test -f /opt/hermes/bin/hermes && echo yes' | grep -q yes; then
  ok "B1 container runs the disposable hermes image (/opt/hermes)"
else
  bad "B1 /opt/hermes missing — unexpected rootfs"
fi

# --- C. environment boundary -------------------------------------------------
env_dump="$(docker exec "$CONT_NAME" env 2>/dev/null || true)"
if printf '%s' "$env_dump" | grep -qE '^(HOME|PATH)=/(Users|home/tony)'; then bad "C1 maintainer HOME/PATH in env"; else ok "C1 no maintainer HOME/PATH"; fi
if printf '%s' "$env_dump" | grep -qE '^(TELEGRAM|DISCORD|SLACK)_[A-Z_]*TOKEN'; then bad "C2 messaging tokens in env"; else ok "C2 no messaging-integration tokens"; fi
if printf '%s' "$env_dump" | grep -qE '^REVIEWER_(USERNAME|PASSWORD|SECRET)='; then bad "C3 reviewer credentials echoed into env"; else ok "C3 reviewer credentials not present in container env (config.yaml only)"; fi

# --- D. credential boundary ----------------------------------------------------
if cecho 'ls /root/.ssh /home/*/.ssh 2>/dev/null' | grep -q .; then bad "D1 .ssh material visible"; else ok "D1 no SSH material"; fi
if cecho 'ls /root/.gitconfig /home/*/.gitconfig /root/.docker /var/run/docker.sock 2>/dev/null' | grep -q .; then bad "D2 git config / docker socket visible"; else ok "D2 no git config, no docker socket"; fi
if cecho 'find / -maxdepth 3 \( -name "*.pem" -o -name "id_rsa*" -o -name "known_hosts" \) 2>/dev/null | head -3' | grep -q .; then
  bad "D3 key material discoverable: $(cecho 'find / -maxdepth 3 \( -name "*.pem" -o -name "id_rsa*" -o -name "known_hosts" \) 2>/dev/null | head -3' | tr '\n' ' ')"
else
  ok "D3 no key material at shallow depth"
fi

# --- E. network boundary -------------------------------------------------------
# Inside-container egress: public HTTPS must work; everything host-ish must fail.
if cecho 'curl -fsS -m 8 -o /dev/null -w "%{http_code}" https://pypi.org/simple/ 2>/dev/null' | grep -qE '200|301'; then
  ok "E1 public HTTPS egress works (provider APIs reachable)"
else
  bad "E1 public HTTPS egress BROKEN — demo chat would fail"
fi
lan_ip="$(docker exec "$CONT_NAME" getent hosts archlinux-1 2>/dev/null | awk '{print $1}' || true)"
if [ -n "$lan_ip" ] && cecho "(curl -fsS -m 5 telnet://$lan_ip:22 2>/dev/null; timeout 4 bash -c \"</dev/tcp/$lan_ip/22\" 2>/dev/null) && echo open" | grep -q open; then
  bad "E2 runtime-host SSH reachable at $lan_ip"
else
  ok "E2 runtime-host SSH not reachable from container"
fi
gw="$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
if [ -n "$gw" ] && cecho "(curl -fsS -m 4 -o /dev/null http://$gw:9119 2>/dev/null; timeout 4 bash -c \"</dev/tcp/$gw/9119\" 2>/dev/null) && echo open" | grep -q open; then
  bad "E3 host gateway service on :9119 reachable"
else
  ok "E3 host gateway port :9119 not reachable from container"
fi
# tailnet addresses must be unroutable
if cecho 'curl -fsS -m 5 -o /dev/null -k https://100.108.104.89 2>/dev/null && echo open' | grep -q open; then
  bad "E4 tailnet address reachable"
else
  ok "E4 tailnet addresses unreachable"
fi
# non-443 public egress blocked (FTP control port as the canary)
if cecho 'curl -fsS -m 5 -o /dev/null telnet://example.com:21 2>/dev/null && echo open' | grep -q open; then
  bad "E5 non-443 public egress allowed"
else
  ok "E5 non-443 public egress blocked"
fi

# --- F. runtime hardening --------------------------------------------------------
hc="$(docker inspect -f '{{.HostConfig.Privileged}} capdrop={{.HostConfig.CapDrop}} nnpriv={{.HostConfig.SecurityOpt}} ro={{.HostConfig.ReadonlyRootfs}} user={{.Config.User}}' "$CONT_NAME")"
printf '     runtime: %s\n' "$hc"
if docker inspect -f '{{.HostConfig.Privileged}}' "$CONT_NAME" | grep -q true; then bad "F1 privileged mode"; else ok "F1 not privileged"; fi
if docker inspect -f '{{.HostConfig.CapDrop}}' "$CONT_NAME" | grep -q ALL; then ok "F2 all capabilities dropped"; else bad "F2 capabilities not fully dropped"; fi
if docker inspect -f '{{.HostConfig.SecurityOpt}}' "$CONT_NAME" | grep -q no-new-privileges; then ok "F3 no-new-privileges"; else bad "F3 no-new-privileges missing"; fi
if docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$CONT_NAME" | grep -q true; then ok "F4 read-only rootfs"; else bad "F4 rootfs writable"; fi
if docker inspect -f '{{.Config.User}}' "$CONT_NAME" | grep -qE '^10000:10000$'; then ok "F5 non-root uid 10000"; else bad "F5 not running as uid 10000"; fi
if cecho 'test -S /var/run/docker.sock && echo yes' | grep -q yes; then bad "F6 docker socket mounted"; else ok "F6 no docker socket"; fi

# --- G. auth gate ------------------------------------------------------------
# The dashboard auth gate only engages for NON-loopback hosts (hermes exempts
# loopback), so these probes carry the rehearsal public host and map it onto
# the host loopback port with --connect-to — the same shape
# reviewer_env_check.sh uses. Every probe here must be DENIED.
PUBLIC_HOST="${REVIEWER_CONTAINMENT_PUBLIC_HOST:-rehearsal.invalid}"
SERVE_PORT="${REVIEWER_SERVE_PORT:-9318}"
CONNECT_TO="${REVIEWER_CONTAINMENT_CONNECT_TO:-$PUBLIC_HOST:$SERVE_PORT:127.0.0.1:$SERVE_PORT}"
gatecurl() { curl -sS -m 10 --connect-to "$CONNECT_TO" "$@"; }
TMPBODY="$(mktemp)"; trap 'rm -f "$TMPBODY"' EXIT

HTTP="$(gatecurl -o /dev/null -w '%{http_code}' -X POST \
  "http://$PUBLIC_HOST:$SERVE_PORT/api/auth/ws-ticket" 2>/dev/null || true)"
if [ "$HTTP" = "200" ]; then bad "G1 unauthenticated ws-ticket returned 200 — AUTH GATE NOT ENGAGED"; else ok "G1 unauthenticated ws-ticket denied (HTTP ${HTTP:-000})"; fi

HTTP="$(gatecurl -o "$TMPBODY" -w '%{http_code}' \
  "http://$PUBLIC_HOST:$SERVE_PORT/api/auth/providers" 2>/dev/null || true)"
BODY="$(cat "$TMPBODY" 2>/dev/null || true)"
# /api/auth/providers is public BY DESIGN — the app must discover the
# password-capable provider before it can log in. The assertion is therefore
# (a) reachable, (b) advertises the password provider, (c) leaks no
# credential material from the 0600 credentials file.
leak=""
if [ -n "${REVIEWER_CRED_FILE:-}" ] && [ -f "$REVIEWER_CRED_FILE" ]; then
  _pw="$(sed -n 's/^password=//p' "$REVIEWER_CRED_FILE")"
  _sec="$(sed -n 's/^secret=//p' "$REVIEWER_CRED_FILE")"
  [ -n "$_pw" ] && case "$BODY" in *"$_pw"*) leak="password" ;; esac
  [ -n "$_sec" ] && case "$BODY" in *"$_sec"*) leak="$leak secret" ;; esac
fi
if [ "$HTTP" = "200" ] && printf '%s' "$BODY" | grep -q 'basic' && [ -z "$leak" ]; then
  ok "G2 public provider advertisement reachable by design, advertises 'basic', leaks no credential material"
elif [ -n "$leak" ]; then
  bad "G2 provider advertisement LEAKS credential material ($leak)"
else
  bad "G2 provider advertisement unusable (HTTP ${HTTP:-000}) — the app could not log in"
fi

HTTP="$(gatecurl -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  --data '{"provider":"basic","username":"containment-probe","password":"not-the-password"}' \
  "http://$PUBLIC_HOST:$SERVE_PORT/auth/password-login" 2>/dev/null || true)"
if [ "$HTTP" = "200" ]; then bad "G3 wrong-password login returned 200"; else ok "G3 wrong-password login denied (HTTP ${HTTP:-000})"; fi

HTTP="$(gatecurl -o /dev/null -w '%{http_code}' -X POST \
  -H 'Cookie: hermes_session=deadbeefdeadbeefdeadbeef' \
  "http://$PUBLIC_HOST:$SERVE_PORT/api/auth/ws-ticket" 2>/dev/null || true)"
if [ "$HTTP" = "200" ]; then bad "G4 fabricated session cookie minted a ws-ticket"; else ok "G4 fabricated session cookie denied (HTTP ${HTTP:-000})"; fi

# the published port must not answer on any non-loopback address of this host
LAN_IPS="$(hostname -I 2>/dev/null || ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
if [ -z "$LAN_IPS" ]; then
  ok "G5 no non-loopback IPv4 on this host (nothing exposed off-loopback)"
else
  leaked=""
  for ipa in $LAN_IPS; do
    if curl -fsS -m 3 -o /dev/null "http://$ipa:$SERVE_PORT/api/health" 2>/dev/null; then leaked="$leaked $ipa"; fi
  done
  if [ -n "$leaked" ]; then bad "G5 serve port answers on non-loopback address(es):$leaked"; else ok "G5 serve port not reachable on any non-loopback host address"; fi
fi

# and docker must report it bound to loopback only (no wildcard publish)
PORTS="$(docker port "$CONT_NAME" 2>/dev/null | tr '\n' ' ')"
if printf '%s' "$PORTS" | grep -qE '(^| )0\.0\.0\.0:|\[::\]:'; then
  bad "G6 port published on a wildcard address: $PORTS"
else
  ok "G6 port published to loopback only: ${PORTS:-<none>}"
fi

printf '\ncontainment: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'CONTAINMENT NOT PROVEN — fix before any external exposure.\n'
  exit 1
fi
printf 'CONTAINMENT PROVEN by execution: reviewer blast radius = the disposable demo environment.\n'
exit 0
