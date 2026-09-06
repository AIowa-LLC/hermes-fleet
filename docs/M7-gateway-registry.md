# M7 Gateway Registry

**Task:** t_8ad04232 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa).

## 1. Scope (M7 only)

Per the authorized card (USER BATCH-AUTHORIZED M6–M15 at 2026-08-29;
SEQUENCER dispatch after M6 FINAL PASS) + synthesis §20 Phase 5 (security)
mapping + spec §31 Gateway / §12 model: **gateway registry management —
add/edit/remove gateways, auth config, test connection, capability surface,
Keychain credential storage.** Built on M6 commit `cc67b2d` in repo
the repository root.

Card scope line: *"add/edit/remove gateways, auth config, test connection,
capability surface, Keychain credential storage. Acceptance: spec §31 Gateway
+ §12 model; Keychain safe."*

Deliverables:
- **`GatewayRegistryManaging`** (FleetCore) — the M7 seam protocol: add /
  update / remove, save / clear credential, `hasCredential`, `testConnection`,
  fail-closed lookup (`allGateways` / `gateway(for:)`). FleetUI stays free of
  FleetNetworking (M0 guard preserved — the concrete service lives in
  FleetNetworking behind this protocol).
- **`GatewayRegistryService`** (FleetNetworking) — concrete
  `GatewayRegistryManaging` actor composing the M2 in-memory `GatewayRegistry`
  with an injected `CredentialStoring` (Keychain in production, in-memory in
  tests) and an injected `GatewayConnectionFactory` (production builds a
  `SingleGatewayConnection`; tests build in-process-server connections).
- **Auth config** (FleetCore) — `GatewayAuthConfiguration` (strategy +
  credential-stored flag), `GatewayCredential` (redacted secret value,
  deliberately NOT Codable), `CredentialStoring` seam + `CredentialStoreError`.
  Credentials never touch source/logs/UI — Keychain only (spec §16, §29).
- **Keychain credential storage** (FleetSecurity) — `KeychainCredentialStore`
  (GenericPassword, service `com.aiowa.hermesfleet.gateway-credentials`,
  account = gateway ID, accessibility `WhenUnlockedThisDeviceOnly`, no iCloud
  sync) + `InMemoryCredentialStore` (test/preview double). The "Keychain safe"
  acceptance is asserted at the attribute level AND with a real simulator
  Keychain round-trip in the app-level boundary test.
- **Test connection** — `testConnection(to:)` probes a registered gateway via
  the injected connection factory, adopts `gateway.ready` capability surface,
  classifies reachable/unreachable into the spec §13 vocabulary, and never
  crashes on disconnect (§31 "disconnect does not crash"). A failed probe is a
  classified `GatewayTestResult`, not a thrown error (unless the gateway is
  absent).
- **Capability surface** (FleetCore) — `GatewayCapabilities` tolerant decode
  of `Set<String>` capability flags into known (`heartbeat`,
  `change_events`, `replay`) + unknown-preserved, per spec §5.5.
- **Gateway identity helper** — `GatewayID(endpoint:)` deterministic ID
  derivation (host:port) when a registration omits an explicit ID (spec §12).
- **`GatewayStatus(connectivityError:)`** — §13 classification for probe
  failures (authRequired / unsupported / offline / degraded) added to the M3
  vocabulary.

Explicitly NOT in M7 (per BATCH AUTH + sequencer): multi-gateway roster /
aggregation (M8, remains gated), persistence across relaunch (P5 SwiftData),
UI wiring (P6), live Hermes gateway connection (tests use in-process fixtures),
any privileged Hermes operations.

## 2. Files

### FleetCore (pure domain + seams)
| File | Responsibility |
|---|---|
| `GatewayAuthConfiguration.swift` | non-secret auth strategy + credential-stored flag (spec §12/§16) |
| `GatewayCredential.swift` | redacted secret value; not Codable; `description`/`debugDescription` redacted |
| `CredentialStoring.swift` | credential-store seam + `CredentialStoreError` (no secrets in errors) |
| `GatewayCapabilities.swift` | tolerant capability surface (`known` + `unknown` preserved) |
| `GatewayRegistration.swift` | add-gateway input (id optional → derived from endpoint) |
| `GatewayEdit.swift` | partial edit value (`applied(to:)`) |
| `GatewayTestResult.swift` | probe outcome (status + capability surface + server identity) |
| `GatewayRegistryManaging.swift` | M7 seam protocol + `GatewayRegistryError` (fail closed) |
| `FleetGateway.swift` *(modified)* | `authConfiguration` field added (defaulted; M0/M2 call sites unchanged) |
| `GatewayID.swift` *(modified)* | `GatewayID(endpoint:)` deterministic derivation |
| `GatewayStatus.swift` *(modified)* | `init(connectivityError:)` — probe classification |

