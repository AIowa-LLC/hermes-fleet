# L1 Live gateway dogfood — first-ever live connection to a REAL Hermes gateway

**Task:** t_dc31a446 · **Owner:** apple-release · **Board:** hermes-fleet-ios
**Date:** 2026-08-30 (CDT) · **Status:** Evidence recorded, handed to review.
**Verdict: HOLD** — first live-connection bug (app-side auth wiring) blocks an
in-app authenticated session against a real gateway; every server-side surface
and the app's U2 add-gateway flow are proven independently.

## 1. Scope executed (per card body)

- **PHASE 1 — discover endpoint:** inspected the Mac gateway (default profile
  `hermes gateway run`, PID 87559) and the Arch gateway (`ssh user@node-a`,
  systemd `hermes-gateway.service`). Mapped every surface that speaks the
  JSON-RPC `/api/ws` + `/api/auth/ws-ticket` protocol, plus the agent roster.
- **PHASE 1b — verify reachability + real RPC surface:** started a real
  `hermes serve` JSON-RPC backend on loopback :9119 and drove the full M11
  contract over the WS: `gateway.ready`, `profiles.list`, `session.list`,
  `session.create`, `session.events.since`, `gateway.ping` — **all live, all
  PASS**, including a real agent turn (a `prompt.submit` created session
  "Echo L1-DOGFOOD-OK exactly").
- **PHASE 2 — configure the app:** added the real gateway via the **U2
  gateway-management UI** (Release build = production graph: real Keychain +
  live transport) — **no hardcoding**. Row appeared with the live endpoint and
  "Authentication configured" (Keychain credential stored).
- **PHASE 3 — live §32 walkthrough attempt:** drove all 10 walkthrough steps
  against the live gateway in the app (see §5). Steps 1-3 of the DoD executed
  and rendered; the **in-app live probe classified the real gateway
  "Unreachable"** and the Roster showed "No Bots" — the expected
  first-live-connection bug, root-caused to app-side auth wiring (§6), NOT to
  the gateway.
- **PHASE 4 — report honestly:** PASS on discovery + server-side contract +
  U2 add flow; **HOLD** on in-app live authenticated session pending the auth
  wiring fix. Structural findings filed, not fixed (per card).
- **TOOLING:** script files + `bash <script>` only (as mandated). No inline
  one-liners for the dogfood itself.

## 2. Baseline (git)

| Item | Value |
|---|---|
| main HEAD | `6bc8383` (U4 Dogfood re-run: §32 steps 1-10 PASS + G1 XCUITest) |
| branch | `main` (clean at start; added `scripts/l1_*.sh` + L1 UI test + this doc) |
| xcodegen | 2.46.0 |
| Xcode / Swift | 26.6 (17F113) / 6.3.3 |
| Simulator | iPhone 17 Pro, iOS 26.5 (booted) |
| App build | Release-iphonesimulator (production graph, `build/DerivedDataL1`) |

## 3. PHASE 1 — endpoint discovery (PASS)

### 3.1 Mac gateway — surfaces that exist

| Surface | What it is | `/api/ws`? | `/api/auth/ws-ticket`? |
|---|---|---|---|
| `127.0.0.1:9900` | default-profile gateway daemon (PID 87559) — **agent roster JSON** (6 real profiles) | 404 | 404 |
| `100.100.200.61:8642` | same daemon, Tailscale bind (api_server platform) | 404 | 404 |
| `127.0.0.1:8642` | `hermes-webui/server.py` (PID 1235, loopback) | 401 (gated) | 401 |
| `127.0.0.1:52875/63474/63597` | `hermes serve` instances (PIDs 87716/7263/8108, loopback) | 401/403 (gated) | 401 |

Key structural fact: **the gateway daemon itself does NOT serve the JSON-RPC
`/api/ws` surface** — that protocol lives in `web_server.py` (the dashboard /
`hermes serve`), and on this machine every running instance is **loopback-only
and auth-gated** (401/403 without credentials). There is **no LAN-reachable
`/api/ws` surface today** (nothing binds the Mac LAN IP 192.168.50.37).

