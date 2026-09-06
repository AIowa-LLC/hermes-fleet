# M5 Conversation Streaming (GATED)

**Task:** t_23e280be · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa). M6 remains gated.

## 1. Scope (M5 only)

Per the authorized card (USER AUTHORIZED M5 at 2026-08-29) and synthesis §20
Phase 3 mapping: **conversation streaming** — `session.create` / `session.resume`
/ `prompt.submit` / `session.interrupt` plus streamed turn-event rendering
(`message.*`, `tool.*`, `status.*`, `thinking/reasoning.*`, `message.complete`).
Built on M4 commit `2a71cf7` in repo the repository root.

Card scope line: *"session.create/resume, prompt.submit, render
message/tool/status/thinking/reasoning events, message.complete, interrupt.
Acceptance: spec §31 Conversation; fixtures + streaming."*

Deliverables:
- **`ConversationEvent`** (FleetCore) — the typed streamed-turn vocabulary
  (`messageStart/Delta/Interim/Complete`, `thinkingDelta`, `reasoningDelta`,
  `reasoningAvailable`, `statusUpdate`, `toolStart/Generating/Progress/Complete`,
  `backgroundComplete`, `sessionInfo`, `error`, `unknown`). Pure domain value;
  tolerant by construction (spec §5.5: unknown types preserved, never fatal).
- **`ConversationSession`** (FleetCore) — `session.create` / `session.resume`
  result value (`session_id`, `stored_session_id`, message_count, messages via
  the shared `SessionMessage` projection, best-effort model/provider/profile).
- **`PromptSubmission`** (FleetCore) — `prompt.submit` result (`{"status":
  "streaming"}` contract).
- **`InterruptResult`** (FleetCore) — `session.interrupt` result
  (`{"status": "interrupted"}` + optional `turn_isolation`).
- **`ConversationProviding`** (FleetCore) — the M5 MUTATING seam protocol +
  `ConversationError` vocabulary. Deliberately separate from the M4 read-only
  `SessionHistoryProviding` (spec §5.4: observation never implies ownership) —
  a read-only screen structurally cannot reach this seam.
- **`GatewayEvent.EventType`** (FleetNetworking) — extended with the
  conversation vocabulary so streamed turn events route by type.
- **`GatewayWebSocketTransport.subscribeToEvents()`** (FleetNetworking) — an
  inbound event channel yielding every decoded `GatewayEvent` in order
  (unbounded buffering), finished on teardown.
- **`GatewayConversationClient`** (FleetNetworking) — concrete
  `ConversationProviding`: `session.create` / `session.resume` / `prompt.submit`
  / `session.interrupt` over the M1 transport `request()` correlation; maps
  4001 and 4007 ("session not found", both the `_sess_nowait` and the
  `session.resume` DB-lookup paths) → `.sessionNotFound`, 4006 →
  `.invalidRequest`, transport failures → `.rpcFailed`; `events` maps the
  transport event channel onto the domain.

Explicitly NOT in M5: reconnect/replay (M6), registry (M7), session close/delete
(P3 excludes destructive ops), persistence (P5), UI wiring (P6). The mutating
seam is explicit-user-action only — no implicit ownership claim.

## 2. Files

### FleetCore (pure domain + seam)
| File | Responsibility |
|---|---|
| `ConversationEvent.swift` | Typed streamed-turn vocabulary incl. `.unknown` preservation (§5.5) |
| `ConversationSession.swift` | session.create/resume result value |
| `PromptSubmission.swift` | prompt.submit result (`status: "streaming"`) |
| `InterruptResult.swift` | session.interrupt result (+ turn_isolation) |
| `ConversationProviding.swift` | M5 mutating seam protocol + `ConversationError` vocabulary |

