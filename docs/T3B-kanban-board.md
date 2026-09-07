# T3B Live read-only Kanban board (Hermex event-stream pattern)

**Task:** t_3b321b7b · **Owner:** apple-dev · **Board:** hermes-fleet-ios

Live, read-only Kanban board in the app: board changes stream into the phone
in real time, cards grouped by status, automatic reconnect with cursor
resume — the Hermex `KanbanEventStreamClient` pattern ported onto the stock
Hermes gateway's existing kanban surface.

## 1. Server surface (discovered, not modified)

The stock Hermes dashboard (`hermes serve` / `hermes dashboard` — the same
server that hosts `/api/ws`) already mounts the kanban plugin
(`plugins/kanban/dashboard/plugin_api.py`, verified live):

- `GET /api/plugins/kanban/board` → the full board grouped by status columns
  (`triage…done`), plus `latest_event_id` (the tail cursor) and `now`.
  Behind the dashboard's session middleware (`X-Hermes-Session-Token`
  header in loopback mode; login cookie in gated mode).
- `WS /api/plugins/kanban/events?since=<cursor>` → frames of
  `{"events":[{id,task_id,run_id,kind,payload,created_at}…],"cursor":N}` —
  a poll-tail over the append-only `task_events` table
  (`WHERE id > cursor`, 300ms cadence). The upgrade authorizes through the
  dashboard's canonical `_ws_auth_ok` gate: `?ticket=` (single-use,
  `POST /api/auth/ws-ticket`) or `?token=` (loopback) — exactly the
  credentials the app already mints for `/api/ws`.

**No gateway-side changes were needed** (out of scope per the card: no
schema or data-model changes; the read-side surface already exists).

## 2. Client architecture

| Layer | File | Responsibility |
|---|---|---|
| FleetCore | `KanbanBoard.swift` | `KanbanCard` / `KanbanBoardSnapshot` / `KanbanChangeEvent` / `KanbanEventBatch` domain values + the `KanbanBoardWatching` seam (read-only by construction — no mutation commands exist) + `KanbanBoardError` (non-secret) |
| FleetNetworking | `KanbanEventStreamClient.swift` | The Hermex-pattern client: `snapshot()` (HTTP board fetch, dual-auth: session-token header or login cookie), `changeEvents()` (WS tail with fan-out), `stop()`. Internal socket pump: connect → parse frames → advance cursor → fan out; on drop, exponential backoff (1s→15s cap) and reconnect with `since=<lastCursor>` so events missed in the gap are replayed. Uses the SAME `WebSocketSessionFactory` seam as the conversation transport (TOFU TLS pinning included) and the SAME `AuthenticationProviding` per gateway. |
| FleetUI | `KanbanBoardViewModel.swift` | `@MainActor @Observable` state: snapshot, stream phase (live/reconnecting/idle), recent events, error. ANY event batch triggers a coalesced (300ms) snapshot refetch — the dashboard web client's own pattern; the HTTP board is the single source of truth so client/server can never drift. 30s poll backstop while visible. |
| FleetUI | `KanbanBoardView.swift` | Read-only board (Gold Fleet tokens): per-status sections with horizontal card lanes, live-stream banner, recent-activity strip, honest empty/error/loading states, pull-to-refresh as recovery. No create/edit/move/delete affordances anywhere. |
| App | `FleetServiceGraph.swift` | Production `FleetKanbanWatcherFactory`: `KanbanEventStreamClient` with the per-gateway authenticator, strategy-appropriate HTTP credential, and the pinning-aware session factory. |
| App | `FleetSimulator.swift` | DEBUG scripted watcher (5 cards across 4 columns; `HERMES_FLEET_KANBAN_LIVE_UPDATES=1` enables a 3s event ticker for the live-update UI test). |
| FleetUI | `AppEnvironment` / `FleetScreen` / `FleetDashboardView` | `makeKanbanWatcher(for:)` accessor (fail-closed), `.kanban` destination, Home dashboard entry card. |

Board source: v1 picks the first connected gateway (else the first
registered) — single-gateway boards today; multi-gateway board selection is
a later phase (documented in the view).

## 3. Design decisions

1. **Events are signals, not state.** Any tail event → coalesced refetch of
   the HTTP board. The server's board endpoint is authoritative; the client
   never incrementally patches card state, so a missed/unknown event kind
   can never desync the view. (Mirrors the dashboard's own web client,
   verified in its bundle: `for (const e of msg.events) → scheduleReload()`.)
2. **Cursor resume, not blind reconnect.** The WS carries `since=<cursor>`;
   the server replays everything after it. The snapshot's
   `latest_event_id` seeds the cursor so stream + snapshot are aligned.
3. **One auth seam per gateway.** WS upgrades ride the existing
   `AuthenticationProviding` (ticket/loopback token); HTTP board fetches
   resolve per strategy (token header / fresh login cookie). No second
   credential path, no secrets in logs (`KanbanBoardError` is non-secret).
4. **Same socket seam as the transport.** `WebSocketSessionFactory`
   injection means kanban sockets enforce the gateway's TOFU SPKI pin,
   consistent with every other connection surface (T3 discipline).
5. **Read-only by construction.** The FleetCore seam has no mutation API;
   the view has no mutating controls. Enforced by UI test (no Add/move
   affordances) and by the domain type surface itself.

## 4. Tests (all passing)

- FleetCore `KanbanBoardDomainTests` — 3 (snapshot math, unknown column,
  non-secret errors).
- FleetNetworking `KanbanEventStreamClientTests` — 9: URL building
  (ws/wss/token/ticket/scheme rejection), frame parsing (valid/junk),
  snapshot decode + HTTP error + malformed body (URLProtocol mock), live
  stream delivery over the in-process WS fixture.
- App `KanbanBoardViewModelTests` — 5: start loads snapshot; live event
  triggers refetch (liveUpdateCount ≥ 1, recentEvents update); recent-events
  cap; error surfaces non-secret message; stop reaches the watcher.
- UI `KanbanBoardUITests` — 2 (deterministic, scripted fleet, in the CI
  selector list): entry → board renders columns + banner, no mutating
  controls; `HERMES_FLEET_KANBAN_LIVE_UPDATES=1` → activity strip appears
  with no manual refresh.

## 5. Live wire-contract evidence

`bash scripts/t3b_kanban_live_probe.sh` (committed) — spins a real
loopback `hermes serve`, then:

```
PROBE 1: GET /api/plugins/kanban/board → HTTP 200
  columns: [triage, todo, scheduled, ready, running, blocked, review, done]
  latest_event_id: 6996 → PASS (shape ok)
PROBE 2: WS /api/plugins/kanban/events?since=6996
  (insert real task via `hermes kanban --board default create`)
  frame cursor: 6997, events: 1, kinds: [created] → PASS
PROBE 3: since=999999999 → no events delivered at/behind cursor → PASS
ALL PROBES PASS
```

## 6. Known limitations (honest)

- Gated (OAuth) deployments: the HTTP board fetch uses the stored token
  header; if a deployment gates HTTP strictly behind OAuth cookies with no
  token path, the board surfaces a 401 error state (username/password
  gateways use the fresh-login cookie path). Not hit on Tony's LAN/tailnet
  setups.
- The board view picks the first connected gateway (single-gateway v1).
- Card detail drill-in is not in scope (read-only board only).
