# Reviewer Hermes environment — provisioning design

This document specifies the disposable Hermes gateway environment that Hermes
Fleet's external TestFlight reviewers connect to, and the automation skeleton
this repository ships for it. It pairs with the reviewer-facing walkthrough in
[`REVIEWER-PACKAGE.md`](REVIEWER-PACKAGE.md) and the App Store Connect draft in
[`BETA-METADATA.md`](BETA-METADATA.md). Those two documents land via the
sibling reviewer-package lane (branch `hermes/i18-reviewer-package`); if the
links 404 on this branch alone, that is why — they exist once the lanes merge.
Those documents tell Apple what to do; this one defines the environment
they do it against and how the operator runs it.

Nothing in this file or the scripts it describes commits an endpoint,
credential, QR payload, or any secret. Every secret is resolved at runtime from
the environment, a `0600` file outside the repository, or the macOS Keychain.

## Requirements recap (issue #18)

- reachable from outside the maintainer network over an encrypted, supported path
- authenticated; isolated from personal/business Hermes data
- disposable or narrowly scoped; stable for the whole review window
- demonstrates: gateway connection, roster/profile visibility, chat session
  creation, streamed prompt/response, basic model/session state, one safe demo
  skill, bot/profile inspection
- pre-submission reachability check using the same endpoint Apple receives
- revocable credentials; no production fleet, no maintainer secrets

## Architecture (chosen design)

```
iPhone (reviewer)                 public internet
    │  Hermes Fleet                      │  TLS (terminated at tunnel edge)
    │  Add Gateway → URL + user/pass     ▼
    │                       ┌──────────────────────────┐
    └──────────────────────►│  cloudflared tunnel      │
                            │  https://<reviewer host> │
                            └────────────┬─────────────┘
                                         │ plaintext, loopback only
                                         ▼
                            ┌──────────────────────────┐
                            │ hermes serve             │
                            │ --host 127.0.0.1         │
                            │ --port <REVIEWER_SERVE_PORT>
                            │ auth gate ON via         │
                            │   HERMES_DASHBOARD_      │
                            │   PUBLIC_URL             │
                            │ basic-auth provider via  │
                            │   HERMES_DASHBOARD_      │
                            │   BASIC_AUTH_* env       │
                            └────────────┬─────────────┘
                                         │
                            HERMES_HOME = disposable dir
                            (fresh profile home: synthetic roster,
                             one demo skill, scoped demo model key)
```

Ground truth for every mechanism cited below was verified against the
installed Hermes server source and CLI (`hermes serve --help`,
`hermes_cli/web_server.py`, `plugins/dashboard_auth/basic/__init__.py`) and
against this repository's existing hermetic-launch script
(`scripts/p08_launch_gateways_hermetic.sh`):

1. `hermes serve` never opens a browser UI and binds `127.0.0.1` by default.
   The `--insecure` flag is a documented no-op: a non-loopback bind ALWAYS
   requires an auth provider. The supported remote-access deployment is
   "bind loopback + tunnel", which is what this design does.
2. Setting `dashboard.public_url` (or the `HERMES_DASHBOARD_PUBLIC_URL` env
   var) engages the dashboard auth gate on an otherwise-loopback bind
   whenever the public URL's host is non-loopback — it is the operator's
   declaration of "this backend is reached through a public URL", and it
   registers the public host as the trusted Host/Origin for WebSocket
   upgrade validation behind a reverse proxy. A LOOPBACK public URL (e.g.
   `http://127.0.0.1:<port>`, pure transport rehearsal) does NOT engage the
   gate: `should_require_dashboard_auth()` only engages for a non-loopback
   bind or a non-loopback public-URL host. The launcher therefore reports
   gate engagement honestly and always sets the variable to the real tunnel
   URL for the review window.
3. The bundled basic-auth provider activates from
   `dashboard.basic_auth.{username,password,secret}` in `config.yaml` OR the
   `HERMES_DASHBOARD_BASIC_AUTH_{USERNAME,PASSWORD,SECRET}` env vars, with env
   winning when non-empty. Passwords are scrypt-hashed; sessions are
   HMAC-signed stateless tokens. Login is `POST /auth/password-login`
   (JSON username/password → session cookie), then
   `POST /api/auth/ws-ticket` (single-use WebSocket ticket) — the exact
   sequence Hermes Fleet's `GatewayAuthenticator` performs, so a successful
   reachability check exercises the same wire path Apple will.

## Public-path mechanism options

