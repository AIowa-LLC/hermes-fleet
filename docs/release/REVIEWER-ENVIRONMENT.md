# Reviewer Hermes environment — v2 container architecture

This document specifies the disposable, **container-isolated** Hermes gateway
environment that Hermes Fleet's external TestFlight reviewers connect to
(issue #18), and the checked-in automation that provisions it. It pairs with
the reviewer-facing walkthrough in
[`REVIEWER-PACKAGE.md`](REVIEWER-PACKAGE.md) and the App Store Connect draft
in [`BETA-METADATA.md`](BETA-METADATA.md).

**v2 supersedes the v1 design** (a disposable `HERMES_HOME` on the
maintainer's Mac). v1 was rejected in security review for a correct reason:
a synthetic Hermes home is not a security boundary. A serve process running
as the maintainer's OS user retains all host permissions outside that
directory — home filesystem, SSH material, git credentials, Keychain,
browser profiles, messaging integrations. Prompts and a "safe SOUL.md" are
demo content, not containment. v2 puts the reviewer gateway inside a
hardened disposable container on a **dedicated container host**, where the
intended blast radius is the container and its disposable volume — and
proves it with executable probes (see `scripts/reviewer_containment_test.sh`).

Nothing in this file or the scripts commits an endpoint, credential, QR
payload, or secret. Every secret is resolved at runtime into 0600 storage
outside any repository.

## Architecture (v2)

```
iPhone (reviewer)            public internet
    │  Hermes Fleet               │ TLS (terminated at Cloudflare edge)
    │  Add Gateway → URL+user/pass ▼
    │                    ┌────────────────────────┐
    └───────────────────►│ cloudflared named tunnel│  (operator-run, on the
                         │ https://<reviewer host> │   container host)
                         └───────────┬────────────┘
                                     │ loopback HTTP only (127.0.0.1:<port>)
                                     ▼
                ┌──────────────────────────────────────────────┐
                │ Docker container — hermes-agent image         │
                │  --cap-drop ALL  --security-opt               │
                │    no-new-privileges  --user 10000:10000      │
                │  --read-only rootfs  --tmpfs /tmp             │
                │  --memory 2g --pids-limit 256                 │
                │  network: dedicated bridge (IPv4-only)        │
                │    egress = public tcp/443 ONLY               │
                │    (model provider APIs + the upstream DNS    │
                │     the host's own resolver already serves);  │
                │    everything else DROP — host, LAN,          │
                │    tailnet, docker nets, and any port-53      │
                │    destination other than docker's embedded   │
                │    resolver (127.0.0.11)                      │
                │  HERMES_HOME = named volume (disposable)      │
                │  hermes serve --host 0.0.0.0 (in-container)   │
                │  auth gate: basic-auth provider (scrypt hash  │
                │    in config.yaml; plugin ENABLED in home)    │
                └──────────────────────────────────────────────┘
```

Layered boundary, outermost first:

1. **Transport**: TLS terminates at the Cloudflare edge; the container host
   publishes the serve port to **host loopback only** — nothing listens on
   the host's LAN/tailnet interfaces.
2. **Authentication**: the Hermes dashboard auth gate is engaged
   (non-loopback `HERMES_DASHBOARD_PUBLIC_URL`); unauthenticated
   `/api/auth/ws-ticket` is refused (verified by probe H of the
   containment suite).
3. **Runtime containment** (the boundary v1 lacked): the serve process runs
   inside the container above — non-root UID 10000, all Linux capabilities
   dropped, no-new-privileges, read-only rootfs, no host mounts of any
   kind, no docker socket, no host-management tools in the image.
4. **Network containment**: a dedicated IPv4-only docker bridge whose egress
   is pinned (iptables, DOCKER-USER for forwarded traffic + INPUT rules for
   container→host traffic) to established traffic and public TCP/443 only.
   The only port-53 destination allowed is **docker's own resolver address**
   (the default-bridge gateway docker points containers at when the host
   resolver is a loopback stub — `RESOLVER_ADDR` in the launcher); a LAN
   router, a public resolver, or a tailnet address is dropped. The
   reviewer subnet cannot reach the host's SSH, other host services, LAN,
   tailnet, or other docker networks. The launcher refuses to run if the
   network has IPv6 enabled (the pinning is IPv4-only). Proven by probes
   E1–E9 and the auth-gate group G.
5. **Disposable state**: the demo home is a named volume created empty at
   every `start` (prior volumes are destroyed first — no inherited state)
   and destroyed by `clean --purge` together with credentials.

### Why the container host is not the maintainer Mac

The container host must not hold the maintainer's personal session. The
fleet's dedicated Linux container host runs the reviewer container; the
maintainer Mac never runs reviewer-facing processes. Even full container
escape yields: the disposable volume, the container's own network (443-only
egress), and nothing else — no mountable path leads to maintainer data.

## What is remotely reachable (honest scope)

The Hermes gateway API is not per-route scoped: a client holding valid
reviewer credentials can reach the full JSON-RPC/WebSocket surface the
dashboard serves. There is no partial-API credentials mode. v2 accepts this
and isolates at the runtime layer instead:

- the *process* reachable by the reviewer is confined to the hardened
  container; its tools act on the disposable volume, not on any host;
- the container's own network egress is public TCP/443 plus DNS to docker's
  own resolver only, so even a malicious tool call cannot reach maintainer
  LAN/tailnet services;
- the model key is the only credential in the environment, a scoped
  low-limit demo key forwarded through a strict allowlist (below);
- credentials are generated per provisioning run and destroyed at teardown.

### Residual risk, stated plainly (independent-challenge findings)

An independent `apple-qa` challenge (2026-09-10) attacked this model on the
head that preceded this revision; its findings are fixed and re-verified, and
what remains is listed here rather than glossed:

- **Outbound TCP/443 is open to the entire internet**, not to a provider
  allowlist. A compromised agent process can therefore exfiltrate over HTTPS
  to any host. This is accepted by design (provider base URLs are
  operator-chosen), and is the reason the only credential in the container is
  a scoped, low-limit demo key. The earlier, wider hole — UDP/53 to arbitrary
  LAN/internet destinations (a DNS-tunnel channel) — is closed: **the only
  port-53 destination allowed is docker's own resolver address**
  (`RESOLVER_ADDR`, the default-bridge gateway), in both chains; a LAN router,
  a public resolver, or a tailnet address is dropped.
- **The egress pinning is IPv4-only.** The reviewer network is created
  IPv4-only and the launcher refuses to start if IPv6 is enabled on it (and
  that refusal now happens before credentials or volumes are created), so the
  pinning cannot silently stop applying.
- **Host service exposure is reduced to docker's resolver**: the
  container→host chain accepts only port 53 to that same docker-owned address
  and drops everything else — no SSH, no other host listener, no LAN/tailnet
  address. Verified live.
- **The reviewer credential file persists between `start`/`clean` runs by
  design** (`reusing generated credentials`); rotation is manual — delete the
  file (or `clean --purge`) to rotate.
- **A refused launch leaves nothing behind**: the provider-env allowlist is
  evaluated before anything is created, and the IPv6 check runs before
  credentials are generated, so a refusal leaves no network rules, volume,
  seeded home, or credential file.

This scope statement is deliberate and must not be softened in review notes.

## Provider env allowlist (BLOCKER 1 remediation)

`REVIEWER_PROVIDER_ENV_FILE` (0600, outside the repo) is the operator's
`.env` for the demo model key. The launcher does **not** forward it
verbatim: `scripts/reviewer_provider_env_lib.sh` defines the single
allowlist of model-provider credential variables and **fails closed** on
everything else.

The allowlist is **derived, not hand-picked**: it is the union of every
api-key env var and base-URL env var in `hermes_cli.auth.PROVIDER_REGISTRY`
and every `hermes_cli.config.OPTIONAL_ENV_VARS` entry with category
`provider` at the pinned image version (hermes 0.21.1: 79 providers → 100
variables), minus seven documented exclusions (93 entries). The seven are
`GH_TOKEN`, `GITHUB_TOKEN` (Copilot provider keys, but also the operator's
full VCS credential — Hermes's own child-env blocklist strips them too),
`CLAUDE_CODE_OAUTH_TOKEN` (belongs to the operator's Claude Code install),
`AWS_PROFILE`/`AWS_REGION` (cloud credential-chain selection, not a chat key),
`VERTEX_CREDENTIALS_PATH` (a host-side path to a service-account JSON), and
`HERMES_QWEN_BASE_URL` (the launcher owns the whole `HERMES_*` namespace, so
that class wins). Each excluded name is also rejected explicitly, so editing
the allowlist cannot silently re-admit it.

Rejected categories include:

- any `HERMES_*` variable — the launcher owns the Hermes security
  configuration (`HERMES_HOME`, `HERMES_DASHBOARD_PUBLIC_URL`,
  `HERMES_DASHBOARD_BASIC_AUTH_*`, …); a reused .env must never override it;
- `HOME`, `PATH`, identity/locale/shell-runtime manipulation
  (`ENV`, `BASH_ENV`, `LD_*`, `DYLD_*`, `PYTHON*`, `NODE_*`, …);
- reviewer/auth/tunnel control (`REVIEWER_*`, `CLOUDFLARED_*`, `TUNNEL_*`,
  `CF_*`);
- host control / host credential material (`GITHUB_TOKEN`, `GH_TOKEN`,
  `AWS_*`, `SSH_AUTH_SOCK`, `DOCKER_HOST`, `KUBECONFIG`, `HEROKU_API_KEY`);
- unknown keys — including near-misses of real names (`OPENAI_API_KE`),
  vendor keys Hermes 0.21.1 does not read (`GROQ_API_KEY`,
  `MISTRAL_API_KEY`, `TOGETHER_API_KEY`, `PERPLEXITY_API_KEY`),
- duplicate keys (the launcher re-extracts values with `sed` over the whole
  file, so a repeated key would splice an embedded newline into one `-e`
  argument),
- malformed lines, mis-permissioned files (must be 0600), and values
  containing quotes, backslashes, or control characters (docker `-e`
  injection guard — the backslash case is matched by an *unquoted* `*\\*`
  pattern; a quoted `'\\'` matches only doubled backslashes and silently
  admits a single one).

`scripts/reviewer_provider_env_test.sh` is the executable regression suite
(108 assertions: every protected key rejected, legitimate provider keys
accepted, near-miss names rejected by exact matching, single- and
doubled-backslash values rejected, duplicate keys rejected, and
malicious/mixed/mis-permissioned/injection-bearing files refused). Run it
anywhere; it is part of QA.

## Auth-gate activation — corrected for hermes 0.21.x

Verified in-container against the shipped source: setting
`HERMES_DASHBOARD_BASIC_AUTH_{USERNAME,PASSWORD,SECRET}` **alone does not
register the provider** at serve time — the bundled `basic` dashboard-auth
plugin must also be enabled in the home (`hermes plugins enable basic`,
recorded in the home's `config.yaml` under `plugins.enabled`). v1 of this
document claimed env vars alone engage the provider; that was wrong. The
v2 launcher's seeding step enables the plugin in the disposable home and
the auth-config step writes the scrypt `password_hash` (never plaintext at
rest) by **merging** into the existing config so the plugin state survives.

## Automation (all checked in, all secret-free)

| File | Purpose |
|---|---|
| `scripts/reviewer_env_launch.sh` | v2 launcher: builds nothing, runs ON the container host. Fresh volume + demo seeding, plugin enable, scrypt auth config, hardened container start, egress pinning, `status`/`stop`/`clean [--purge]` |
| `scripts/reviewer_containment_test.sh` | executable containment evidence: 33 probes (filesystem, shell, environment, credentials, network egress incl. UDP/53-scope and IPv6 regression guards, runtime hardening, auth gate) run against the LIVE container — 23 attack probes that must be DENIED, 10 state assertions that must hold (disposable image, demo home writable, public 443 reachable, name resolution working, no IPv6 path, public-but-credential-free provider advertisement, cap-drop ALL, no-new-privileges, read-only rootfs, uid 10000) |
| `scripts/reviewer_provider_env_lib.sh` | the one allowlist definition (fail closed) |
| `scripts/reviewer_provider_env_test.sh` | allowlist regression suite (108 assertions) |
| `scripts/reviewer_env_check.sh` | off-network pre-submission reachability check (health → providers → login → ws-ticket → unauthenticated-negative) following Fleet's exact wire sequence |
| `scripts/reviewer_env_assets/` | synthetic demo SOUL/SKILL content (demo material only — NOT a security control) |

### Executed QA evidence (re-verified post-fix 2026-09-10 20:58 CDT = 2026-09-11 01:58 UTC, dedicated container host, image `hermes-agent:0.21.1-reviewer` @ `sha256:55d51bf97414…`)

An **independent `apple-qa` challenge** attacked the previous head and
returned `CONTAINMENT CHALLENGE: FALSIFIED`: the runtime containment, auth
gate, allowlist core and teardown all held, but **UDP/53 reached arbitrary
destinations** (the container got real answers from the LAN router and from
`1.1.1.1` — a DNS-tunnel exfil channel), and two allowlist gaps existed
(single-backslash values admitted; duplicate keys splicing a newline into one
`-e` argument). All of it is fixed here and the whole suite was re-run on the
fixed head.

A **second independent `apple-qa` pass re-attacked the fixes** and verified
every security claim with no new hole found: the port-53 scope (its own
matrix: `1.1.1.1`, `8.8.8.8`, `9.9.9.9`, the LAN router, the tailnet address
and other docker networks all denied on UDP and TCP; only docker's resolver
address answers, and name resolution works), the allowlist gaps (including a
bypass hunt over space-prefixed, lone-CR and CRLF duplicates/values),
refused-launch residue (three refusal vectors, zero residue), the IPv6
fail-closed path, and public safety. Its remaining findings were doc-honesty
issues (two sentences overstating the DNS and host-chain exceptions, a stale
`E1–E5` reference) and one ordering nit — the IPv6 refusal ran after
credential generation. Both are fixed here: the wording now matches the
chains exactly, and the IPv6 check runs before credentials or volumes exist.

Evidence from the re-run on the fixed head:

- allowlist regression suite: **108/108 PASS** (includes the new
  single-backslash and duplicate-key cases; the challenger's own 25-case
  adversarial harness now reports every protected key rejected — its only
  "mismatch" is the duplicate-key case, which its harness recorded as
  `accept` for the pre-fix behaviour)
- refused launch: a provider file carrying `HOME=` / `HERMES_HOME=` exits
  non-zero **and leaves nothing behind** — no container, no volume, no
  network, no iptables rule, no credentials file (the allowlist gate now runs
  before anything is created; the IPv6 refusal likewise precedes credentials)
- container bring-up with full hardening flags: PASS; egress pinned to
  established + public TCP/443 + DNS to docker's own resolver address only
  (`172.17.0.1` — the default-bridge gateway, derived at runtime, never a LAN
  router, public resolver or tailnet address)
- containment suite: **33/33 PASS**, including the new regression guards:
  UDP/53 to a public resolver **denied**, UDP/53 to the reviewer gateway / LAN
  router / other docker networks **denied**, network IPv4-only with no IPv6
  route out of the container, and name resolution **working** (E1 + E9).
  The challenger's own attack scripts re-run against this head: external
  UDP/53 timed out, LAN `:53` queries got no reply, tailnet `:53` no reply,
  other docker-network TCP closed.
- Fleet wire sequence with the gate **ENGAGED**: **0 failures** — health 200,
  provider discovery `basic`, password login + session cookie, ws-ticket 200
  with cookie, unauthenticated ws-ticket → 401
- teardown (`clean --purge`): container, volume, network, state dir, and every
  iptables rule removed — verified no residue (no listener on the serve port)

The challenges' own findings are preserved verbatim in the lane's QA records
(reports attached to the board cards), including what remains accepted by
design — see "Residual risk", above. The public review-window endpoint is
created by the operator at review time; this automation never creates or runs
a tunnel.

## Operations (on the container host, from the repo root)

```sh
# rehearsal (non-loopback host header, no tunnel needed):
REVIEWER_PUBLIC_URL=http://rehearsal.invalid:9318 bash scripts/reviewer_env_launch.sh start
REVIEWER_BASE_URL=http://rehearsal.invalid:9318 \
REVIEWER_ALLOW_INSECURE_HTTP=1 \
REVIEWER_CONNECT_TO='rehearsal.invalid:9318:127.0.0.1:9318' \
REVIEWER_CRED_FILE="$REVIEWER_ENV_DIR/credentials" \
  bash scripts/reviewer_env_check.sh
bash scripts/reviewer_containment_test.sh   # auth-gate probes carry the rehearsal host by default

# review window (operator, after Tony creates the named tunnel):
REVIEWER_PUBLIC_URL=https://<reviewer-host> \
REVIEWER_PROVIDER_ENV_FILE=~/.config/fleet-review/provider.env \
REVIEWER_ENV_DIR=</persistent/path/outside/repo> \
  bash scripts/reviewer_env_launch.sh start
REVIEWER_BASE_URL=https://<reviewer-host> REVIEWER_CRED_FILE=… \
  bash scripts/reviewer_env_check.sh        # from an OFF-network vantage
# and the same containment proof pointed at the real public host:
REVIEWER_CONTAINMENT_PUBLIC_HOST=<reviewer-host> REVIEWER_SERVE_PORT=9318 \
REVIEWER_CRED_FILE=… bash scripts/reviewer_containment_test.sh

bash scripts/reviewer_env_launch.sh status
bash scripts/reviewer_env_launch.sh stop
bash scripts/reviewer_env_launch.sh clean --purge   # destroys everything
```

The launcher never creates or runs tunnels; it prints the exact cloudflared
commands for the operator. A named tunnel (stable hostname, TLS at edge)
is the review-window transport; quick tunnels are rehearsals only.

## What needs Tony (explicitly out of this lane)

1. **Container host designation**: the dedicated Linux container host
   running Docker (the fleet box), with the image built from the local
   hermes-agent source (`docker build -t hermes-agent:0.21.1-reviewer .`).
   The maintainer Mac never runs the reviewer environment.
2. **Scoped demo model key** (hard spend limit) supplied via
   `REVIEWER_PROVIDER_ENV_FILE`; never committed.
3. **Named cloudflared tunnel + DNS record** for the review-window URL.
4. **App Store Connect**: private entry of endpoint/credentials/QR and
   every `[TONY: …]` placeholder in BETA-METADATA.md; human
   export-compliance confirmation.
5. **Review-window operations**: on-call, teardown (`clean --purge`),
   credential/key revocation, tunnel deletion after review.

## Do-not list (enforced by scripts)

- the launcher refuses to run without `REVIEWER_PUBLIC_URL` (auth gate must
  engage) and refuses loopback public URLs (v2 always runs the real
  architecture);
- the launcher destroys and recreates the demo volume on every `start` —
  no inherited state is possible;
- the provider env file is allowlist-gated; a file containing any protected
  or unknown key aborts the launch;
- neither script accepts a secret as a command-line argument; credentials
  are generated 0600 outside the repo or read from env/Keychain;
- `clean` refuses to purge a directory inside the repository;
- the launcher never executes `cloudflared`.