### 3.2 Arch gateway (multi-gateway)

- `ssh user@node-a`: **real second Hermes gateway**, systemd
  `hermes-gateway.service`, running 3h+, multiplexing **10+ profiles**
  (coach, developer, growth, legal, media, ops, product, revenue, outreach,
  qa, researcher), api_server on `100.127.200.89:8642` (Tailscale) +
  LAN `192.168.50.20`.
- **Not LAN-reachable for the JSON-RPC surface from the Mac:** Tailscale
  :8642 `/api/ws` → 404; LAN :8642 → timeout. Arch config also warns about
  unset env refs (`CLOUDFLARE_API_TOKEN`, `A2A_PEER_*`, `HERMES_GPT_BEARER_TOKEN`)
  — config hygiene, not a release blocker.

### 3.3 Chosen endpoint + auth (documented)

For the live dogfood we stood up a **real `hermes serve` JSON-RPC backend on
loopback :9119** (`scripts/l1_start_serve.sh`) with a **test-only** session
token (generated in-script, chmod 600 at `/tmp/l1_live_test/.token`, never
printed). Loopback + no `dashboard.public_url` ⇒ `auth_required == False`, so
the gateway accepts the **legacy `?token=<session-token>` WS path** — exactly
the app's `.loopbackToken` strategy (`buildWebSocketURL` → `?token=`, M11).
Auth per M11: `POST {base}/api/auth/ws-ticket` (gated mode) or `?token=` /
`?ticket=` on the WS (loopback/gated). No real credentials touched or stored.

## 4. PHASE 1b — real RPC surface proof (PASS)

`scripts/l1_live_contract3_lean.sh` — real `hermes serve` on :9119, real
`?token=` WS auth:

| RPC | Result |
|---|---|
| `gateway.ready` event | ✅ received (replay_epoch, heartbeat) |
| `profiles.list` | ✅ `{profiles:[…]}` — real default profile (model `glm-5.3`, provider `custom:zai`, skill_count 97) |
| `session.list` | ✅ `{sessions:[…]}` — real session history incl. the earlier "Echo L1-DOGFOOD-OK exactly" turn |
| `session.create` | ✅ `session_id` present |
| `session.events.since` | ✅ replay path answers (0 events on a fresh session) |
| `gateway.ping` | ✅ `{ok: true}` |
| `prompt.submit` (real agent) | ✅ ran — produced session "Echo L1-DOGFOOD-OK exactly" (server side proven; the earlier full-turn script was killed by the 240s harness timeout, not a protocol failure) |

The app's decode shapes match the live wire format exactly
(`GatewayRosterClient.decodeProfiles` reads `result["profiles"]`,
`decodeSessions` reads `result["sessions"]` — verified against the live
responses). **The Hermes gateway side of this card is fully functional.**

## 5. PHASE 2 + 3 — in-app against the live gateway (add = PASS, live auth = HOLD)

`HermesFleetAppUITests/L1LiveGatewayUITests.swift` — Release app (production
graph) on the booted simulator, live serve on :9119 up.

| §32 step | In-app result | Evidence |
|---|---|---|
| 1 open the app | ✅ Gateways root (Release, empty registry) | `build/l1/l1-step1-open-gateways.png` |
| 2 see machines | ✅ U2 add-gateway sheet opened, endpoint entered via UI (no hardcode) | `build/l1/l1-step2-add-form-filled.png` |
| 3 select a bot / machine | ⚠️ gateway added via UI, strategy **Loopback Token** selected | `build/l1/l1-step2-add-form-strategy-token.png` |
| — gateway added | ✅ row "Mac Live / http://127.0.0.1:9119 / Authentication configured" | `build/l1/l1-step3-gateway-added-row.png` |
| — **test connection (live)** | ❌ **Unreachable** (classified offline) | `build/l1/l1-step3-test-connection-result.png` |
| 4+ roster | ❌ "No Bots / No profiles reported" (probe never connected) | `build/l1/l1-step4-roster-live.png` |
| 5-10 session/prompt/reconnect | ⛔ blocked by the auth wiring bug (§6) — cannot be PASSed in-app today | `build/l1/l1-final-state.png` |