| # | Mechanism | Setup | Stability | Exposes | Verdict |
|---|-----------|-------|-----------|---------|---------|
| A | **cloudflared quick tunnel** (`cloudflared tunnel --url http://127.0.0.1:<port>`) | none — no Cloudflare account, no DNS; prints a random `https://<token>.trycloudflare.com` URL | URL rotates on every restart; best-effort availability | full gateway surface, TLS at edge, behind Hermes auth | **dry-runs and internal validation only** — never the review window |
| B | **cloudflared named tunnel** (`cloudflared tunnel create` + DNS CNAME) | Cloudflare account + DNS zone — Tony-only | stable hostname across restarts; can run as a service (`cloudflared service install`); optional Cloudflare Access in front | same as A with a fixed URL | **recommended for the review window** |
| C | cloudflared on a public host (e.g. the Arch fleet box) forwarding to this Mac over the tailnet | Tony-only: tunnel + DNS + tailnet routing to the Mac's disposable port | stable; keeps the Mac out of public DNS | gateway surface via one tailnet-forwarded port; the production tailnet carries reviewer transit to exactly one port | acceptable Tony-owned alternative if the Mac must not run the tunnel itself |
| D | Tailscale Funnel | tailnet admin + HTTPS certs — Tony-only | stable `*.ts.net` URL | same gateway surface; public tailnet hostname | viable but couples the review URL to the private tailnet name; prefer B |
| E | direct LAN/port-forward, tailnet IP, or maintainer hostname | — | — | exposes the home network / private infra; violates issue #18 | **rejected** |

Chosen: **B for the review window, A for rehearsals.** The launcher script
never creates a tunnel itself (this lane is forbidden from creating real
tunnels); it prints the exact commands for the operator after the backend is
up, and the reachability check works against whichever URL the operator
supplies.

### What a tunnel actually exposes — honest scope

The Hermes dashboard/gateway API is not per-route scoped: a client holding
valid reviewer credentials can reach the full JSON-RPC/WebSocket surface the
dashboard serves, including administrative routes. There is no partial-API
credentials mode. The isolation therefore comes from the environment, not
from credential scoping:

- the `HERMES_HOME` is a throwaway directory containing only synthetic
  content and a scoped demo model key — worst case, an abusive reviewer
  spends the demo key's budget or trashes a disposable home;
- credentials are generated fresh per provisioning run and revoked by
  teardown;
- the model key is a low-limit scoped key (Tony-provisioned), never a
  maintainer key;
- approvals stay in `smart` mode with the documented unattended/cron
  `deny` defaults, so dangerous commands surfaced through unattended surfaces
  are blocked rather than prompted.

This limitation is stated here deliberately and should not be softened in
review notes: reviewers get a real, full-capability Hermes gateway against a
synthetic, disposable home.

## Isolation properties

- **Separate Hermes home.** The launcher refuses to run against the default
  `~/.hermes` (it fails fast if `HERMES_HOME` would resolve there). All
  state — config, sessions, skills, state DB, logs — lives under
  `$REVIEWER_ENV_DIR/home` which is created empty and destroyed only by
  `clean --purge` (plain `clean` stops the serve and keeps state).
- **Hermetic process environment.** The serve process is launched with
  `env -i` and an explicit minimal environment (the pattern already proven in
  `scripts/p08_launch_gateways_hermetic.sh`), so no agent-session, kanban, or
  profile variables from the maintainer's machine leak into the reviewer
  gateway. The only inherited values are explicitly forwarded: `PATH`,
  `HOME`, `HERMES_HOME`, the public-URL variable, the three basic-auth
  variables, timezone, and variables from the operator's provider env file.
- **No messaging platforms.** The fresh home has no platform tokens, so
  Telegram/Discord/etc. inbound surfaces never come up.
- **No personal data.** Nothing is cloned from any existing profile. The
  roster is created synthetic (below).

## Demo-content seeding plan

All steps are performed by `scripts/reviewer_env_launch.sh start` inside the
disposable home — no secrets involved:

