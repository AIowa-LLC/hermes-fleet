# M11 Authentication Hardening

**Task:** t_08f1395b · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-release per card; orchestrator routes to apple-qa).

## 1. Scope (M11 only)

Per the authorized card (USER BATCH-AUTHORIZED M6–M15 at 2026-08-29;
SEQUENCER dispatch after M10 FINAL PASS commit `1e4bbeb`) + synthesis §11
(AuthenticationProvider abstraction) + spec §16 (Authentication Architecture) +
§29 (Logging) + §31 Security: **auth hardening + redaction.** Built on M10
commit `1e4bbeb` in repo the repository root.

Card scope line: *"single-use WS ticket (30s TTL) + loopback token; 4401
re-auth no silent retry; redaction; no credentials in logs/cache/UI.
Acceptance: auth + redaction; apple-release signs."*

The ticket-mint REST client (`WSTicketClient` for `POST /api/auth/ws-ticket`),
the 4401 close-code mapping, and the reconnect policy (`4401 → reauthenticate,
never silent retry`) already existed from M1/M6. M11 adds the **hardening
surface** on top:

- **`AuthenticationProviding` seam + `ConnectionAuthentication` value**
  (FleetCore) — the spec §16 / synthesis §11 "AuthenticationProvider"
  abstraction. The transport and service layer depend on this protocol, never
  on a concrete ticket minter or Keychain store (mirrors the M7
  `CredentialStoring` / M10 `TokenStoring` seam pattern). The value carries
  either a single-use WS ticket (`?ticket=`), a loopback token (`?token=`), or
  `.none` — and is structurally non-serializable (StoredToken is not Codable),
  so auth material can never reach the SwiftData cache, a file, or a JSON log.
- **`GatewayAuthenticator`** (FleetNetworking) — concrete
  `AuthenticationProviding`: mints a single-use 30s ticket via
  `WSTicketMinting` (session-token/bearer strategy), enforces the client-side
  TTL, or loads a loopback token from `TokenStoring` (Keychain) for the
  `.loopbackToken` strategy; `.none` yields no auth query.
- **Client-side TTL enforcement** — `WSTicket.isExpired(asOf:)` (single-use,
  30s TTL per synthesis §11). The authenticator rejects an expired ticket
  (`AuthenticationError.ticketExpired`) instead of connecting with a stale
  credential.
- **Loopback token URL building** — `buildWebSocketURL(base:path:authentication:)`
  emits `?ticket=` or `?token=` (or no auth query); the legacy ticket-only
  builder delegates to it.
- **4401 re-auth, no silent retry** — `SingleGatewayConnection.reauthenticate()`
  is the explicit re-auth path. The transport never auto-reconnects after a
  4401; the connection surfaces `.authenticationRequired`, and re-auth re-mints
  a FRESH ticket (tested: mint counter increments, never a silent retry with
  the same credential).
- **Redaction** — `WSTicket` and `WSTicketClient` now have redacted printable
  descriptions (previously `WSTicket.token` would have leaked if logged);
  `ConnectionAuthentication` is redacted; and a new `Redaction` utility
  (FleetCore) scrubs sensitive query parameters (`ticket`, `token`,
  `access_token`, `password`, `secret`, …) from URLs for network error logs
  (spec §29).

Explicitly NOT in M11 (per BATCH AUTH + sequencer): UI wiring (P6), gateway
registry on-disk persistence, live Hermes gateway connection (in-process
fixtures only), privileged Hermes operations.

## 2. Files

### FleetCore (pure domain + seams)
| File | Responsibility |
|---|---|
| `ConnectionAuthentication.swift` *(new)* | `ConnectionAuthentication` (none/ticket/loopbackToken, redacted, non-Codable via StoredToken) + `AuthenticationProviding` seam + `AuthenticationError` (no secret material) |
| `Redaction.swift` *(new)* | `Redaction.redactedURL(_:)` / `Redaction.redacted(_:)` — scrubs sensitive query params for safe network error logs (spec §29) |
| `GatewayAuthConfiguration.swift` *(modified)* | `Strategy.loopbackToken` case (synthesis §11 "optional loopback `?token=`") |

