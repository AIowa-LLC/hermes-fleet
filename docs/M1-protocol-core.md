# M1 Protocol Core — FleetNetworking WebSocket JSON-RPC Transport

**Task:** t_cf3f507b · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa / apple-release). M2+ remain gated.

## 1. Scope (M1 only)

Per the authorized scope and synthesis §20 Phase 1 — "Protocol core":

- **FleetNetworking** newline-delimited JSON-RPC 2.0 frame codec
  (`JSONRPCCodec`), verified against `tui_gateway/ws.py` wire shapes.
- **URLSessionWebSocketTask transport seam** (`WebSocketSession` protocol +
  concrete `URLSessionWebSocketSession` with a delegate to observe close codes).
- **Connection state machine** (`ConnectionState` + `GatewayWebSocketTransport`
  actor): `idle → connecting → open → closed|error`, mapping onto FleetCore's
  `TransportState`.
- **`gateway.ready` handshake** handling — adopted heartbeat flag + replay_epoch.
- **Heartbeat** — 15s `gateway.ping` / 45s inbound-deadline behavior, gated on
  `gateway.ready.payload.heartbeat` (configurable for fast tests).
- **Close-code/error mapping** (`CloseCodeMapping`): 4400/4401/4403/4404/4408/
  1011 + standard codes → typed `DisconnectReason`.
- **Short-lived WS ticket mint REST client seam** (`WSTicketClient` for
  `POST /api/auth/ws-ticket` → `{ticket, ttl_seconds}`, header
  `X-Hermes-Session-Token`).
- **Fixtures / in-process test server** (`InProcessWebSocketServer`, Network
  framework RFC6455) proving connect/ready/heartbeat/close-code mapping without
  any live Hermes node.

Explicitly NOT in M1 (per authorization): live Hermes gateway connection,
profiles/session routing, conversation RPCs, replay engine, persistence/auth UX,
privileged operations, PTY. `FleetUI` does not import `FleetNetworking`
(structural guard preserved).

## 2. Files

New in `Packages/FleetNetworking/`:

| File | Responsibility |
|---|---|
| `Sources/FleetNetworking/JSONRPCCodec.swift` | `JSONValue`, `JSONRPCID`, request/response/error/event types, single-frame + newline-delimited stream codec |
| `Sources/FleetNetworking/GatewayEvent.swift` | Typed `gateway.ready` view (heartbeat, change_events, replay_epoch, skin) + event type enum |
| `Sources/FleetNetworking/CloseCodeMapping.swift` | Raw close-code/error → `DisconnectReason` mapping |
| `Sources/FleetNetworking/WSTicket.swift` | `WSTicket`, `WSTicketMinting` protocol, `WSTicketClient` (REST) |
| `Sources/FleetNetworking/WebSocketSession.swift` | `WebSocketMessage`, `WebSocketSession` seam, `URLSessionWebSocketSession` (delegate-captured close codes), factory |
| `Sources/FleetNetworking/ConnectionState.swift` | `ConnectionState`, `TransportConfiguration` (15s/45s/15s/120s), `TransportStateBox` |
| `Sources/FleetNetworking/GatewayWebSocketTransport.swift` | `HermesTransport` actor: connect→ready→heartbeat→close mapping, URL building |
| `Tests/FleetNetworkingTests/InProcessWebSocketServer.swift` | In-process RFC6455 WebSocket server fixture (scripted) |
| `Tests/FleetNetworkingTests/JSONRPCCodecTests.swift` | codec round-trips, framing, parse tolerance |
| `Tests/FleetNetworkingTests/CloseCodeMappingTests.swift` | close-code → reason table + error mapping |
| `Tests/FleetNetworkingTests/WSTicketClientTests.swift` | ticket REST client (URLProtocol mock) |
| `Tests/FleetNetworkingTests/GatewayWebSocketTransportTests.swift` | connect/ready/heartbeat/close-code integration vs in-process server + URL building + state machine |

`Package.swift`: added `FleetNetworkingTests` test target. `ModulePlaceholder`
kept (app `ModuleBoundaryTests` still references it).

## 3. Verified protocol contracts (source-grounded)

