# M3 One-Gateway Connectivity

**Task:** t_d7c614f9 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa). M4 remains gated.

## 1. Scope (M3 only)

Per the authorized card (USER AUTHORIZED M3 at 2026-08-29) and synthesis §20 /
§22 mapping: compose M1 transport + M2 identity into **single-gateway
connectivity**. Built on M2 commit `8810c8e` in repo
the repository root.

Card scope line: *"connect one stock Hermes gateway, reachable/unreachable
state, disconnect-no-crash, gateway.ready adoption. Acceptance: spec §31
Gateway; no crash on disconnect."*

Deliverables:
- **`GatewayStatus`** (FleetCore) — spec §13 user-facing gateway states
  (Online / Connecting / Degraded / Authentication Required / Offline /
  Unsupported) derived from the transport seam's `TransportState`. This is the
  "reachable/unreachable state" the acceptance demands.
- **`GatewayReadyAdoption`** (FleetCore) — the `gateway.ready` handshake
  metadata (replay_epoch, heartbeat, change_events → capabilities) adopted
  after a successful connect.
- **`GatewayConnectivityProviding`** (FleetCore) — the M3 seam protocol +
  `GatewayConnectivityError`, mirroring `HermesTransport` / `RosterProviding`:
  FleetUI stays free of `FleetNetworking` (M0 guard preserved).
- **`SingleGatewayConnection`** (FleetNetworking) — actor composing one
  `FleetGateway` identity (M2) with one `GatewayWebSocketTransport` (M1):
  connect → adopt ready → expose `status`; idempotent, safe-from-any-state
  `disconnect()` (the "disconnect does not crash" acceptance).
- `GatewayWebSocketTransport.adoptedReady()` — additive accessor exposing the
  ready payload the transport already captured, so the connectivity layer can
  map it to `GatewayReadyAdoption`.

Explicitly NOT in M3: live Hermes gateway connection (tests use in-process
fixture servers, consistent with M1/M2), auth UX / credential storage
(FleetSecurity, later milestone), conversation RPCs (P3), reconnect/replay
(P4), persistence (P5), UI wiring (P6), multi-gateway aggregation (P7).

## 2. Files

### FleetCore (pure domain + seam)
| File | Responsibility |
|---|---|
| `GatewayStatus.swift` | spec §13 state vocabulary; `init(transportState:)`; failure-detail classifier (falls closed to `.offline`) |
| `GatewayReadyAdoption.swift` | adopted `gateway.ready` metadata (replay_epoch, heartbeat, change_events → capabilities) |
| `GatewayConnectivityProviding.swift` | M3 seam protocol + `GatewayConnectivityError` (unreachable / authRequired / unsupported / timeout / connectionFailed / invalidState) |

### FleetNetworking (transport + composition)
| File | Responsibility |
|---|---|
| `SingleGatewayConnection.swift` | `GatewayConnectivityProviding` actor: connect → ready adoption → `status`; idempotent disconnect; `currentGateway()` snapshot; transport→connectivity error mapping |
| `GatewayWebSocketTransport.swift` *(modified)* | added `adoptedReady()` accessor; `waitForReady()` now re-classifies a died-during-handshake socket as `connectionClosed(reason)` instead of a bare timeout (the M3 reachable/unreachable distinction) |

### Tests
- `FleetCoreTests/ConnectivityDomainTests.swift` — 8 tests: §13 vocabulary,
  transport-state mapping, failure classifier, `isReachable`, adoption
  capabilities/hash, error vocabulary.
- `FleetNetworkingTests/SingleGatewayConnectionTests.swift` — 10 tests:
  connect→ready→online, adoption surfaced on seam, `currentGateway()`
  metadata, unreachable→`unreachable`, silent→`timeout`, 4401→`authenticationRequired`,
  1000→`offline`, disconnect-before-connect / double-disconnect /
  disconnect-after-abnormal-close (no crash), second-connect rejection.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified)* — app-level
  proof that the M3 seam is constructible in the composition root and reports
  the expected offline start state + disconnect-no-crash, without touching UI.