### FleetNetworking (transport)
| File | Responsibility |
|---|---|
| `GatewayEvent.swift` *(modified)* | `EventType` extended with message/tool/status/thinking/reasoning/background/session-info vocabulary |
| `GatewayWebSocketTransport.swift` *(modified)* | inbound event channel (`subscribeToEvents`), yields all events, finished on teardown |
| `GatewayConversationClient.swift` | concrete `ConversationProviding`: create/resume/submit/interrupt + event mapping + error mapping |

### Tests
- `FleetCoreTests/ConversationDomainTests.swift` — 13 tests: event vocabulary
  equality/hashable, message delta/complete (success + error status),
  thinking/reasoning/status, tool start/generating/progress/complete,
  background/error, session-info, unknown preserved, session value + hashable,
  prompt streaming, interrupt result, error vocabulary.
- `FleetNetworkingTests/ConversationClientTests.swift` — 13 tests: create
  params + decode (incl. seed messages), resume param + decode, 4007 → notFound,
  4006 → invalidRequest, submit prompt params + decode, 4001 → notFound,
  interrupt params + decode, all-RPC not-connected, **full turn streaming in
  order** (start → delta×2 → status → thinking → reasoning → tool.start →
  tool.complete → complete), **failed-turn error complete** (status:"error" +
  error event), **unknown event tolerated**, and the **conversation-path safety
  gate**: the mutating seam issues EXACTLY {session.create, session.resume,
  prompt.submit, session.interrupt} and the event subscription issues zero RPCs.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified)* — app-level proof
  the M5 mutating seam is constructible in the composition root over the same
  transport and classifies an unconnected transport as `.notConnected`.

## 3. Design decisions (ADR-style)

1. **The mutating seam is a separate protocol, not an extension of the read
   path.** `ConversationProviding` is deliberately disjoint from
   `SessionHistoryProviding` — the M4 read seam exposes no create/resume/submit/
   interrupt, and the M5 seam exposes no history/status. A read-only screen
   driven by the read seam structurally cannot seize the transport (spec §5.4);
   the conversation-path safety test proves the wire behavior: the mutating
   path sends exactly the four explicit user-action methods.
2. **`prompt.submit` is a fire-and-stream RPC.** The gateway returns
   `{"status": "streaming"}` immediately and streams the turn over the event
   channel; `submitPrompt` returns that acknowledgement while `events` carries
   the stream. The client never fabricates a completion it didn't observe.
3. **Streamed events are tolerant to the wire (spec §5.5).** Unknown event
   types surface as `.unknown` with their raw type preserved (a newer gateway's
   `moa.*` / `pet.*` event is recorded, not dropped, not fatal); tool args are
   carried as compact JSON text and `nil` when unencodable; a missing payload
   member defaults rather than failing the stream.
4. **`gateway.ready` is a handshake, not a conversation event.** It is dropped
   from the conversation event mapping (the transport consumes it for its own
   ready handshake) so the turn stream is exactly the turn's events.