### FleetNetworking (transport + auth)
| File | Responsibility |
|---|---|
| `GatewayAuthenticator.swift` *(new)* | concrete `AuthenticationProviding`: ticket path (TTL-checked) / loopback-token path (Keychain via TokenStoring) / none; `TicketOnlyAuthenticator` adapter for the legacy init |
| `WSTicket.swift` *(modified)* | `WSTicket` redacted description + `mintedAt` + `isExpired(asOf:)` TTL check; `WSTicketClient` redacted description (session token never prints) |
| `GatewayWebSocketTransport.swift` *(modified)* | stored `AuthenticationProviding` seam (new init) + M1-compatible ticket-minter init; URL building for ticket/token/none; `TransportError.authenticationFailed`; explicit auth-error classification |
| `SingleGatewayConnection.swift` *(modified)* | `reauthenticate()` (explicit re-auth, no silent retry); maps `authenticationFailed` → `.authenticationRequired` |

### Tests
- `FleetCoreTests/AuthenticationDomainTests.swift` *(new, 11)* — redaction of
  ticket/loopback auth values (description/debugDescription/interpolation),
  equality, non-Codable structural invariant, `AuthenticationError` vocabulary,
  `AuthenticationProviding` seam construction, `Strategy.loopbackToken`,
  `Redaction.redactedURL` scrubbing (ticket/token/access_token/password) while
  preserving host + non-secret query for §30 classification.
- `FleetNetworkingTests/AuthenticationHardeningTests.swift` *(new, 14)* —
  WSTicket redaction + TTL (fresh/expired), WSTicketClient session-token
  redaction, `GatewayAuthenticator` ticket / expired-ticket / loopback /
  missing-loopback / none paths, transport URL building for `?ticket=` and
  `?token=` + `.none`, redactable built auth URL, and the **4401 re-auth**
  integration test: 4401 → `.authenticationRequired`, `reauthenticate()`
  reconnects and mints a NEW ticket (never a silent retry).
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified, +4)* — app-level
  proofs: `AuthenticationProviding` constructible in the composition root over
  the Keychain token store + ticket minter (ticket/loopback/none paths);
  WSTicket + ConnectionAuthentication redaction in the app context; loopback /
  ticket URL building; `Redaction` scrubs a built auth URL.

## 3. Design decisions (ADR-style)

1. **Authentication is a FleetCore seam, not a transport detail.** Spec §16
   says "Authentication must be abstracted from transport." The transport now
   depends on `AuthenticationProviding` (returning `ConnectionAuthentication`);
   the concrete `GatewayAuthenticator` composes ticket minting + the Keychain
   token store. This mirrors the established M7/M10 seam pattern and keeps
   FleetUI free of concrete auth mechanics.
2. **`ConnectionAuthentication` is redacted AND structurally non-serializable.**
   Its secret is carried by `StoredToken` (not Codable), so the value can never
   be written into the SwiftData cache, a file, or a JSON log by accident — the
   "no credentials in cache" guarantee is structural, not by discipline
   (synthesis §12).
3. **Single-use 30s TTL is enforced client-side too.** The gateway enforces
   single-use/expiry, but the client refuses to connect with a ticket whose TTL
   has elapsed (`isExpired`), so a stale ticket can never be reused across a
   long-lived UI or a reauth attempt. Fail closed (synthesis §11).
4. **Loopback token is a first-class strategy.** Synthesis §11 lists "optional
   loopback `?token=`"; the `Strategy.loopbackToken` case + URL builder +
   authenticator path make it constructible and testable end-to-end without a
   live gateway.
5. **Re-auth is explicit, never silent.** The 4401 close already maps to
   `.reauthenticationRequired` / `.authenticationRequired` (M1/M6/M3). M11 adds
   the explicit `reauthenticate()` surface and proves the transport never
   auto-reconnects with the same credential (mint-count test).
