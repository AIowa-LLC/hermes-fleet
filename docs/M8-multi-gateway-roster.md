# M8 Multi-Gateway Fleet Roster

**Task:** t_63cee438 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa).

## 1. Scope (M8 only)

Per the authorized card (USER BATCH-AUTHORIZED M6–M15 at 2026-08-29;
SEQUENCER dispatch after M7 FINAL PASS commit `090c3f7`) + synthesis §13
(Fleet aggregation) + §20 Phase 7 mapping + spec §31 Multi-Gateway / §32 DoD:
**multi-gateway union fleet roster with partial-outage resilience.** Built on
M7 commit `090c3f7` in repo the repository root.

Card scope line: *"union fleet roster preserving owning gateway; one
unreachable gateway must not break another; Fleet stays useful partially.
Acceptance: spec §31 Multi-Gateway + §32 DoD; apple-qa signs."*

Deliverables:
- **`FleetRosterProviding`** (FleetCore) — the M8 seam protocol: refresh the
  union roster across every registered gateway, returning a
  `FleetRosterSnapshot`. FleetUI stays free of FleetNetworking (M0 guard
  preserved — the concrete service lives in FleetNetworking behind this
  protocol, mirroring `RosterProviding` / `GatewayConnectivityProviding` /
  `GatewayRegistryManaging`).
- **`FleetRosterSnapshot`** (FleetCore) — the refresh result: the union
  `FleetRoster` (every registered gateway with its last-known connection
  state + every bot from gateways that answered `profiles.list`, keyed by full
  `Route`) plus per-gateway `GatewayRosterOutcome` (`loaded(profileCount:)` /
  `failed(status:detail:)`). Exposes `reachableGateways` /
  `unreachableGateways` / `bots(on:)` / `bot(for:)` — the spec §30 vocabulary
  (*"MacBook is unreachable. Researcher on 4090 and Revenue on Arch are still
  available"*).
- **`GatewayRosterSession`** (FleetCore) — one per-gateway unit combining
  connectivity (M3 `GatewayConnectivityProviding`) with roster RPCs (M2
  `RosterProviding`) over a single transport.
- **`FleetRosterService`** (FleetNetworking) — concrete `FleetRosterProviding`
  actor. Composes the M7 registry seam (`GatewayRegistryManaging`), the M7
  credential seam (`CredentialStoring`), and an injected
  `GatewayRosterSessionFactory`. Refreshes every registered gateway
  CONCURRENTLY and independently; a failing gateway is classified into the
  snapshot and NEVER throws the refresh or blocks the others.
- **`SingleGatewayConnection` conformance** (FleetNetworking, modified) —
  `SingleGatewayConnection` now also conforms to `GatewayRosterSession` by
  delegating `fetchProfiles` / `fetchSessions` to a `GatewayRosterClient`
  bound to the SAME transport it owns (one socket per gateway).

Explicitly NOT in M8 (per BATCH AUTH + sequencer): routing hardening (M9),
persistence across relaunch (P5 SwiftData), UI wiring (P6), live Hermes
gateway connection (tests use in-process fixtures), any privileged Hermes
operations.

## 2. Files

### FleetCore (pure domain + seams)
| File | Responsibility |
|---|---|
| `FleetRosterProviding.swift` | M8 seam protocol + `FleetRosterSnapshot` + `GatewayRosterOutcome` (§13/§30 partial-availability vocabulary) |
| `GatewayRosterSession.swift` | `GatewayConnectivityProviding & RosterProviding` — the per-gateway session unit |

### FleetNetworking (concrete service)
| File | Responsibility |
|---|---|
| `FleetRosterService.swift` | `FleetRosterProviding` actor: concurrent union aggregation, per-gateway failure isolation, probe teardown on every path; `GatewayRosterSessionFactory` typealias |
| `SingleGatewayConnection.swift` *(modified)* | additive `GatewayRosterSession` conformance (delegates roster RPCs to a `GatewayRosterClient` over its own transport) |

### Tests
- `FleetCoreTests/FleetRosterDomainTests.swift` — 8 tests: snapshot defaults,
  outcome equality, reachable/unreachable split, fail-closed outcome lookup,
  union-bot lookup preserves owning gateway (identical slugs on two gateways →
  distinct routes), per-gateway bot scoping (absent gateway → no bots),
  gateway entries carry last-known connection state, deterministic ordering.
- `FleetNetworkingTests/FleetRosterServiceTests.swift` — 10 tests: two healthy
  gateways → union roster with 4 bots + correct owners + routing; identical
  `default` profiles stay distinct; one unreachable / authRequired / timeout +
  one healthy → partial availability (healthy bots present, failed classified,
  no throw); empty registry → empty snapshot; stored credential flows to the
  session factory; probe session torn down on success (transport terminal) and
  on failure (disconnect count); adopted capabilities + replay_epoch reflected
  into the gateway entry.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified)* — app-level
  proof the M8 union-roster seam is constructible in the composition root over
  the registry + credential seams; two unreachable gateways classify offline
  without hanging, no crash, no throw, gateway entries preserved.

## 3. Design decisions (ADR-style)

1. **Refresh never throws for a gateway outage — it returns a snapshot.** The
   whole point of §31 Multi-Gateway is that one unavailable gateway does not
   break another. `refreshRoster()` returns a `FleetRosterSnapshot` whose
   `gatewayOutcomes` classify each gateway (loaded / failed with §13 status +
   non-secret detail); the caller inspects `reachableGateways` and `bots(on:)`
   to keep the Fleet screen useful when partially available (§13, §30).