### FleetSecurity (Keychain — the "Keychain safe" acceptance)
| File | Responsibility |
|---|---|
| `KeychainCredentialStore.swift` | real Keychain `CredentialStoring`: GenericPassword, WhenUnlockedThisDeviceOnly, no sync; `baseAttributes` public for attribute assertions |
| `InMemoryCredentialStore.swift` | test/preview double of the same contract |

### FleetNetworking (concrete service)
| File | Responsibility |
|---|---|
| `GatewayRegistryService.swift` | `GatewayRegistryManaging` actor: add/edit/remove, save/clear credential, `hasCredential`, `testConnection` (probe + capability adoption), fail-closed lookups, credential cleanup on remove |

### Tests
- `FleetCoreTests/GatewayRegistryDomainTests.swift` — 18 tests: auth
  configuration (default/cases/Codable), credential redaction (raw value never
  prints), credential equality, store error vocabulary, capability tolerant
  decode + round-trip, registration defaults, edit partial-apply, test-result
  equality/hashable, registry error vocabulary, `GatewayID(endpoint:)`
  derivation, `GatewayStatus(connectivityError:)` classification.
- `FleetSecurityTests/FleetSecurityKeychainTests.swift` — 10 tests:
  in-memory store contract (save/load/delete, missing→nil, delete no-op,
  upsert, per-gateway isolation), and Keychain store query construction
  (GenericPassword class, app-scoped service, gateway-ID account,
  WhenUnlockedThisDeviceOnly accessibility, synchronizable disabled, store
  constructible) — hermetic (no live keychain in package tests).
- `FleetNetworkingTests/GatewayRegistryServiceTests.swift` — 22 tests: add
  (explicit/derived ID, duplicate/empty/invalid rejections), fail-closed
  lookup, update (display name/endpoint/auth config; unknown → notFound),
  remove + credential cleanup, credential save/clear/has + authConfigured
  reflection, test connection happy path (in-process server: ready → online +
  heartbeat/change_events adopted into registry entry), classification
  (authRequired/unreachable/timeout/unsupported/degraded), credential flows to
  the connection factory.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified)* — app-level
  proof the M7 registry seam is constructible in the composition root over the
  Keychain store (add/save/clear/test/remove, stub classifies offline), the
  Keychain store's safe attributes, and a REAL simulator Keychain round-trip
  (save → load → delete; redacted description).

## 3. Design decisions (ADR-style)

1. **Registry management is a seam in FleetCore; the service is in
   FleetNetworking.** `GatewayRegistryManaging` mirrors `HermesTransport` /
   `RosterProviding` / `GatewayConnectivityProviding`: FleetUI and the app
   depend on the protocol; the concrete actor composes the M2 registry with
   transport + Keychain. M0 guard intact (FleetUI imports 0 FleetNetworking).
2. **Secrets never transit the registry model.** Registration/edit carry only
   `GatewayAuthConfiguration` (strategy + stored flag); the credential flows
   through `CredentialStoring` directly to the connection factory. `GatewayCredential`
   is not Codable and prints `[REDACTED]`, so a secret can't leak into logs,
   caches, or artifacts by construction (spec §16, §27, §29).
3. **Test connection is a classification, not a thrown error.** Reachability
   outcomes map to the §13 vocabulary (`GatewayTestResult.status`) so the UI
   can show Online / Auth Required / Offline etc. Only an absent gateway
   throws `.notFound`. The probe always tears down the connection (in-process
   + stub tests assert no crash).
4. **Capability detection stays tolerant.** `GatewayCapabilities` decodes
   `Set<String>` into known + unknown-preserved sets rather than guessing
   versions (spec §5.5). The registry entry's `capabilities` set is updated
   from the adopted `gateway.ready` — server state authoritative (spec §5.3).