- `gateway.ready`: `{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":...,"change_events":true,"heartbeat":true,"replay_epoch":...}}}` — `tui_gateway/ws.py:369-389`.
- `gateway.ping` → `{"jsonrpc":"2.0","result":{"ok":true},"id":<echo>}` — `tui_gateway/ws.py:474`.
- Close codes: 4400 invalid channel, 4401 bad credential, 4403 host mismatch / chat-disabled gate, 4404 chat disabled, 4408 peer not allowed, 1011 internal — `hermes_cli/web_server.py:16584,17501-17532`.
- Ticket mint: `POST {base}/api/auth/ws-ticket` (header `X-Hermes-Session-Token`, cookie `hermes_session_at`) → `{ticket, ttl_seconds}` TTL 30 — `hermes_cli/dashboard_auth/routes.py:932`, `ws_tickets.py`.

## 4. Design decisions (ADR-style)

1. **Actor transport + lock box for observable state.** `GatewayWebSocketTransport`
   is an actor; `HermesTransport.state` is `nonisolated` via `TransportStateBox`
   (`OSAllocatedUnfairLock` — `NSLock` is unavailable from async contexts).
2. **AsyncStream ready handshake.** `gateway.ready` is delivered to `connect()`
   through an `AsyncStream` rather than a stored continuation, avoiding
   cross-isolation mutation; `connect()` races it against the connect timeout.
3. **Close codes via delegate, mapped by raw integer.** `URLSessionWebSocketTask`
   async `receive()` throws without the close code; a delegate captures
   `didCloseWith` and `CloseCode.rawValue` preserves 44xx, so mapping goes
   through `CloseCodeMapping.reason(forRawCode:)`.
4. **Idempotent teardown.** Only the first teardown writes terminal state, so a
   late receive-loop failure can't clobber the classified close reason.
5. **Heartbeat gated on ready flag.** Client mirrors the reference client — no
   ping loop unless `gateway.ready.payload.heartbeat == true`; inbound deadline
   checked every ping interval.
6. **Tests against an in-process server, never a live node.** No live Hermes
   connection anywhere in M1; `InProcessWebSocketServer` scripts `gateway.ready`,
   ping echo, and close codes.

## 5. Validation record (2026-08-29, apple-dev, run 71)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 ·
iOS 26.5 simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetNetworking` | **38 tests, 0 failures** (host) — codec 12, close-code 10, ticket 5, transport 11 |
| `swift test --package-path Packages/FleetCore` | **8 tests, 0 failures** (host, unchanged) |
| `xcodegen generate` | Regenerated; team ID present (4 hits); package references intact |
| `xcodebuild ... build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild ... test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 11 tests, 0 failures** (FleetCoreLogic 5, ModuleBoundary 4 incl. `testNetworkingDependsOnCore`, AppComposition 2) |
| Secrets scan | No keys/tokens/passwords in FleetNetworking sources; header name only, no values |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/`; FleetNetworking imported only by app target + its own tests |

Transport integration evidence (in-process server, no live node):
- connect → `gateway.ready` → state `.connected` ✓
- ready timeout (no ready frame) → `.readyTimeout`, never left connected ✓
- heartbeat: repeated `gateway.ping` observed by server while open; zero pings
  when `ready.heartbeat == false`; stale (no inbound) → abnormal closure ✓
- close 4401 → `reauthenticationRequired`; close 1000 → clean end ✓
- URL building: `http://host:9119` → `ws://host:9119/api/ws?ticket=…`; https→wss ✓

## 6. Known limitations / handoff notes

- Close codes are observed via the URLSession delegate; `URLSessionWebSocketTask`
  flattens some non-standard codes to `.invalid` only if no raw value is carried —
  verified 44xx survives via `rawValue` on this SDK (test `testCloseCodeEnumRawValuePreserves44xx`).
- No reconnect/replay yet (P4), no conversation RPCs (P3), no PTY (P5), no
  cookie-based ticket auth (header path only in M1), no persistence/Keychain (P5).
- Heartbeat intervals are configurable; production defaults are 15s/45s/15s/120s.
- App target unchanged apart from regenerated project; no UI wired to the
  transport yet (P6).

## 7. Out-of-scope respected

NO live Hermes gateway connection · NO profiles/session routing · NO
conversation · NO replay · NO persistence/auth UX · NO privileged operations ·
NO M2+. `FleetUI` and the app target unchanged behaviorally; transport is
test-only in M1.
