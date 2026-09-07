# U1 App runtime + navigation shell — observable application runtime

**Task:** t_0cfc2610 · **Owner:** apple-dev (independent review: apple-qa)
**Board:** hermes-fleet-ios · **Date:** 2026-08-29 (CDT) · **Status:** Evidence recorded, handed to review.

## 1. Scope executed (per card body)

- Base: main@6207df4 (M15 head, later PASS head than 47cacef).
- Built the **observable application runtime** (`AppEnvironment`, FleetUI) composing:
  - `FleetRoster` / union roster data → `FleetRosterProviding` seam (`FleetRosterService` injected at root),
  - gateway registry → `GatewayRegistryManaging` seam (`GatewayRegistryService` injected at root),
  - single-gateway connection lifecycle → `GatewayConnectivityProviding` seam via `FleetConnectionFactory`
    (`SingleGatewayConnection` built at root; scripted in DEBUG/tests),
  - persistence cache → `CacheStoring` seam (`SwiftDataCacheStore` injected at root).
- **FleetUI has ZERO `import FleetNetworking`** — the M0 hard guard is preserved
  (verified structurally by `scripts/u1_validate.sh` §1 and by green `ModuleBoundaryTests`).
- Navigation shell: list-detail `NavigationStack` flow **Gateways → Bots → Sessions → Conversation**
  (`FleetScreen` typed destinations). Bots/Sessions/Conversation are skeleton screens — no bot-detail
  content, no conversation canvas (U2/U3 scope guard honored).
- Runtime owns the connection lifecycle: `connect` / `disconnect` / `reconnect` drive observable
  `connectionStates[gatewayID]` (idle / connecting / connected / disconnected / failed(status)).

## 2. Architecture

```
HermesFleetApp (app target = composition root; the ONLY module importing FleetNetworking)
  ├── FleetServiceGraph   builds registry/roster/cache/connection seams → injects into AppEnvironment
  ├── FleetSimulator      (DEBUG only) scripted fleet so the shell is walkable in the simulator
  └── HermesFleetApp      @main; @State AppEnvironment; .task { load(); refreshRoster() }

FleetUI (SwiftUI; imports FleetCore/FleetSecurity/FleetPersistence ONLY — never FleetNetworking)
  ├── AppEnvironment      @MainActor @Observable runtime + FleetConnectionFactory typealias
  ├── GatewayConnectionState  observable lifecycle vocabulary (§13)
  ├── FleetScreen         typed navigation destinations
  ├── FleetRootView       NavigationStack + navigationDestination
  ├── GatewaysView        registry list + per-row lifecycle controls (connect/disconnect/reconnect menu)
  ├── BotsView            roster bots for a gateway (fail closed)
  ├── SessionsView        skeleton (drill to Conversation; U2 fills session.list)
  └── ConversationView    placeholder (U3 canvas)
```

Seam pattern (unchanged from M0/M7/M8/M10): FleetUI depends on FleetCore **protocols**; the app
target wires the concrete FleetNetworking/FleetSecurity/FleetPersistence services. ModuleBoundaryTests
proves every seam stays constructible in the app context.

## 3. Test evidence (all green)

| Suite | Result |
|---|---|
| FleetCore package (swift test) | 123 tests, 0 failures |
| FleetNetworking package (swift test) | 151 tests, 0 failures |
| FleetSecurity package (swift test) | 20 tests, 0 failures |
| FleetPersistence package (swift test) | 15 tests, 0 failures |
| xcodebuild test (iOS Simulator, iPhone 17 Pro) | **36 tests, 0 failures** (All tests passed) |
| ModuleBoundaryTests (in app bundle) | 21 tests, 0 failures — boundary preserved |
| AppEnvironmentTests (new, U1) | 9 tests, 0 failures |

New U1 tests cover: load seeds + publishes gateways; seed only when registry empty; connect
`connecting → connected`; connect failure classifies `.offline`; disconnect safe before/after
connect; reconnect tears down then connects; connect-while-connected is a no-op (idempotent,
never flips to `.failed`); roster refresh publishes bots with owning-gateway
provenance; cache seam observable.

## 4. Simulator evidence (iPhone 17 Pro, iOS 26.5)

- Build/install/launch PASS via `xcrun simctl` (install + launch PID returned).
- Screenshot `build/u1-simulator-gateways.png`: app renders **"Hermes Fleet"** title, the two seeded
  gateways (**Workstation** / **Render Box**), per-row **Idle** status + ellipsis connect menu +
  refresh toolbar — Black/White/Signal Red theme from M14. The DEBUG scripted fleet makes every
  navigation destination (Gateways → Bots → Sessions → Conversation) reachable on a booted simulator.

## 5. Design decisions (review notes)

- **`AppEnvironment` lives in FleetUI**, not the app target: the runtime is what SwiftUI observes, and
  SwiftUI cannot import FleetNetworking — so the runtime holds FleetCore seams and the composition
  root injects concretes. This keeps the M0 guard structural, not just conventional.
- **`FleetConnectionFactory`** (FleetUI typealias) mirrors FleetNetworking's `GatewayConnectionFactory`
  but lives in FleetUI so the module has no transport import; the app root's closure returns
  `SingleGatewayConnection` in production and scripted connections in DEBUG/tests.
- **DEBUG scripted fleet** (`FleetSimulator.swift`): a live gateway isn't required to navigate the
  shell. Release (`makeProductionEnvironment`) wires real Keychain + SwiftData + live transports.
- **Connection lifecycle is observable** because the runtime drives it: after each async operation the
  runtime writes `connectionStates[id]`; SwiftUI re-renders from the `@Observable` runtime.
- **NO bot-detail content, NO conversation canvas** (U2/U3) — Sessions/Conversation are explicit
  placeholders, not stubbed UI pretending to be real.

## 6. Residual risk / carry-forward

- The Gateways screen connect menu drives the real transport in Release; without stored credentials the
  live gateway classifies offline/authRequired (correct §13 behavior). Credential entry UI is U2.
- The DEBUG fleet is a navigation/demo aid only and is compiled out of Release.
- XCUITest happy-path automation is scheduled in U4 (G1 debt), not U1.

— End of U1 evidence. No secrets, keys, or credentials recorded. —