1. **Initialize the home** by creating two demo bot profiles with the
   supported CLI, e.g.
   `HERMES_HOME=<dir> hermes profile create reviewer-demo-oracle --description "..."`.
   In Hermes, a Bot IS a profile, so the gateway's roster immediately shows
   synthetic entries with names/descriptions Fleet can render. Profile names
   are prefixed `reviewer-demo-`; note `profile create` also installs
   command aliases at `~/.local/bin/<name>`, which the launcher's `clean
   --purge` removes.
2. **Demo personas**: a short synthetic `SOUL.md` is written into each demo
   profile (friendly demo assistant, states it is a disposable review bot).
3. **Safe demo skill**: the launcher copies the checked-in skill
   `scripts/reviewer_env_assets/reviewer-demo/SKILL.md` into
   `<home>/skills/reviewer-demo/`. It is intentionally read-only static
   knowledge (describes the demo environment and what is safe to try); it
   requires no tools, no network, no shell. This is the skill the
   REVIEWER-PACKAGE walkthrough's step 7 refers to.
4. **Model key**: the ONLY secret in the environment. The operator provides a
   scoped, low-limit provider key at runtime via `REVIEWER_PROVIDER_ENV_FILE`
   (a `0600` file outside the repo, e.g. `KEY=value` lines). The launcher
   forwards those variables into the serve process only; they are never
   written inside the repository, printed, or logged. Chat replies will not
   work until this is supplied — rehearsal without a key can still validate
   connect/auth/roster/skills.

## Credentials and access artifact

- Username/password/session-secret are resolved at launch in this order:
  explicit `REVIEWER_USERNAME`/`REVIEWER_PASSWORD`/`REVIEWER_SECRET` env →
  one Keychain generic-password item named by `REVIEWER_KEYCHAIN_ITEM`
  (service = the item name; the reviewer USERNAME is the item's `acct`
  account attribute; the reviewer PASSWORD is the item's password field,
  read via `security find-generic-password -w`, never echoed) → freshly
  generated with `openssl rand` and stored `0600` in
  `$REVIEWER_ENV_DIR/credentials`.
- The pairing QR for Apple is generated AFTER the tunnel exists, with the
  existing checked-in generator, into the (untracked) env dir:
  `bash scripts/f2_generate_pairing_qr.sh "$REVIEWER_PUBLIC_URL" "$REVIEWER_USERNAME" "$REVIEWER_PASSWORD"`
  — output PNG lives under `$REVIEWER_ENV_DIR/` and is handed to Apple only
  through App Store Connect's private review-access fields, per
  [`REVIEWER-PACKAGE.md`](REVIEWER-PACKAGE.md) and
  [`docs/gateway-pairing.md`](../gateway-pairing.md).

## Operations

```sh
# FULL REHEARSAL (primary quick-start — all 5 checks, auth gate genuinely
# engaged; verified working end-to-end). Use a NON-loopback rehearsal
# hostname (any name you control locally is fine; nothing resolves it —
# REVIEWER_CONNECT_TO routes it to the loopback serve without DNS changes):
REVIEWER_ENV_DIR=${TMPDIR:-/tmp}/hermes-fleet-reviewer
REVIEWER_PUBLIC_URL=http://fleet-reviewer.example.com:9318 \
  bash scripts/reviewer_env_launch.sh start
REVIEWER_BASE_URL=http://fleet-reviewer.example.com:9318 \
REVIEWER_ALLOW_INSECURE_HTTP=1 \
REVIEWER_CONNECT_TO='fleet-reviewer.example.com:9318:127.0.0.1:9318' \
REVIEWER_CRED_FILE=$REVIEWER_ENV_DIR/credentials \
  bash scripts/reviewer_env_check.sh
#   -> expect 6/6 OK, exit 0 (transport policy, health, providers, login,
#      ws-ticket, negative probe)
#   (CONNECT_TO maps the URL's host AND port to the loopback serve.)

# TRANSPORT SMOKE ONLY (loopback URL — gate NOT engaged by design, checks
# 2-5 auto-skipped; proves serve-up/health only, never a pre-submission
# result):
REVIEWER_PUBLIC_URL=http://127.0.0.1:9318 bash scripts/reviewer_env_launch.sh start
bash scripts/reviewer_env_check.sh   # auto-targets the loopback instance

# review-window bring-up (operator, after Tony creates the named tunnel):
REVIEWER_PUBLIC_URL=https://<reviewer-host> \
REVIEWER_PROVIDER_ENV_FILE=~/.config/fleet-review/provider.env \
REVIEWER_ENV_DIR=</persistent/path> \
  bash scripts/reviewer_env_launch.sh start
REVIEWER_BASE_URL=https://<reviewer-host> \
REVIEWER_CRED_FILE=</persistent/path>/credentials \
  bash scripts/reviewer_env_check.sh   # from an OFF-network vantage point