2. **Per-gateway concurrency with non-throwing children.** Each gateway is
   refreshed in its own `withTaskGroup` child that catches and classifies its
   own failure — a failing gateway can neither cancel nor poison the others,
   and the refresh total time is bounded by the slowest gateway, not the sum.
3. **One socket per gateway: connectivity + roster combined.** M8's session
   unit (`GatewayRosterSession`) reuses the M3 connection for reachability and
   delegates `profiles.list` to the M2 roster client over that same transport,
   so aggregation never opens a second connection per gateway. Proven by the
   teardown test (transport terminal after refresh).
4. **Owning gateway is preserved by construction.** Bots are keyed by full
   `Route` (`GatewayID#ProfileSlug`) and stamped at ingest
   (`FleetBot.bot(on:descriptor:)`) — identical profile slugs on two gateways
   stay distinct and `bot(for:)` fails closed on ambiguity (spec §31, §36).
5. **The probe session is ALWAYS torn down** (ADR #3 carried from M7): every
   exit path of `refreshGateway` awaits `session.disconnect()` — success,
   classified connectivity failure, and roster-RPC failure alike (spec §31
   "disconnect does not crash"; tests assert transport terminal + disconnect
   count on both success and failure paths).
6. **Registry + credentials stay behind their M7 seams.** `FleetRosterService`
   depends only on `GatewayRegistryManaging` / `CredentialStoring` protocols —
   the concrete registry/Keychain wiring stays at the composition root.

## 4. Verified protocol contracts (source-grounded)

- `profiles.list` → `{"profiles": [ {name, path, is_default, model, provider,
  description, display_name, skill_count, has_avatar, last_session?...} ]}`
  — unchanged from M2 (`methods_profiles.py`); M8 only aggregates it per
  gateway. No new wire contract in M8.
- `gateway.ready` adoption (replay_epoch, heartbeat, change_events) — unchanged
  from M3; M8 reflects adopted capabilities + replay_epoch into the union
  roster gateway entry (server authoritative, spec §5.3).

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2. Ran via `bash m8_validate.sh`.

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **85 tests, 0 failures** (77 prior + 8 new FleetRosterDomainTests) |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors (1 pre-existing M1 `setLastInbound()` warning — untouched) |
| `swift test --package-path Packages/FleetNetworking` | **123 tests, 0 failures** (113 prior + 10 new FleetRosterServiceTests) |
| `xcodegen generate` | Regenerated; the development team present (4 hits); package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 19 tests, 0 failures** (18 prior + testFleetRosterSeamIsConstructibleInComposition) |
| Secrets scan (M8 sources) | No keys/tokens/passwords; fixture tokens are literal test values |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Multi-gateway evidence (in-process servers, no live node):
- 2 healthy gateways → union roster = 4 bots (2+2), both gateways loaded,
  owning gateway preserved per bot, routing `A/default` → A and `B/default` → B
  with correct per-gateway model ✓
- identical `default` slug on both gateways → 2 distinct bots, correct owners ✓
- 1 unreachable + 1 healthy → refresh does NOT throw; healthy gateway's bots
  present + routable; unreachable classified `.offline` ("gateway unreachable");
  `reachableGateways`/`unreachableGateways` split; gateway entry carries
  `.failed("offline")` ✓
- 1 authRequired + 1 healthy → `.authenticationRequired` on A, B still loads ✓
- 1 timeout + 1 healthy → `.offline` on A, B still loads ✓
- empty registry → empty snapshot, no throw ✓
- stored credential flows to the roster session factory ✓
- teardown: success path → transport terminal `.disconnected` after refresh;
  failure path → probe `disconnect()` count == 1 (ADR #3) ✓
- adopted ready metadata (capabilities heartbeat/change_events + replay_epoch)
  reflected into the union gateway entry ✓
- app composition: M8 seam constructible over registry + credential seams; two
  unreachable gateways → both classified offline, no crash, no throw ✓

## 6. Known limitations / handoff notes

- Per spec §31 Multi-Gateway this milestone is "before public v1, ideally
  during v0 dogfooding" — M8 delivers the service + tests; the Fleet screen UI
  wiring that renders `reachableGateways` / `bots(on:)` remains P6 (separate
  milestone, per BATCH AUTH scope).
- `refreshRoster()` opens a probe connection per registered gateway per call
  and tears it down (ADR #3). It does not maintain persistent multiplexed
  connections; live per-gateway transports for conversation remain owned by
  the per-gateway clients (M5/M6) — M8 is the fleet-view aggregation seam.
- Routing hardening (M9) and SwiftData registry persistence (P5) remain out of
  scope, as the sequencer directed.
- Operator follow-up (2026-08-29) recorded: M12/M13 acceptance reviews must
  independently re-verify M7's `GatewayRegistryService` teardown/close
  behavior since M7's final verdict was implementer-rendered. Noted on the
  board for the orchestrator; not re-opened here.

## 7. Out-of-scope respected

NO routing hardening (M9) · NO SwiftData persistence (P5) · NO UI wiring (P6) ·
NO live Hermes gateway connection · NO privileged Hermes operations. `FleetUI`
imports 0 `FleetNetworking` (structural guard preserved).