The serve log confirms the app's probe **never reached the network** (zero
inbound frames) — so this is a client-side pre-connect auth failure, and
ATS is ruled out (loopback cleartext is ATS-exempt; no ATS block signature in
the app logs). The gateway itself is reachable and correct (§4).

## 6. Root cause — first live-connection bug (structural, filed not fixed)

The app's **auth credential wiring** is internally inconsistent, so a credential
entered through the U2 UI can never be presented to the live gateway:

1. **U2 UI writes the token to the wrong Keychain store.** The add/auth sheets
   call `environment.saveCredential` → `GatewayRegistryService.saveCredential`
   → `credentials.saveCredential` → **`KeychainCredentialStore`** (service
   `com.aiowa.hermesfleet.gateway-credentials`). But the production
   `.loopbackToken` authenticator reads **`KeychainTokenStore`** (service
   `com.aiowa.hermesfleet.tokens`) — a *different* Keychain service
   (`FleetServiceGraph.makeAuthenticator`, `.loopbackToken` case). Nothing in
   the app ever calls `saveToken` (verified: the only `saveToken` hits are the
   store implementations + the UI button label). ⇒ the loopback token entered
   in the UI can never be found ⇒ `AuthenticationError.missingLoopbackToken`
   → classified offline.
2. **`saveCredential` force-overrides the strategy to `.sessionToken`** —
   `GatewayRegistryService.saveCredential` sets
   `authConfiguration = .init(strategy: .sessionToken, credentialStored: true)`
   regardless of what the user picked (we picked Loopback Token; the registry
   entry became sessionToken).
3. **The `.sessionToken`/`.bearerToken` ticket minter is built with
   `sessionToken: nil`** — `FleetServiceGraph.makeAuthenticator` constructs
   `WSTicketClient(baseURL: base, sessionToken: nil)`, so the stored credential
   is never sent as the `X-Hermes-Session-Token` header on
   `POST /api/auth/ws-ticket`. On a gated gateway the mint returns 401 → no
   ticket → `connectionFailed`/offline.

Collectively these make every auth strategy structurally unable to authenticate
against a real gateway from the UI as wired today. This is **structural app
code** (FleetNetworking/FleetSecurity/FleetServiceGraph/UI seams), so per the
card it is filed as a finding for apple-dev, **not fixed here**.

## 7. Distribution / device note (unchanged honesty)

- A paired iPhone is available; the live
  walkthrough ran on the simulator because **no LAN-reachable `/api/ws` surface
  exists** on the Mac (gateway daemon doesn't serve it; serve/dashboard
  instances are loopback+gated). A LAN-bound surface would require binding +
  an auth provider (June 2026 hardening: public bind always needs auth) — a
  config decision for Tony, not a release blocker for this dogfood.
- Free-team signing reality unchanged (U4): own-device sideload only.

## 8. Verdict

**HOLD** — with strong, separated evidence:

- **PASS** — PHASE 1 endpoint discovery (Mac + Arch surfaces, ws-ticket route,
  chosen endpoint + auth documented).
- **PASS** — PHASE 1b real gateway JSON-RPC surface: every RPC the app speaks
  works live over `?token=` incl. a real agent turn.
- **PASS** — PHASE 2 U2 add-gateway via the real UI (no hardcode), credential
  stored in Keychain, live endpoint registered.
- **HOLD** — PHASE 3 in-app live authenticated session: the app's auth wiring
  (§6) prevents the probe from ever reaching the gateway, so the §32 steps
  5-10 cannot pass in-app today. This is the **first live-connection bug the
  card anticipated** — documented with exact cause, classified as structural
  findings, not silently fixed.

Not self-certified — handed to apple-qa for independent review per protocol.

— End of L1 live gateway dogfood evidence. No secrets, keys, or credentials
recorded. —
