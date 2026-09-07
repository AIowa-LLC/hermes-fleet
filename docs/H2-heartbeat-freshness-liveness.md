# H2 — Heartbeat-freshness liveness window (t_a07ca37e)

Stops spurious reconnects during long thinking/tool-call model turns while
keeping genuinely-dead connections detected inside the tiered windows.
Pattern adopted from Hermex #227 (`ChatStreamCoordinatorTiming`).

## Problem

The transport's inbound liveness check was a single flat deadline evaluated
after each ping cycle: silence past 45s ⇒ teardown. Two failure modes:

1. A long model turn (deep thinking, a tool executing server-side) can
   legitimately produce no content frames for tens of seconds. If the
   heartbeat pongs are not enough to satisfy a flat inbound deadline (or a
   status watcher reacts to a transient poll blip), the connection is torn
   down and the stream drops mid-turn — a spurious reconnect.
2. Conversely, anything that DID refresh the flat deadline kept the
   connection alive, with no notion of "provably alive, don't even poll".

## Design

One named constants type, one snapshot, one verdict — folded into the
existing RT3/P1-4 liveness evaluation instead of competing with it.

### Constants — `FleetCore.ConnectionLivenessTiming` (5 / 12 / 18 / 25)

| window | value | meaning |
|---|---|---|
| `checkingInterval` | 5s | active liveness check cadence (heartbeat loop tick) |
| `transportFreshInterval` | 12s | silence below this is PROVABLY alive — status polls skipped |
| `reconnectInterval` | 18s | silence at/after this ⇒ stale ⇒ teardown + reconnect |
| `runningToolReconnectInterval` | 25s | reconnect window while a tool call is mid-flight |

`transportFreshInterval` must sit above the server's ~5s heartbeat cadence
and below `reconnectInterval` (Hermex #227 invariant).

### Snapshot — `FleetCore.ConnectionLivenessSnapshot`

Immutable `lastFrameReceivedAt` instant; consumers derive the tier at read
time (`fresh` / `checkDue` / `stale`) so the snapshot never goes stale
itself. `toolInFlight` selects the extended reconnect window.

### Transport — `GatewayWebSocketTransport`

- `handleInbound` refreshes `lastInbound` (and the lock-boxed mirror) on any
  VALID protocol frame — heartbeat pongs AND payload events. Junk frames
  (binary / non-JSON-RPC text) still never refresh it (P1-4, unchanged).
- The heartbeat loop ticks at `checkingInterval` (5s; collapses to the ping
  interval when that is shorter), sends pings on their own cadence, then
  evaluates ONE verdict (`evaluateLiveness`):
  - `fresh` — provably alive, nothing to do;
  - `checkDue` — escalation is the active probe itself (the ping just sent);
  - `stale` — teardown with `.abnormalClosure`, i.e. the reconnect path.
- Tool-in-flight accounting: `tool.start` increments, `tool.complete` /
  `background.complete` decrement, `message.complete` drains (backstop for
  unpaired starts). Counter resets on connect.
- `TransportConfiguration.inboundDeadline` is now derived (max window);
  the legacy `inboundDeadline:` init maps a flat deadline onto equivalent
  tiered windows (fresh at half, stale at the deadline, no tool extension)
  so existing call sites/tests keep their exact teardown timing.

### Seam — `GatewayConnectivityProviding.liveness`

New protocol requirement with a `nil` default: providers backed by a real
transport surface the snapshot (nonisolated lock-box read — no actor hop);
test doubles/previews keep the previous behavior. Exposed through
`SingleGatewayConnection` and `GatewayConversationSession`.

### View model — status watcher poll gate

`ConversationViewModel.startStatusWatcher` skips the `session.status` poll
entirely while the snapshot tier is `fresh` (<12s silence). Nil liveness
keeps the previous always-poll behavior. The transport clears the snapshot
on teardown, so the gate reopens the instant a connection dies — a
freshness timestamp never vouches for a dead transport.

## Acceptance evidence

- `FleetCoreTests/ConnectionLivenessTests` — 6 domain tests: constants are
  exactly 5/12/18/25; fresh under 12s; checkDue 12..<18s (25s with tool);
  stale at 18s (25s with tool); elapsed math.
- `FleetNetworkingTests/TieredLivenessTransportTests` — 6 transport tests
  against the in-process WS server (compressed windows):
  - snapshot refreshes on heartbeat pong AND on payload frame;
  - slow turn (heartbeats flowing, no content frames past the reconnect
    window) stays connected — no teardown, connection count unchanged;
  - dead transport (no frames at all) still goes stale within the window
    (abnormal closure);
  - tool-in-flight extends the window (alive past 18s-equivalent, torn down
    at the 25s-equivalent);
  - binary junk flood still detected as dead (P1-4 unchanged).
- `ConversationViewModelTests` — 2 hosted VM tests: offline flip ignored
  while fresh, applied once silence ages past the fresh window; nil
  liveness keeps always-poll.
- `bash scripts/c1_ci_validate.sh` — PASS (see card metadata for lines).

## Out of scope (unchanged)

Server heartbeat interval (~5s) and wire format; reconnect/backoff policy
beyond the four windows; RT3 malformed-frame detection semantics.