6. **Redaction is defense at the log boundary.** Every secret-bearing type
   (`WSTicket`, `WSTicketClient`, `StoredToken`, `GatewayCredential`,
   `ConnectionAuthentication`) now prints `[REDACTED]`, and `Redaction` scrubs
   sensitive query params from URLs so a network error log can say WHICH
   gateway failed (spec §30) without echoing credentials (spec §29).

## 4. Verified contracts (source-grounded)

- Ticket mint: `POST {base}/api/auth/ws-ticket` (header
  `X-Hermes-Session-Token`) → `{ticket, ttl_seconds}` TTL 30 —
  `hermes_cli/dashboard_auth/routes.py:932`, `ws_tickets.py` (unchanged from
  M1; TTL now also enforced client-side).
- Socket auth query params: `?ticket=` (single-use ticket) and loopback
  `?token=` — synthesis §4/§11 (query-param path because iOS cannot set WS
  upgrade headers).
- Close codes: 4401 = bad credential → re-auth, never silent retry —
  `hermes_cli/web_server.py` (M1 verified; M6 ReconnectPolicy).
- Keychain: `WhenUnlockedThisDeviceOnly`, no iCloud sync (synthesis §12) —
  unchanged from M7/M10.

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2. Ran via `bash m11_validate.sh`
(**PASS=17 FAIL=0**).

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **123 tests, 0 failures** (112 prior + 11 new AuthenticationDomainTests) |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetNetworking` | **149 tests, 0 failures** (135 prior + 14 new AuthenticationHardeningTests) |
| `swift build` / `swift test` FleetSecurity | 20 tests, 0 failures (regression, unchanged) |
| `swift build` / `swift test` FleetPersistence | 15 tests, 0 failures (regression, unchanged) |
| `xcodegen generate` | Regenerated; the development team present; package refs intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 28 tests, 0 failures** (24 prior + 4 new M11 boundary) |
| Secrets scan (M11 sources) | No hardcoded secret-like literals; fixture values are test-only |
| Redaction structural checks | WSTicket redacted description present; cache models no secret-named fields; seam + Redaction present |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Evidence highlights:
- `GatewayAuthenticator` ticket path mints and wraps a single-use ticket; an
  expired ticket throws `AuthenticationError.ticketExpired` (never reused) ✓
- Loopback path loads the token from the token store and returns
  `.loopbackToken` → `?token=`; missing token throws; `.none` yields no auth
  query ✓
- `buildWebSocketURL` emits `?ticket=` / `?token=` / none; a built auth URL is
  redactable (`Redaction` strips the secret value) ✓
- **4401 re-auth:** connect → server closes 4401 → status
  `.authenticationRequired` (no auto-retry) → `reauthenticate()` reconnects and
  mints ticket #2 — never a silent retry with the same credential ✓
- Redaction: `WSTicket`, `WSTicketClient` (session token), and
  `ConnectionAuthentication` never print raw secrets in description /
  debugDescription / interpolation ✓
- App-level: auth provider constructible over real Keychain token store +
  ticket minter; redaction and URL building hold in the app composition root ✓

## 6. Known limitations / handoff notes

- The `.bearerToken` strategy is accepted vocabulary but not a separate
  implementation (it reuses the ticket path — consistent with M7, which kept it
  "accepted vocabulary; not v0").
- Loopback token UI flows (entering/storing a loopback token in Settings) are
  P6 UI wiring, out of this card's scope; the seam + Keychain path are in place.
- No live Hermes gateway connection in M11 — transport/network fixtures only
  (consistent with M1–M10).

## 7. Out-of-scope respected

NO UI wiring (P6) · NO gateway-registry on-disk persistence · NO live Hermes
gateway connection · NO privileged Hermes operations. `FleetUI` imports 0
`FleetNetworking` (structural guard preserved).
