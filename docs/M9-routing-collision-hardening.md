# M9 Routing Collision Hardening

**Task:** t_6963e474 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa).

## 1. Scope (M9 only)

Per the authorized card (USER BATCH-AUTHORIZED M6–M15 at 2026-08-29;
SEQUENCER dispatch after M8 FINAL PASS commit `b3dbd29`) + synthesis §7
(Route = (gateway, profile) always) + §14 threat model ("path/session-key
traversal") + spec §5.6 (fail closed on ambiguity) + §31/§36 (routing tests):
**hardening of the routing layer against collision, ambiguity, and
path/session-key traversal.** Built on M8 commit `b3dbd29` in repo
the repository root.

Card scope line: *"collision-proof routing (Gateway A/default vs B/default
distinct), fail-closed on ambiguity, path/session-key traversal guards.
Acceptance: routing collision + traversal tests pass; apple-qa signs."*

The collision-proof core already existed from M2 (`Route` = full
`(GatewayID, ProfileSlug)` pair, `FleetRoster` keyed by route, `bot(for:)`
fail-closed) and M8 (union aggregation preserving owner). M9 adds the
**hardening surface** on top:

- **`RoutingGuard`** (FleetCore) — the single pure validator for routing keys.
  `isValidRouteComponent` rejects path separators, traversal segments, the
  `#` route-id separator, whitespace, and control characters; `isValidSessionKey`
  rejects separators / traversal / whitespace / control in `session_id` keys.
  This is the "path/session-key traversal guard" of the card and threat model.
- **`RouteResolution`** (FleetCore) + `FleetRoster.resolve(profileSlug:)` /
  `resolve(displayName:)` — the ONLY APIs that accept a bare slug / display
  name, and they never guess: `.notFound` / `.resolved(route)` /
  `.ambiguous([routes])` / `.invalid(reason)`. This is "fail closed on
  ambiguity" made explicit and testable (spec §5.6).
- **Fail-closed ingest** — `FleetRoster.setBots` and `upsertBot` drop
  descriptors/bots whose route is not routing-safe, so an unsafe slug from a
  malicious gateway never becomes a routable bot.
- **Fail-closed at the request boundary** (FleetNetworking) — the roster,
  conversation, history, and registry clients validate routes / session keys /
  gateway IDs BEFORE any RPC is sent (before the transport-state check), and
  surface typed errors (`RosterError.invalidRoute`,
  `ConversationError.invalidSessionKey`, `SessionHistoryError.invalidSessionKey`,
  `GatewayRegistryError.invalidGatewayID`).

Explicitly NOT in M9 (per BATCH AUTH + sequencer): persistence/cache (M10),
auth hardening (M11), SwiftData registry persistence (P5), UI wiring (P6).

## 2. Files

### FleetCore (pure domain)

| File | Change |
|---|---|
| `RoutingGuard.swift` *(new)* | `isValidRouteComponent` / `isValidSessionKey` — the M9 traversal guard |
| `Route.swift` | `init?(validating:)`, `isRoutingSafe`, doc notes |
| `GatewayID.swift` | `isRoutingSafe` |
| `ProfileSlug.swift` | `isRoutingSafe` |
| `FleetRoster.swift` | `resolve(profileSlug:)` / `resolve(displayName:)` + `RouteResolution` enum; `setBots`/`upsertBot` fail-closed ingest |
| `RosterProviding.swift` | `RosterError.invalidRoute` |
| `ConversationProviding.swift` | `ConversationError.invalidSessionKey` |
| `SessionHistoryProviding.swift` | `SessionHistoryError.invalidSessionKey` |
| `GatewayRegistryManaging.swift` | `GatewayRegistryError.invalidGatewayID` |

### FleetNetworking (request boundary)

| File | Change |
|---|---|
| `GatewayRosterClient.swift` | `fetchSessions(for:)` guards route safety before `session.list` |
| `GatewayConversationClient.swift` | guards `profile` slug (`session.create`) + `session_id` (resume/submit/interrupt) |
| `GatewaySessionHistoryClient.swift` | guards `session_id` (`session.history` / `session.status`) |
| `GatewayRegistryService.swift` | `addGateway` rejects unsafe gateway IDs |

### Tests

- `FleetCoreTests/RoutingGuardTests.swift` *(new, 14 tests)* — valid tokens,
  separator/traversal/`#`/whitespace/control rejection, session-key guards,
  `isRoutingSafe` surfaces, failable `Route(validating:)`, fail-closed ingest
  (`setBots` + `upsertBot`).
- `FleetCoreTests/RoutingCollisionTests.swift` *(+7)* — resolver ambiguity
  (A/default vs B/default → `.ambiguous` with both candidates), unique slug →
  `.resolved`, unknown → `.notFound`, unsafe slug → `.invalid`, display-name
  ambiguity never guesses.
- `FleetNetworkingTests/ConversationClientTests.swift` *(+6)* — unsafe/empty
  session key rejected before transport on resume/submit/interrupt; unsafe
  profile rejected on create; safe profile still checks connection.
