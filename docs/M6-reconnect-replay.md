# M6 Reconnect / Replay

**Task:** t_57cf698d · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa).

## 1. Scope (M6 only)

Per the authorized card (USER BATCH-AUTHORIZED M6–M15 at 2026-08-29) +
synthesis §20 Phase 4 mapping: **reconnect + replay engine** — per-session seq
watermarks, `session.events.since`, replay_epoch comparison, truncated refetch
`session.history`, replay-hold dedupe. Built on M5 commit `6f48cbe` in repo
the repository root.

Card scope line: *"reconnect+replay engine (per-session seq watermarks,
session.events.since, replay_epoch, truncated refetch session.history,
replay-hold dedupe). Acceptance: spec §31 Reconnect; reconnect suite per
synthesis §20 P4."*

SCOPE ADDITION (orchestrator, 2026-08-29): the **M1 P4 residual** (single-shot
ready handshake — reconnect after clean disconnect fails readyTimeout) is now
in scope; fixed as part of this work.

Deliverables:
- **Transport is re-connectable (M1 P4 residual fix).**
  `GatewayWebSocketTransport.connect()` may now be called again after a clean
  `disconnect()` (state `.closed`) AND after an abnormal close (state
  `.error`) — previously the ready-handshake channel was single-shot (finished
  at first teardown), so a reconnect iterated a finished stream and failed
  `readyTimeout`. The ready channel is now re-created per `connect()`; the
  inbound event channel lives for the transport's lifetime (reconnects
  included) so a reconnecting conversation client keeps its live subscription.
- **Per-session seq watermarks** (`SessionEventWatermark`, FleetCore). The
  transport tracks the highest observed `seq` per session id as events flow,
  persists them across disconnect, and never invents events (spec §9).
- **`session.events.since` client** (`GatewayReplayClient`, FleetNetworking).
  Wire contract verified against `tui_gateway/methods_session.py:3642` +
  `event_replay.py`: params `{session_id, last_seen}`; result
  `{events: [bare_event...], latest_seq, truncated, count, epoch}` where each
  bare event is the frame's `params` dict (`{type, session_id, seq, payload}`)
  — decoded via a new `GatewayEvent(replayParams:)` tolerant decoder.
- **Replay engine** (`GatewayReplayEngine`, FleetNetworking — implements
  `ReplayProviding`). The spec §9/§10 state machine: compare adopted
  replay_epoch → epoch match ⇒ `session.events.since(lastSeen)` per watermarked
  session, dedupe overlap (drop seq ≤ watermark), apply in order (inject back
  through the transport's live channel under replay-hold); truncated ⇒ refetch
  authoritative `session.history`; epoch changed ⇒ discard stale seq
  assumptions (clear watermarks) and rehydrate.
- **Replay-hold dedupe** in the transport. During a replay pass, inbound live
  frames are parked and flushed seq-gated: seq ≤ watermark are dropped
  (never duplicated), strictly-newer frames resume in order (spec §10).
- **Reconnect policy** (`ReconnectPolicy`, FleetNetworking). Pure close-code →
  decision mapping (spec §8.6): 4401 → re-mint ticket, NEVER silent retry;
  abnormal/going-away/server-error/TLS → reconnect; clean close / unsupported
  surface → do not auto-reconnect. The transport now also exposes
  `lastDisconnectReason` so the policy can be applied without re-deriving it.

Explicitly NOT in M6: registry (M7), session close/delete, persistence (P5),
UI wiring (P6), live Hermes gateway connection (tests use in-process fixtures).

## 2. Files

### FleetCore (pure domain + seams)
| File | Responsibility |
|---|---|
| `SessionEventWatermark.swift` | per-session (sessionID, lastSeenSeq) value |
| `ReplayOutcome.swift` | replay pass outcome per session (replayed / truncated / epochChanged / failed / nothingToReplay) |
| `ReplayProviding.swift` | M6 seam protocol + `ReplayError` vocabulary (watermarks + replayAfterReconnect) |

### FleetNetworking (transport + replay)
| File | Responsibility |
|---|---|
| `GatewayWebSocketTransport.swift` *(modified)* | re-connectable (M1 P4 fix); ready channel per connect; event channel for transport lifetime; watermark tracking; replay-hold + flush; `injectReplayedEvents`; `lastDisconnectReason`; session-scoped receive-failure guard; ENOTCONN → abnormalClosure classification |
| `GatewayEvent.swift` *(modified)* | `init?(replayParams:)` — decode bare `session.events.since` event objects |
| `GatewayReplayClient.swift` | `session.events.since` RPC + `ReplayBatch` decode |
| `GatewayReplayEngine.swift` | `ReplayProviding` actor: epoch compare, since-replay, dedupe, truncation→history, hold |
| `ReconnectPolicy.swift` | close-code → reconnect decision (4401 → re-auth, never silent retry) |

### Tests
- `FleetCoreTests/ReplayDomainTests.swift` — 5 tests: watermark value/equality,
  outcome equality + debug summary, replay error vocabulary.
- `FleetNetworkingTests/ReconnectReplayTests.swift` — 13 tests: the §36
  reconnect suite (socket close / timeout / network switch / duplicate replay /
  event gap / replay truncation / gateway epoch change) plus the M1 P4
  regression, policy mapping, replay client decode + params, and not-connected.
- `FleetNetworkingTests/InProcessWebSocketServer.swift` *(modified)* —
  multi-connection scripting (per-connection `Script`, `connectionCount`,
  `abortConnection()` abnormal-drop simulation) so reconnects are scriptable.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified)* — app-level
  proof the M6 replay seam is constructible in the composition root and
  classifies an unconnected transport as `.notConnected`.