5. **Error codes are classified, not opaque.** 4001 and 4007 "session not found"
   and 4006 "session_id required" map to typed `.sessionNotFound` /
   `.invalidRequest` (verified in the gateway source: 4001 comes from
   `_sess_nowait` `server.py:3400` for prompt.submit / session.interrupt, 4007
   from the `session.resume` handler's own DB lookup `methods_session.py:543`),
   so the UI can render "session gone / resume again" instead of a generic
   failure; transport failures map to `.rpcFailed`.
6. **Tests run against in-process servers, never a live node.** Consistent with
   M1–M4; `InProcessWebSocketServer` scripts `session.*` / `prompt.submit`
   responses and pushes streamed event frames, and the safety gate records every
   inbound method.

## 4. Verified protocol contracts (source-grounded)

- `session.create` → `{session_id, stored_session_id?, message_count, messages,
  info: {model?, provider?, profile_name?}}` — `methods_session.py:14` (returns
  lightweight session immediately; agent builds in the background).
- `session.resume` → same envelope; requires `session_id` (else 4006), 4007 when
  the session is unknown (its own DB lookup — `methods_session.py:543`) —
  `methods_session.py:374`.
- `prompt.submit` → `{"status": "streaming"}` immediately; params
  `{session_id, text}` — `methods_prompt.py:287-934`.
- `session.interrupt` → `{"status": "interrupted"}` (+ `turn_isolation` on the
  compute-host path) — `methods_session.py:3329`.
- Event frames: `{"jsonrpc":"2.0","method":"event","params":{"type":T,
  "session_id":sid,"payload":{...}}}` — `server.py _event_frame`/`_emit`.
  Payloads verified: `message.start` (no payload), `message.delta` `{text,
  rendered?}`, `message.interim` `{text, already_streamed?}`, `message.complete`
  `{text, status?, error?, ...}` (status "error" on failure), `thinking.delta`
  `{text}`, `reasoning.delta` `{text, verbose?}`, `reasoning.available` `{text,
  verbose?}`, `status.update` `{kind, text}`, `tool.start` `{tool_id, name,
  context?, args?}`, `tool.generating` `{name}`, `tool.complete` `{tool_id,
  name, args, result?, summary?}`, `background.complete` `{task_id, text}`
  (`methods_prompt.py:1359`), `session.info` (rich metadata incl. model/provider/
  profile_name).

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift test --package-path Packages/FleetCore` | **54 tests, 0 failures** (41 prior + 13 new ConversationDomainTests) |
| `swift test --package-path Packages/FleetNetworking` | **77 tests, 0 failures** (64 prior + 13 new ConversationClientTests) |
| `xcodegen generate` | Regenerated; the development team present (4 hits); package references intact; pbxproj unchanged by regen |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED, 14 tests / 0 failures** (13 prior + testConversationSeamIsConstructibleInComposition) |
| Secrets scan (M5 sources) | Clean (only doc-comment word "tokens", no credentials) |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Conversation evidence (in-process servers, no live node):
- create: title/profile/model/provider/cols params captured; session_id +
  stored_session_id + model/provider/profile_name decoded; seed messages
  decoded via the shared projection ✓
- resume: session_id param captured; 4007 → sessionNotFound (unknown stored
  session, matches the real gateway `methods_session.py:543`); 4006 →
  invalidRequest ✓
- submit: session_id + text captured; `{"status":"streaming"}` → isStreaming;
  4001 → sessionNotFound ✓
- interrupt: session_id param; `{"status":"interrupted"}` → isInterrupted ✓
- not-connected: all four RPCs classify `.notConnected` (no hang) ✓
- **full turn streamed in order**: message.start → delta×2 → status.update →
  thinking.delta → reasoning.delta → tool.start → tool.complete →
  message.complete (9 events, typed) ✓
- **failed turn**: message.complete {status:"error", error} + error event ✓
- **unknown event** (`moa.reference`) preserved as `.unknown`, not fatal ✓
- **conversation-path safety gate**: full mutating pass (create+resume+submit+
  interrupt) sent exactly {session.create, session.resume, prompt.submit,
  session.interrupt} — zero read-only, zero privileged/destructive calls ✓
- app composition: M5 mutating seam constructible + unconnected classification ✓

## 6. Known limitations / handoff notes

- The transport event channel (`subscribeToEvents`) is single-consumer (one
  conversation client per gateway). The client stores its mapped stream at init;
  a second subscriber on the same transport would split events. Composition root
  wires one conversation client per gateway.
- `session.create` builds the agent in the background; a `session.info` event
  typically follows and is surfaced via the stream (rendered as metadata).
- `message.complete` with `status == "error"` is the terminal frame for failed
  turns; the UI should treat it as the turn's end and surface `error`.
- Reconnect/replay (M6), registry (M7), session close/delete, persistence (P5)
  and UI wiring (P6) remain out of scope.

## 7. Out-of-scope respected

NO reconnect/replay · NO registry · NO session close/delete/undo/activate ·
NO persistence · NO live Hermes gateway connection · NO UI wiring · NO
destructive ops. `FleetUI` imports 0 `FleetNetworking` (structural guard
preserved).