- `FleetNetworkingTests/RosterClientTests.swift` *(+2)* — unsafe route
  rejected before transport; safe route still checks connection.
- `FleetNetworkingTests/SessionHistoryClientTests.swift` *(+2)* — unsafe
  session key rejected before transport on history/status.
- `FleetNetworkingTests/GatewayRegistryServiceTests.swift` *(+2)* — unsafe
  gateway ID rejected; host:port derived ID still accepted.

## 3. Design decisions (ADR-style)

1. **One pure validator, reused everywhere.** `RoutingGuard` lives in FleetCore
   (no platform/UI deps) and is the single source of truth for "what is a safe
   routing key". The value-type `isRoutingSafe` surfaces and the networking
   request-boundary guards all delegate to it, so the rule cannot drift between
   domain, ingest, and transport layers.
2. **`#` is the Route.id separator — components must never contain it.** Two
   routes like `a#b/c` and `a/b#c` would collapse to the same `id` string
   `a#b#c`, making the string id ambiguous. Rejecting `#` in components keeps
   `Route.id` collision-free by construction (the card's "collision-proof").
3. **Bare-slug resolution is the ONLY slug-only API, and it fails closed.**
   `resolve(profileSlug:)` returns `.ambiguous([routes])` when a slug exists on
   ≥2 gateways (A/default vs B/default), `.resolved` when exactly one,
   `.notFound` when none, and `.invalid` for an unsafe key — the caller never
   guesses which gateway owns a bare slug (spec §5.6, §31 Multi-Gateway).
4. **Guards fire before the transport-state check.** In every networking
   client the M9 guard precedes `guard case .connected` on purpose: an unsafe
   key must fail closed with the traversal error even when the transport would
   otherwise report not-connected. Proven by tests against a never-connected
   transport.
5. **Ingest is fail-closed.** `FleetRoster.setBots` (M2) AND `upsertBot` (the
   M8 aggregation path) both drop unsafe routes, so a gateway reporting a
   traversal slug cannot inject it into the union roster.
6. **Derived gateway IDs remain valid.** `GatewayID(endpoint:)` produces
   `host:port` tokens (e.g. `127.0.0.1:8642`) which contain dots and a colon
   but no `..` — `isValidRouteComponent` accepts them (tested), so the M9
   registry guard does not break endpoint-derived IDs.

## 4. Verified protocol contracts (source-grounded)

- No new wire contract. M9 is client-side defense-in-depth over the M2–M8
  verified contracts: `profiles.list`, `session.list` (profile-scoped),
  `session.create`/`resume`, `prompt.submit`, `session.interrupt`,
  `session.history`/`status` — the guards reject unsafe keys BEFORE the RPC
  params are built, so no malformed request ever reaches the gateway.
- The server remains authoritative (spec §5.3); these guards are the client's
  first line, not a substitute for gateway-side validation.

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2. Ran via `bash m9_validate.sh`
(PASS=9 FAIL=0).

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **106 tests, 0 failures** (85 prior + 21 new) |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors (1 pre-existing M1 `setLastInbound()` warning — untouched) |
| `swift test --package-path Packages/FleetNetworking` | **135 tests, 0 failures** (123 prior + 12 new) |
| `xcodegen generate` | Regenerated; the development team present; package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 19 tests, 0 failures** (app + module-boundary composition, unchanged by M9) |
| Secrets scan (M9 sources) | No keys/tokens/passwords; fixture tokens are literal test values |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Hardening evidence:
- `Route(A, default) != Route(B, default)`; both resolve distinct bots; the new
  resolver returns `.ambiguous([A/default, B/default])` for the bare slug —
  never a guessed owner ✓
- traversal keys rejected at every boundary: `Route(validating:)` nil for
  `../x` / `a/b` / `a#b`; `setBots`/`upsertBot` drop unsafe slugs; fetchSessions/
  resume/submit/interrupt/history/status throw typed errors BEFORE transport;
  `addGateway` rejects unsafe gateway IDs ✓
- valid keys unaffected: `researcher`, `apple-dev`, `192.168.50.58:8642`
  (derived endpoint ID) all pass; safe-route/safe-key calls still hit the
  connected-state path ✓
- existing M2/M8 routing-collision + union-roster tests still green (no
  regression) ✓

## 6. Known limitations / handoff notes

- Guards are client-side. A malicious gateway that itself serves a traversal
  slug is dropped from the client roster (fail-closed ingest), but the gateway
  still controls its own namespace — the server remains authoritative.
- `resolve(displayName:)` matches exact display-name equality; case/whitespace
  normalization of display names is out of scope (presentation-only).
- M10 persistence and M11 auth hardening remain gated per the sequencer.

## 7. Out-of-scope respected

NO persistence/cache (M10) · NO auth hardening (M11) · NO SwiftData registry
persistence (P5) · NO UI wiring (P6) · NO live Hermes gateway connection (tests
use in-process fixtures) · NO privileged Hermes operations. `FleetUI` imports 0
`FleetNetworking` (structural guard preserved).
