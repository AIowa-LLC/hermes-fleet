# M2 Gateway/Bot Identity + Routing

**Task:** t_f679d107 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa). M3 remains gated.

## 1. Scope (M2 only)

Per the authorized scope (2026-08-29) and synthesis §20 Phase 2 — "Fleet
identity + roster": `GatewayID + ProfileSlug` identity, routing
(`Gateway + Profile`), and the roster RPCs `profiles.list` / `session.list`.
Built on M1 commit `236644f` in repo the repository root.

Deliverables per synthesis §20 P2:
- **`Route`** — canonical routing identity `(GatewayID, ProfileSlug)`; a bare
  slug or display name is never sufficient to address a bot (fail closed).
- **`GatewayRegistry`** — registered gateways keyed by `GatewayID`
  (id, display name, endpoint, connection state, capabilities, server
  identity, replay_epoch).
- **`FleetRoster`** — union roster across gateways preserving owning gateway;
  bots keyed by full `Route` so identical slugs on two gateways stay distinct.
- **`FleetBot` / `ProfileDescriptor` / `SessionSummary`** — the identity and
  wire DTO vocabulary (display name is never substituted for routing slug).
- **`GatewayRosterClient`** (FleetNetworking) — `profiles.list` / `session.list`
  over the M1 WebSocket JSON-RPC transport via a new `request(method:params:)`
  correlation method on `GatewayWebSocketTransport`.
- **`RosterProviding`** (FleetCore) — protocol seam so FleetUI can present the
  roster without importing FleetNetworking (M0 guard preserved).

Explicitly NOT in M2 (per authorization): live Hermes gateway connection,
conversation streaming, replay, persistence/auth UX, privileged operations,
PTY, multi-gateway aggregation beyond the domain model (P7), M3+.

## 2. Files

### FleetCore (pure domain)
| File | Responsibility |
|---|---|
| `Route.swift` | `(GatewayID, ProfileSlug)` routing identity; collision-free `id`; ordering |
| `GatewayRegistry.swift` | gateway registry (register/update/remove, fail-closed lookup) |
| `FleetRoster.swift` | union roster; bots keyed by `Route`; provenance preserved; fail-closed `bot(for:)` |
| `FleetBot.swift` | bot identity (route, display name, model/provider, activity, latest session) |
| `ProfileDescriptor.swift` | `profiles.list` row → domain (slug + display name split) |
| `SessionSummary.swift` | `session.list` / nested `last_session` row → domain |
| `RosterProviding.swift` | async seam protocol + `RosterError` |
| `FleetGateway.swift` *(modified)* | registry-entry fields added (defaulted; M0 call sites unchanged) |
| `HermesTransport.swift` *(modified)* | `TransportState` now `Hashable` (needed for `FleetGateway` hash) |

### FleetNetworking (transport)
| File | Responsibility |
|---|---|
| `GatewayWebSocketTransport.swift` *(modified)* | added `request(method:params:)` RPC correlation: synchronous continuation registration, timeout race via `failPending`, `.response`/`.error` resume, teardown fails all pending |
| `GatewayRosterClient.swift` | concrete `RosterProviding`; decodes `profiles.list` / `session.list` wire → FleetCore types; stamps `GatewayID` provenance |

### Tests
- `FleetCoreTests/RoutingCollisionTests.swift` — 14 tests: route identity
  distinctness (A/default vs B/default), fail-closed bare-slug lookup, display
  name never substituted, roster provenance, registry, DTO codable round-trips.
- `FleetNetworkingTests/RosterClientTests.swift` — 8 tests: transport RPC
  correlation (result / timeout / teardown-fail / not-connected), roster client
  decode, `session.list` profile-scoping, and a two-gateway routing-collision
  integration test (two in-process servers, same slug, distinct owners).

## 3. Design decisions (ADR-style)

1. **Route is the only address.** Every bot is addressed by an exact
   `(GatewayID, ProfileSlug)` pair. `FleetRoster.bot(for:)` returns exactly one
   bot or `nil`; there is no API that resolves a bare slug, so ambiguity fails
   closed by construction (spec §5.6, §36).
2. **Provenance stamped at ingest.** `profiles.list` rows carry no gateway
   identity; `FleetBot.bot(on:descriptor:)` attaches the calling transport's
   `GatewayID`, so aggregation can never lose the owning gateway (spec §12).