## 3. Design decisions (ADR-style)

1. **Status is derived, never stored.** `SingleGatewayConnection.status` reads
   `transport.state` (nonisolated lock box) and maps through `GatewayStatus`,
   so a server-initiated close (4401/1000/1006) is reflected immediately
   without an extra event pipeline. No separate status field to drift.
2. **Ready adoption maps transport payload → FleetCore value.** The transport
   already captures `gateway.ready`; M3 exposes it via an additive accessor and
   `SingleGatewayConnection` converts it to `GatewayReadyAdoption`, keeping the
   transport module's wire types out of FleetCore/UI (M0 guard).
3. **`waitForReady()` classifies handshake death, not just timeout.** When the
   ready stream ends because the socket actually died (unreachable host, closed
   socket), the transport now re-throws `connectionClosed(reason)` instead of a
   bare `readyTimeout`; a still-open silent server still times out. This is the
   wire-level reachable-vs-unreachable distinction the acceptance names.
4. **Disconnect is idempotent and terminal.** `disconnect()` forwards to the
   M1 transport teardown, which writes terminal state exactly once; early /
   repeated / post-failure disconnect calls are safe no-ops. Proven by tests,
   not just asserted.
5. **Error mapping is a pure function.** `TransportError` / `DisconnectReason`
   → `GatewayConnectivityError` is a static mapping, so the UI-facing error
   vocabulary is testable without a live node.
6. **Tests against in-process servers, never a live node.** Consistent with
   M1/M2; `InProcessWebSocketServer` scripts ready/ping/close codes.

## 4. Verified protocol contracts (unchanged from M1/M2, source-grounded)

- `gateway.ready` payload (skin, change_events, heartbeat, replay_epoch) —
  `tui_gateway/ws.py:369-389`; adopted into `GatewayReadyAdoption`.
- Close codes 4400/4401/4403/4404/4408/1011 → typed reasons —
  `hermes_cli/web_server.py`.
- Ticket mint `POST /api/auth/ws-ticket` — `dashboard_auth/routes.py:932`.

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 ·
iOS 26.5 simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **30 tests, 0 failures** (22 prior + 8 new) |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors (pre-existing M1 `await setLastInbound()` warning not touched) |
| `swift test --package-path Packages/FleetNetworking` | **56 tests, 0 failures** (46 prior + 10 new) |
| `xcodegen generate` | Regenerated; the development team present (4 hits); package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED** (see evidence) |
| Secrets scan (M3 sources) | No keys/tokens/passwords; fixture token is a literal test value only |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Connectivity evidence (in-process servers, no live node):
- connect → `gateway.ready` → `status == .online`; adopted replay_epoch /
  capabilities surfaced on the seam ✓
- unreachable endpoint → `.unreachable` (socket died during handshake);
  silent server → `.timeout` ✓
- server close 4401 → `.authenticationRequired`; 1000 → `.offline`;
  1006 then disconnect → no crash, `.offline` ✓
- disconnect before connect / double disconnect → no crash, `.offline` ✓
- `currentGateway()` carries adopted capabilities + replay_epoch + authConfigured ✓

## 6. Known limitations / handoff notes

- Reconnect/replay (P4), conversation RPCs (P3), credential storage (P5) and UI
  wiring (P6) remain out of scope — `SingleGatewayConnection` is connectivity
  only; roster RPCs stay on the separate M2 `GatewayRosterClient`.
- The 1006-abnormal-close path is observed via the receive-loop failure; on
  some SDK paths URLSession flattens close codes, but the M1 delegate-captured
  raw-value path covers 44xx (verified).
- App target unchanged behaviorally apart from the new boundary test; nothing
  in the UI is wired to the seam yet (P6).

## 7. Out-of-scope respected

NO live Hermes gateway connection · NO auth/credential UX · NO conversation ·
NO reconnect/replay · NO persistence · NO UI wiring · NO multi-gateway
aggregation. `FleetUI` imports 0 `FleetNetworking` (structural guard preserved).