bash scripts/reviewer_env_launch.sh status
bash scripts/reviewer_env_launch.sh stop
bash scripts/reviewer_env_launch.sh clean           # stops serve, KEEPS state
bash scripts/reviewer_env_launch.sh clean --purge   # destroys home + aliases
```

`start` prints the exact quick-tunnel and named-tunnel `cloudflared` commands
but never executes them. For the review window the operator should keep the
Mac awake (`caffeinate -dimsu`) and prefer a persistent `REVIEWER_ENV_DIR`
(note `${TMPDIR:-/tmp}` is purged on reboot) plus a service-managed tunnel.

### Pre-submission reachability check

`scripts/reviewer_env_check.sh` is the operator-side check the package doc
requires. Given only a base URL and credentials (env or `0600` cred file,
never argv), it performs, following the exact wire sequence the Fleet app
performs (`PasswordLogin` → `GatewayAuthenticator`), without printing
secrets:

1. `GET /api/health` — public liveness probe, must answer 200 `{"ok":true}`;
2. `GET /api/auth/providers` — must advertise a password-capable provider
   (the bundled `basic` provider);
3. `POST /auth/password-login` with `{provider, username, password}` — must
   return `200` and set a session cookie (429 = rate-limited, reported as a
   failure with a do-not-hammer hint);
4. `POST /api/auth/ws-ticket` with that cookie — must return `200` and a
   single-use ticket;
5. **negative probe**: `POST /api/auth/ws-ticket` WITHOUT credentials must
   NOT return `200` — proving the auth gate is genuinely engaged, so an
   accidentally unauthenticated tunnel cannot pass the check.

It refuses non-HTTPS URLs except an explicit loopback smoke (gate off by
design; auth checks 2–5 are skipped with a printed note — a healthy ungated
loopback serve 401s `/api/auth/providers` because it is not in the loopback
public path set, so a loopback smoke proves transport only, never
readiness) and a rehearsal-only `REVIEWER_ALLOW_INSECURE_HTTP=1` escape
hatch for exercising the gate locally via `REVIEWER_CONNECT_TO` (routes the
public hostname to the loopback serve without DNS changes — this is the
PRIMARY documented rehearsal above, verified working against a live
auth-gated serve). Credentials are never accepted as command-line
arguments, and the cookie jar is a `0600` temp dir removed on exit. Run it
from an off-network vantage (phone hotspot, or the public host via SSH)
before every submission, matching issue #18's validation section.

## Stability across the review window

- named tunnel (option B) keeps one URL across restarts of both tunnel and
  backend;
- the launcher's `status`/`stop` make restarts mechanical; the state that
  matters (roster, sessions) lives under `REVIEWER_ENV_DIR`;
- credential rotation = re-run `start` with new credentials + re-run the
  check + update Apple's private review fields (package doc's incident
  procedure). No repository artifact changes.

## What exists vs. what needs Tony

Exists after this change (all secret-free, checked in):

- this design doc;
- `scripts/reviewer_env_launch.sh` — disposable-home provisioning, demo
  seeding, hermetic authenticated `hermes serve`, status/stop/clean;
- `scripts/reviewer_env_check.sh` — off-network pre-submission reachability
  check incl. negative auth probe;
- `scripts/reviewer_env_assets/reviewer-demo/SKILL.md` — safe demo skill;
- tunnel *commands* printed by the launcher (not executed).

Requires Tony (explicitly out of this lane's authority):

1. **Scoped demo model key** with a hard spend limit (provider console) —
   supplied at runtime via `REVIEWER_PROVIDER_ENV_FILE`; never committed.
2. **Named cloudflared tunnel + DNS record** for the review-window URL
   (Cloudflare account), or a decision to host the tunnel on the Arch fleet
   box (option C) — either way, tunnel creation is a Tony step; this Mac's
   scripts never create tunnels.
3. **App Store Connect**: entering demo endpoint/credentials/QR privately,
   resolving every `[TONY: ...]` placeholder in `BETA-METADATA.md`, and the
   human export-compliance confirmation (package lane owns the draft).
4. **Review-window operations**: keeping the Mac awake and reachable,
   on-call for the window, teardown (`clean --purge`), key revocation, and
   Cloudflare tunnel deletion after review.
5. Optional: Tailscale Funnel (option D) if preferred over Cloudflare —
   tailnet admin decision.

## Do-not list (enforced by scripts)

- the launcher refuses `HERMES_HOME` = the maintainer default;
- the launcher never executes `cloudflared`;
- neither script accepts a secret as a command-line argument;
- no secret, endpoint, or QR artifact is ever written inside the repository
  worktree — the env dir is expected to live outside it, and `clean` refuses
  to purge a directory that is the repository root or the default Hermes
  home.