3. **Display name is presentation-only.** `ProfileDescriptor` keeps `name`
   (slug) and `displayName` separate; `resolvedDisplayName` is used for
   rendering, `name` for routing — never the reverse (spec §31 Profiles).
4. **RPC correlation via remove-and-resume continuation.** `request()` registers
   a `CheckedContinuation` synchronously on the transport actor, then a timeout
   task races it through `failPending`, which removes-and-resumes exactly once.
   Teardown fails every pending request with `connectionClosed`, so a dropped
   socket is a classification, never an endless await. A late response to a
   timed-out request is a no-op (id already removed).
5. **String request ids.** `rpc-N` ids (mirroring the heartbeat's `heartbeat-N`)
   keep the fixture server's string-keyed extraction and the correlation map
   consistent — numeric ids would echo back as strings and never correlate.
6. **Wire decoding is tolerant.** Unknown/missing fields default (`name`/`id`
   are required; everything else defaults), so older or extended gateway
   payloads degrade gracefully instead of failing the whole roster.
7. **Tests against in-process servers, never a live node.** Two
   `InProcessWebSocketServer` fixtures script `profiles.list` / `session.list`
   and a shared-slug collision; no Hermes connection is opened.

## 4. Verified protocol contracts (source-grounded)

- `profiles.list` → `{"profiles": [ {name, path, is_default, model, provider,
  description, display_name, skill_count, has_avatar, last_session?...} ],
  "bot_mode_protocol": true}` — `tui_gateway/methods_profiles.py:22-339`.
- `session.list` → `{"sessions": [ {id, title, preview, started_at,
  message_count, source} ]}`, scoped by `params.profile` (slug) + `params.limit`
  — `tui_gateway/methods_session.py:165-277`, `server.py:2314 _profile_db`.
- The transport's new `request()` reuses the M1 frame codec and heartbeat
  gating; string ids keep server-side id echo correlation working.

## 5. Validation record (2026-08-29, apple-dev, run 75)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 ·
iOS 26.5 simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors (1 pre-existing M1 warning: `await setLastInbound()` — not touched) |
| `swift test --package-path Packages/FleetCore` | **22 tests, 0 failures** (8 prior + 14 new) |
| `swift test --package-path Packages/FleetNetworking` | **46 tests, 0 failures** (38 prior + 8 new) |
| `xcodegen generate` | Regenerated; the development team present (4 hits); package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 11 tests, 0 failures** (FleetCoreLogic 5, ModuleBoundary 4 incl. `testNetworkingDependsOnCore`, AppComposition 2) |
| Secrets scan (M2 sources) | No keys/tokens/passwords; fixture token is a literal test value only |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/`; FleetNetworking imported only by app tests + its own tests |

Routing-collision evidence (in-process servers, no live node):
- `Route(A, default) != Route(B, default)`; `Set` dedupe = 2; `id` collision-free ✓
- Two gateways each serving a "default" profile → two distinct bots with correct
  owners; `roster.bot(for:)` returns the exact owner for each route ✓
- Bare-slug lookup impossible by construction; unknown-gateway route → `nil` ✓
- `profiles.list` decode (model/provider/display-name fallback) and
  `session.list` profile-scoping (`params.profile == "researcher"`) verified ✓
- `request()` result / timeout / teardown-fail / not-connected all verified ✓

## 6. Known limitations / handoff notes

- `request()` currently has no per-call cancellation cleanup beyond the timeout
  race (the detached send task and timeout task are not retained/cancelled on
  caller cancellation) — acceptable for M2 roster RPCs; revisit for P3
  conversation RPCs.
- No `session.active_list` yet (listed in synthesis P2 but not in the task's
  authorized scope line "profiles.list/session.list"); add in a later milestone
  if the fleet screen needs live-session backstop.
- No multi-gateway *aggregation service* yet — `FleetRoster` models the union,
  but driving N transports simultaneously is P7.
- App target and FleetUI unchanged behaviorally; nothing wired to the new
  types yet (P6).

## 7. Out-of-scope respected

NO live Hermes gateway connection · NO conversation streaming · NO replay · NO
persistence/auth UX · NO privileged operations · NO M3+. `FleetUI` imports 0
`FleetNetworking` (structural guard preserved). M3 remains gated.