5. **Keychain attributes are asserted, not assumed.** `baseAttributes` is
   public so the exact `WhenUnlockedThisDeviceOnly` + no-sync attributes are
   proven in both the package test and the app-level test; a real simulator
   round-trip proves the store persists/retrieves in the app context.
6. **Gateway ID is derivable from the endpoint.** When a registration omits an
   explicit ID, `GatewayID(endpoint:)` derives a stable `host:port` identity,
   satisfying spec §12's "a gateway always has an ID" without forcing the
   caller to mint one. Explicit IDs remain supported.
7. **Fail closed.** `gateway(for:)` returns nil and update/remove/test throw
   `.notFound` for unknown IDs; duplicate registration throws `.duplicate`;
   invalid endpoint / empty display name are rejected before mutation.
8. **Credential cleanup on remove.** Removing a gateway best-effort deletes its
   stored credential (Keychain-safe; missing is a no-op) — a removed gateway
   leaves no secret behind.

## 4. Verified protocol contracts (source-grounded)

- No new wire contract in M7 (test connection reuses the M3 `gateway.ready`
  adoption; capabilities from `{skin, change_events, heartbeat,
  replay_epoch}` — `tui_gateway/ws.py:369-389`).
- Keychain semantics follow Apple's Security framework: `kSecClassGenericPassword`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable =
  false` — matching synthesis §12 (GenericPassword, per-peer, no sync).

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **77 tests, 0 failures** (59 prior + 18 new GatewayRegistryDomainTests) |
| `swift build --package-path Packages/FleetSecurity` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetSecurity` | **10 tests, 0 failures** (new FleetSecurityTests target) |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetNetworking` | **113 tests, 0 failures** (90 prior + 23 new GatewayRegistryServiceTests, incl. probe-teardown assertions) |
| `xcodegen generate` | Regenerated; the development team present; package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 18 tests, 0 failures** (15 prior + 3 new M7 boundary tests, incl. real simulator Keychain round-trip) |
| Secrets scan (M7 sources) | No keys/tokens/passwords; fixture tokens are literal test values |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Registry evidence (in-process servers + scripted stubs, no live node):
- add gateway (explicit + derived ID); duplicate / empty-name / invalid-endpoint
  rejected ✓
- update display name / endpoint / auth config; unknown → notFound ✓
- remove gateway removes it AND its stored credential ✓
- save credential marks `authConfigured` + `authConfiguration.sessionToken`;
  clear restores `.none`; unknown → notFound ✓
- `testConnection` happy path: in-process `gateway.ready` → `.online`,
  capabilities heartbeat/change_events adopted into the registry entry,
  replay_epoch surfaced ✓
- `testConnection` classification: 4401→`.authenticationRequired`,
  unreachable/timeout→`.offline`, unsupported→`.unsupported`,
  server-error→`.degraded` ✓
- probe teardown: `testConnection` tears down its probe connection on EVERY
  exit path — success (real transport reaches terminal `.disconnected`) and
  classified failure (recorded `disconnect()` call) — ADR #3 ✓
- stored credential flows to the connection factory (auth config) ✓
- Keychain: attributes = GenericPassword / WhenUnlockedThisDeviceOnly /
  no-sync (asserted); real simulator round-trip save→load→delete with
  `[REDACTED]` description ✓
- app composition: M7 registry seam constructible over Keychain store +
  unconnected probe classifies offline, no crash ✓

## 6. Known limitations / handoff notes

- Registry entries are in-memory for M7 (as the M2 `GatewayRegistry` is);
  persistence of the non-secret registry across relaunch is P5 (SwiftData) and
  remains out of scope. Credentials DO persist (Keychain).
- Multi-gateway roster / union aggregation is M8 (gated) — M7 registry models
  multiple gateways in the registry but drives no simultaneous transports.
- Test connection in the app uses the default factory (production wires a real
  `SingleGatewayConnection`); the app-level boundary test uses a stub so no
  network is touched in CI.
- The Keychain round-trip test writes a fixture credential to the simulator's
  keychain under the test account and deletes it in the same test; no
  persistent secrets remain.

## 7. Out-of-scope respected

NO multi-gateway roster/aggregation (M8) · NO SwiftData persistence (P5) · NO
UI wiring (P6) · NO live Hermes gateway connection · NO privileged Hermes
operations. `FleetUI` imports 0 `FleetNetworking` (structural guard preserved).
