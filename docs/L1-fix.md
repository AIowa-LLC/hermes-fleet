# L1 fix — app auth wiring: UI-stored credentials reach the live gateway

**Task:** t_c0bfc604 · **Assignee:** apple-dev · **Board:** hermes-fleet-ios
**Date:** 2026-08-30 (CDT) · **Base:** be5b5df (L1 dogfood HOLD) · **Status:** Fixed + verified live.
**Verdict: PASS** — a gateway added via the U2 UI with a real loopback token
connects (Reachable) against a live `hermes serve`, and the Roster returns
REAL profiles.

## 1. Root cause (from L1, verified in source at be5b5df)

Three structural findings blocked every UI-entered credential from
authenticating against a real gateway:

1. **Store split** — the U2 UI writes via
   `saveCredential → GatewayRegistryService.saveCredential → KeychainCredentialStore`
   (service `com.aiowa.hermesfleet.gateway-credentials`), but the
   production `.loopbackToken` authenticator read
   `KeychainTokenStore` (service `com.aiowa.hermesfleet.tokens`) via
   `tokenStore.loadToken`. Nothing in the app ever calls `saveToken` →
   `AuthenticationError.missingLoopbackToken` → classified offline.
2. **Strategy force-override** — `GatewayRegistryService.saveCredential`
   forced `authConfiguration` to `.sessionToken` regardless of the UI
   selection, so a user-selected loopback strategy was clobbered.
3. **Dead ticket minter** — `FleetServiceGraph.makeAuthenticator` built
   `WSTicketClient(baseURL: sessionToken: nil)` for `.sessionToken`/`.bearerToken`,
   so the stored credential was never sent as `X-Hermes-Session-Token` on
   `POST /api/auth/ws-ticket`.

## 2. The fix (three coordinated changes)

**A. `GatewayAuthenticator` (FleetNetworking)** — reads the credential from
`CredentialStoring` — the SAME store the U2 UI writes — for BOTH paths:
- `.loopbackToken` → `credentialStore.loadCredential(for:)` →
  `.loopbackToken(StoredToken)` → `?token=` on the socket.
- `.sessionToken`/`.bearerToken` → loads the stored credential and builds the
  `WSTicketClient(baseURL: sessionToken: credential.rawValue)` itself (when no
  minter is injected), so `X-Hermes-Session-Token` is actually sent on the mint.

**B. `GatewayRegistryService.saveCredential`** — preserves the gateway's
configured strategy (`gateway.authConfiguration.strategy`) instead of forcing
`.sessionToken`. The UI owns the strategy (set via addGateway registration /
updateGateway); saveCredential only marks `credentialStored = true`.

**C. `FleetServiceGraph` (production graph)** — threads the single
`KeychainCredentialStore` into every factory (connection / probe / roster
session / conversation) and `makeAuthenticator`; the dead `KeychainTokenStore`
wiring is removed. Now a credential entered in the UI lands in the store the
authenticator reads.

## 3. Evidence

### 3.1 Regression tests (FleetNetworking + FleetSecurity, all green)

| Test | Proves |
|---|---|
| `testLoopbackCredentialStoredViaRegistryReachesAuthenticator` | Finding #1: a credential saved via `GatewayRegistryService.saveCredential` (the UI path) authenticates a `.loopbackToken` gateway from the SAME store |
| `testSessionTokenAuthenticatorSendsStoredCredentialAsHeader` | Finding #3: the built `WSTicketClient` sends the stored credential as `X-Hermes-Session-Token` (URLProtocol capture) |
| `testSaveCredentialPreservesConfiguredStrategy` | Finding #2: saveCredential preserves loopback/session/bearer strategy, never forces `.sessionToken` |

Full suite: FleetCore 123/0, FleetNetworking 160/0, FleetSecurity 20/0,
FleetPersistence 15/0 (see `scripts/l1_fix_validate.sh`).

### 3.2 Live gateway dogfood (Release app, production graph)

`scripts/l1_start_serve.sh` → real `hermes serve` on loopback :9119 with a
test-only token at `/tmp/l1_live_test/.token` (chmod 600, never printed).
`L1FixLiveGatewayUITests` (Release app on the simulator) adds the real gateway
via the U2 UI and asserts the acceptance:

| Step | Result | Evidence |
|---|---|---|
| Add gateway via U2 UI (Loopback Token + real token) | ✅ row "Mac Live / http://127.0.0.1:9119 / Auth configured" | `build/l1-fix/l1fix-step3-gateway-added-row.png` |
| **Test connection (live probe)** | ✅ **Connected (Reachable)** — was Unreachable in L1 | `build/l1-fix/l1fix-step3-test-connection-result.png` |
| **Roster against live gateway** | ✅ **6 real profiles**: apple, apple-design, apple-dev, apple-qa, apple-release, default (real routes + models) | `build/l1-fix/l1fix-step4-roster-live.png` |

`L1FixLiveGatewayUITests` — `** TEST SUCCEEDED **` (Release,
`-only-testing:HermesFleetAppUITests/L1FixLiveGatewayUITests`).

### 3.3 Where the evidence lives

- New evidence under `build/l1-fix/` (the L1 evidence under `build/l1/` and
  `docs/L1-live-dogfood.md` are NOT mutated).
- `scripts/l1_fix_validate.sh` reproduces the full check; `l1_fix_copy_evidence.sh`
  consolidates the exported XCUITest attachments.
- No real credentials touched or committed; the test token is throwaway, local,
  and never printed (secrets scan: 0 occurrences in committed files).

## 4. Honest residual notes

- The roster screen auto-refreshes once at app launch (before any gateway is
  added), so the XCUITest taps the Roster **Refresh** button after adding the
  gateway — the same action a user takes. This is a UI-flow nuance, not a
  regression of this fix.
- The session-token header path is proven by the URLProtocol regression test;
  live gated-gateway minting needs a gateway with `auth_required == True`
  (none runs loopback-only on this machine) — covered by the unit test.

— End of L1 fix evidence. No secrets, keys, or credentials recorded. —
