# U2 Roster + Bot detail + Gateway management screens

**Task:** t_36584ef2 · **Owner:** apple-dev (independent review: apple-qa)
**Board:** hermes-fleet-ios · **Date:** 2026-08-29 (CDT) · **Status:** Evidence recorded, handed to review.

## 1. Scope executed (per card body)

Base: main@d0b7220 (U1 FINAL PASS head). Built the U2 fleet-facing screens over
the U1 runtime, data through FleetCore seams only:

- **Gateways screen** — full registry management over the M7
  `GatewayRegistryManaging` seam: registry list, **add** (sheet: display name,
  endpoint, auth strategy, optional token), **edit** (display name / endpoint /
  strategy), **remove** (swipe + context menu), **test connection**
  (reachable/unreachable per spec §13 — observable `testingGatewayIDs` →
  `testResults[id]` → §13 status badge; a classified failure is stored, never
  thrown), and **auth config entry** per M7 (strategy + save/clear credential —
  Keychain only, the secret never transits the UI model).
- **Bots roster** — the fleet-wide union roster (`FleetRosterView`): M8 union
  aggregation rendered with **per-gateway grouping** (one section per gateway)
  and **partial-outage resilience states** (an unreachable gateway renders its
  classified §13 status + non-secret detail as an outage section while the
  reachable gateways' bots stay visible — spec §31/§30). The per-gateway
  `BotsView` drill also renders its gateway's outage state (not a silent empty).
- **Bot detail** — identity `Route` display (canonical `gateway#slug`, never a
  display name), status (model/provider, activity, latest session), and the
  sessions list via the read-only `session.list` **`SessionListProviding`**
  seam (new FleetCore protocol + `GatewaySessionListService` concrete in
  FleetNetworking). Loading / empty / classified-error / populated states.
- Scope guard honored: **NO conversation screen (U3)** — `ConversationView`
  remains the placeholder canvas; tapping a session drills to it unchanged.

## 2. Architecture

```
HermesFleetApp (app target = composition root; the ONLY module importing FleetNetworking)
  ├── FleetServiceGraph   builds registry/roster/sessionList/cache/connection seams
  ├── FleetSimulator      (DEBUG) scripted fleet + ScriptedSessionListService + outage gateway
  └── HermesFleetApp      @main; @State AppEnvironment

FleetCore (pure domain + seams)
  ├── SessionListProviding  NEW — read-only session.list seam (spec §5.4 observation-only)
  └── RosterError            + .gatewayNotFound (fail closed, M9)

FleetNetworking (concrete services)
  └── GatewaySessionListService  NEW — SessionListProviding actor; resolves route → gateway
      from registry, connects, session.list, tears down on EVERY exit path (ADR #3)

FleetUI (SwiftUI; imports FleetCore/FleetSecurity/FleetPersistence ONLY — never FleetNetworking)
  ├── AppEnvironment       + updateGateway / testConnection / save+clearCredential /
  │                        hasCredential / loadSessions + observable testResults,
  │                        testingGatewayIDs, sessionsByRoute, loadingRoutes, sessionReadErrors
  ├── FleetScreen          bots(gateway) / roster / botDetail(route) / conversation
  ├── GatewaysView         registry management + add/edit/remove/test/auth sheets
  ├── GatewayFormSheet     add/edit (strategy + optional token)
  ├── GatewayAuthSheet     auth strategy + save/clear credential (Keychain-safe)
  ├── FleetRosterView      union roster grouped per gateway + partial-outage states
  ├── BotsView             per-gateway drill w/ outage state
  ├── BotDetailView        identity Route + status + sessions via session.list
  └── (SessionsView removed — superseded by BotDetailView)
```

Seam pattern unchanged: FleetUI depends on FleetCore protocols; the app target
wires the concrete FleetNetworking/FleetSecurity/FleetPersistence services.
`ModuleBoundaryTests` proves every seam stays constructible in the app context.

## 3. Test evidence (all green)

| Suite | Result |
|---|---|
| FleetCore package (swift test) | 123 tests, 0 failures |
| FleetNetworking package (swift test) | **157 tests, 0 failures** (151 prior + 6 new `GatewaySessionListServiceTests`) |
| FleetSecurity package (swift test) | 20 tests, 0 failures |
| FleetPersistence package (swift test) | 15 tests, 0 failures |
| xcodebuild test (iOS Simulator, iPhone 17 Pro) | **All tests passed** |
| ModuleBoundaryTests | 22 tests, 0 failures (incl. new U2 `session.list` seam constructible in composition) |
| AppEnvironmentTests | 18 tests, 0 failures (9 prior + 9 new U2 view-model tests) |

New U2 view-model tests cover: gateway update/remove observables; test
connection reachable (online) / classified-unreachable (offline, never thrown) /
absent-gateway notFound; auth config save+clear observable (`authConfigured`,
`hasCredential`); Bot-detail `loadSessions` success + classified read error;
union roster partial availability (one reachable + one unreachable → healthy
bots stay, failed gateway classified `.offline`, no throw).

`GatewaySessionListServiceTests` (FleetNetworking): happy path over the
in-process WS fixture server with ADR #3 teardown asserted on the transport;
unknown gateway → `.gatewayNotFound`; unsafe route → `.invalidRoute` (M9, before
any RPC); connect failure → `.notConnected`; probe teardown on success AND
failure paths (disconnect count == 1).

## 4. Simulator evidence (iPhone 17 Pro, iOS 26.5, DEBUG scripted fleet)

Ran via `bash scripts/u2_validate.sh` — **PASS=22 FAIL=0**.

- `build/u2-simulator-gateways.png` — Gateways screen: 3 seeded gateways
  (Lab Node / Render Box / Workstation), endpoints, Idle badges, Add / Roster /
  Refresh toolbar, M14 theme.
- `build/u2-simulator-roster.png` — Fleet Roster (DEBUG `HERMES_FLEET_AUTO_NAV
  =roster`): per-gateway sections; **Lab Node unreachable** outage section
  ("Unreachable" + "gateway unreachable") while Render Box (Default) and
  Workstation (Default, Researcher) bots remain listed — the spec §31 partial
  availability state renders.
- `build/u2-simulator-bot-detail.png` — Bot detail (DEBUG auto-nav =bot-detail):
  Identity section (Route `render-box#default`, Gateway, Profile), Status
  (Model hermes·nous, Activity, Latest session "Fleet setup"), Sessions section
  listing "Fleet setup" (6 messages · ios · timestamp) via `session.list`.
- `build/u2-simulator-dynamic-type.png` — Dynamic Type sanity at
  accessibility-extra-extra-extra-large: gateway rows are left-aligned and
  fully readable (display names wrap vertically, no horizontal clipping). This
  drove an M14 a11y fix: `ViewThatFits(in: .horizontal)` gives the gateway row
  a compact variant at AX sizes (status icon instead of text badge) so text
  yields to controls instead of overflowing off-screen.

## 5. Design decisions (review notes)

- **`SessionListProviding` is a new FleetCore seam**, not a method bolted onto
  `FleetRosterProviding`: Bot detail's read path mirrors M4's read-only
  philosophy and stays structurally unable to mutate a session (spec §5.4 /
  §36). The concrete `GatewaySessionListService` reuses the M8
  `GatewayRosterSessionFactory` and the ADR #3 teardown invariant.
- **testConnection is observable, not thrown**: `testResults[id]` + a §13
  status badge give the reachable/unreachable acceptance (spec §31) without a
  live connect; the absent-gateway case still throws `.notFound` (fail closed).
- **Auth entry never holds the secret**: the add/edit/auth sheets pass
  `GatewayCredential` by value straight to `saveCredential`; SecureField state
  is cleared on save; nothing is logged (spec §16/§29).
- **`SessionsView` was removed**, superseded by `BotDetailView` (identity +
  status + sessions). The navigation case was renamed `.sessions(route)` →
  `.botDetail(route)`.
- **DEBUG auto-nav hook** (`HERMES_FLEET_AUTO_NAV`) is evidence-capture only:
  it drives the shell to the roster / first bot detail on launch for
  screenshots. Compiled out of Release; never a product feature.
- **Dynamic Type a11y gate (M14)**: the gateway row got a `ViewThatFits`
  compact variant so the display name never clips at AX sizes.

## 6. Residual risk / carry-forward

- The roster/bot-detail screenshots use the DEBUG scripted fleet + auto-nav;
  Release renders the same views against live gateway data.
- XCUITest happy-path automation remains scheduled in U4 (G1 debt).
- Conversation canvas is U3 (unchanged placeholder).

— End of U2 evidence. No secrets, keys, or credentials recorded. —