## 3. Design decisions (ADR-style)

1. **The transport owns watermarks + replay-hold; the engine owns the replay
   protocol.** The transport is the single authoritative consumer of inbound
   frames (it already decodes every `GatewayEvent` and sees every `seq`), so
   it tracks watermarks and can park/replay-inject without a second subscriber
   (M5's single-consumer event channel stays intact). The replay engine sits
   above it and performs the spec §9 protocol (epoch compare, `since` RPCs,
   truncation → history) without touching the event channel.
2. **Reconnect is a first-class transport state, not a hack.** `connect()`
   accepts `.idle`, `.closed` and `.error`; the ready channel is re-created per
   connection; the event channel survives teardown. The M1 P4 residual
   ("reconnect after clean disconnect fails readyTimeout") is a regression test
   at the top of the reconnect suite, so it can never silently recur.
3. **`session.events.since` is a read-only, observation-only RPC.** The replay
   client issues exactly that one method (spec §5.4: replay observes; it never
   claims ownership of a session's live transport). The M6 path sends no
   mutating call.
4. **Truncation triggers an authoritative refetch, never an invention.**
   When the gateway reports `truncated` (a gap between the watermark and the
   ring's oldest retained seq was evicted), the engine refetches
   `session.history` via the M4 read client and reports `.truncated` — it does
   not fabricate the missing events (spec §9 "the client must not invent
   missing events").
5. **Epoch change ⇒ discard, don't guess.** A changed `replay_epoch` means the
   gateway restarted; in-process seq counters reset, so any stored watermark
   is meaningless. The engine clears watermarks and reports `.epochChanged` so
   the caller rehydrates from server state (§9.6).
6. **Best-effort per-session failures.** A failed `session.events.since` for
   one session is surfaced as `.failed` and retried on the next reconnect —
   it never fails the whole reconnect (§10 "best-effort replay retried later").
7. **Reconnect policy is a pure function, tested across every close code.**
   `ReconnectPolicy.decision(for:)` is static and fully unit-tested; 4401 is
   the one case that must NEVER silently retry with the same credential.

## 4. Verified protocol contracts (source-grounded)

- `session.events.since` params `{session_id, last_seen}` → result `{events,
  latest_seq, truncated, count, epoch}` — `methods_session.py:3642-3670`;
  `truncated` = `last_seen + 1 < buf[0][0]` (gap), `epoch` = server-process
  replay epoch (`event_replay.py:31,94`).
- `session.events.since` returns BARE event objects (each frame's `params`
  dict, top-level `type`/`session_id`/`seq`/`payload`) — NOT wrapped in a
  JSON-RPC envelope (`event_replay.py:78-91`).
- `gateway.ready` replay_epoch — `tui_gateway/ws.py:369-389` (already adopted
  in M3).
- Reconnect close codes (4401 = bad credential, etc.) — `CloseCodeMapping`
  (M1); `ReconnectPolicy` maps them (spec §8.6).

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift test --package-path Packages/FleetCore` | **59 tests, 0 failures** (54 prior + 5 new ReplayDomainTests) |
| `swift test --package-path Packages/FleetNetworking` | **90 tests, 0 failures** (77 prior + 13 new ReconnectReplayTests) |
| `xcodegen generate` | Regenerated; the development team present (4 hits); package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED, 15 tests / 0 failures** (14 prior + testReplaySeamIsConstructibleInComposition) |
| Secrets scan (M6 sources) | No keys/tokens/passwords; fixture tickets are literal test values |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Reconnect/replay evidence (in-process servers, no live node):
- **M1 P4 regression**: connect → disconnect → connect again succeeds (was
  `readyTimeout`); fresh connection observed (connectionCount == 2) ✓
- **socket close / network switch**: abnormal drop (no close frame) maps to
  `.abnormalClosure`, `lastDisconnectReason` surfaces it, policy says
  reconnect, transport recovers on a fresh connection ✓
- **timeout**: silent server → `readyTimeout`; retry hits the next (healthy)
  per-connection script and succeeds ✓
- **replay in order**: watermark 3 → reconnect → since returns seq 4,5 →
  replayed through the live channel in order, watermark → 5, original 1-3 not
  duplicated ✓
- **duplicate replay**: since returns overlap seq 1 + 2 → only 2 applied,
  overlap dropped ✓
- **replay truncation**: truncated batch → `session.history` refetched
  (recorded), outcome `.truncated`, watermark → latest_seq ✓
- **gateway epoch change**: epoch-A → epoch-B → watermarks cleared, outcome
  `.epochChanged` ✓
- **never invent**: since returns 5,7 (6 missing) → exactly 5,7 applied in
  order, no fabricated 6 ✓
- **not connected**: `replayAfterReconnect()` → `.notConnected` (no hang) ✓
- app composition: M6 replay seam constructible + unconnected classification ✓

## 6. Known limitations / handoff notes

- Replay is a foreground/connected-path concern (synthesis risk #6): on iOS
  suspension/background the reconnect happens when the app returns to the
  foreground. Background push is post-v0 (honest model).
- `session.events.since` buffers are bounded server-side (512 events /
  64 sessions, `event_replay.py`); truncation is expected after long gaps and
  is handled via history refetch.
- Registry (M7), persistence of watermarks across relaunch (P5), and UI wiring
  (P6) remain out of scope. Watermarks are in-memory per transport for now.

## 7. Out-of-scope respected

NO registry · NO session close/delete/undo · NO persistence (P5) · NO live
Hermes gateway connection · NO UI wiring · NO destructive ops. `FleetUI`
imports 0 `FleetNetworking` (structural guard preserved).
