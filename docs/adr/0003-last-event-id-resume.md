# ADR-0003 — Last-Event-ID resume semantics for gateway WS conversation streams

- **Status:** Accepted (t_8401d3c3; card doc `docs/H1-last-event-id-resume.md`)
- **Source:** card t_8401d3c3 (Hermex-inspired backlog); Hermex reference
  snapshot `/tmp/hermex-inspect` (`SSEClient.lastEventID` tracking +
  `ChatStreamCoordinator` snapshot/restore).
- **Related:** `docs/M6-reconnect-replay.md`, ADR-0002 (RT1 replay hold),
  gateway `tui_gateway/event_replay.py`, `methods_session.py`.

## Context

A reconnecting gateway WebSocket conversation stream must resume from the
client's last received event — no lost tokens, no replayed flood. The gateway
ALREADY stamps every per-session event with a monotonic `seq`
(`event_replay.py: _stamp_event`, one counter per session id, assigned under
a lock at emit time) and implements server-side replay:
`session.events.since(session_id, last_seen)` returns the missed tail from a
bounded ring (512 events / 64 sessions), flagging `truncated: true` when the
range was evicted. The M6 layer (transport watermarks + `GatewayReplayEngine`)
consumes that contract after reconnects.

What was missing (the card's real gap): the CONVERSATION layer dropped `seq`
entirely — `ConversationEvent` had no event id, the conversation client never
sent `last_seen` on (re)subscribe, a mid-stream gap on a LIVE connection was
invisible (silently applied the jumping tail), and the only unrecoverable-gap
signal (`.truncated` on `ReplayOutcome`) lived on the reconnect path, not the
conversation seam.

## Decision

**Both halves, one seq space — client-side no-gap validation + the existing
server-side gap replay, chosen over server-side subscribe-time filtering.**

The card allowed either (a) server replays only after the client's
lastEventID on reconnect, or (b) the client validates the resumed stream has
no gap. We implemented (b) as the client mechanism, layered on the already
existing (a) wire contract — because the server half (`session.events.since`)
was already implemented and battle-tested in the gateway, and the residual
risk was precisely the client trusting whatever arrived.

1. **Every conversation event carries the per-stream event id.** The
   top-level `seq` (sibling of `payload` in the event params) is threaded
   through `GatewayConversationClient.decodeEvent` into every
   `ConversationEvent` case (`seq: Int?`, default nil — unstamped events are
   tolerated and classified `.unknown`, never fatal).
2. **The client tracks its own last APPLIED event id (cursor).** The view
   model advances `lastAppliedEventID` only when an event is rendered —
   distinct from the transport watermark (highest observed). Applied-vs-
   observed is the distinction that makes gap detection exact at the layer
   that renders.
3. **The cursor travels on (re)subscribe.** `resumeSession(lastEventID:)`
   includes `last_seen` in the `session.resume` params. Verified wire-safe:
   `methods_session.py` reads only known keys and ignores extras. When the
   server adopts resume-time filtering, this same field becomes the filter
   with no client change.
4. **Client-side no-gap validation at apply time.** Each inbound event is
   classified against the cursor: `contiguous` (apply), `duplicate` (drop —
   this is the dedupe gate that makes RT1 replay-hold injections and the
   live tail compose without double renders), `gap` (recover), `unknown`
   (unstamped/foreign — apply, pre-existing behavior).
5. **Gap recovery reuses the server replay RPC.** `resumeEvents(since:
   sessionID:)` (new `ConversationProviding` requirement) issues
   `session.events.since` from the CLIENT cursor and re-applies the tail in
   order. `truncated: true` ⇒ throw the explicit
   `ConversationError.gapUnrecoverable(sessionID:afterEventID:)` — never a
   partial batch. The caller surfaces an integrity notice and refetches
   authoritative `session.history` (dropping the stale cursor).

## Consequences

- Zero lost / zero duplicated events is enforced at the layer that renders,
  on BOTH resume paths (reconnect replay AND live-stream gaps).
- RT1 composition: RT1's replay-hold dedupe (transport, seq ≤ watermark
  dropped) and this cursor gate (conversation, seq ≤ cursor dropped) are the
  same rule at two layers — enabling both cannot drop a new event (both gates
  pass strictly-newer frames) and cannot duplicate (either gate catches the
  overlap). Existing RT1/ReconnectReplay tests unchanged and green.
- `session.resume` gains an (ignored-today) `last_seen` param — forward
  compatible with a future server-side subscribe filter.
- Evidence: `LastEventIDResumeTests` (5 tests, incl. the disconnect-mid-
  stream exact-resumption proof and the truncated ⇒ gapUnrecoverable proof)
  and `ConversationViewModelTests` gap tests (recovered-exactly, duplicate-
  dropped, unrecoverable ⇒ history refetch).

## Rejected alternatives

- **Porting Hermex SSEClient wholesale** — out of scope by card; only the
  lastEventID tracking + resume-point-declaration pattern was adopted.
- **Server-side subscribe-time replay filtering** — would require gateway
  changes; the ring + `events.since` already provide replay, and the client
  validation catches gaps the reconnect path misses (live-stream drops
  without a socket close, partial-server edge cases).
- **Sparse-batch tolerance** (the old `testReplayNeverInventsMissingEvents`
  behavior — apply {5,7} after 3 silently) — now classified as a GAP at the
  conversation layer and recovered or surfaced. NOTE for RT1 merge: RT1's
  branch retains the old sparse-batch test at the transport layer; the
  transport still applies exactly what the ring returns (never invents), and
  the conversation layer's validation is what now catches sparse tails.
