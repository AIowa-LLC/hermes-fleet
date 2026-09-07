# U3 Conversation screen — streaming, replay, reconnect UX

**Task:** t_011f64e1 · **Owner:** apple-dev (independent review: apple-qa)
**Board:** hermes-fleet-ios · **Date:** 2026-08-29 (CDT) · **Status:** Evidence recorded, handed to review.

## 1. Scope executed (per card body)

Base: main@836f456 (U2 FINAL PASS head). Built the **Conversation screen** over
the U1/U2 runtime, data through FleetCore seams only:

- **Open/create a session** — `session.create` (new conversation) / `session.resume`
  (existing session) via the M5 mutating seam, surfaced from Bot-detail's session
  list (and a New-Conversation entry point on the canvas).
- **Send prompts** — `prompt.submit` (returns `{"status":"streaming"}` immediately).
- **Render streamed events incrementally (M5)** — `message.start` → `message.delta`
  → `message.complete` plus `tool.*`, `status.update`, `thinking/reasoning.*`,
  `background.complete`, `session.info` all render into the transcript as they
  arrive (assistant bubble accumulates deltas, typing indicator while streaming).
- **message.complete** — finalizes the assistant row with the authoritative text;
  `status == "error"` marks the row failed and surfaces the error.
- **Interrupt** — `session.interrupt` stops a running turn (Stop button).
- **Reconnect → replay hydration (M6)** — on a mid-stream socket drop the screen
  goes `.disconnected` (partial transcript preserved); an explicit Reconnect runs
  the M6 `replayAfterReconnect` (epoch compare → `session.events.since` →
  replay-hold → seq-gated flush), shows a "Reconnected · replayed N missed
  events" notice, and the replayed tail flows back into the live transcript —
  **dedupe visible in the UI** (no duplicated assistant rows/text).
- **Re-auth UX on 4401 (M11 — no silent retry)** — a 4401 close surfaces
  `.authRequired` with an explicit "Re-authenticate" button; the view model NEVER
  auto-reconnects after 4401 (connect count proven unchanged in tests), and
  re-auth mints a fresh ticket.
- **Persisted history via FleetPersistence (M10) for cold-start** — on opening an
  existing session, cached history is hydrated immediately (offline/relaunch shows
  the last transcript, `hydratedFromCache`), then authoritative server messages
  supersede it; the transcript is persisted back to the cache after each turn.

## 2. Architecture

```
HermesFleetApp (app target = composition root; the ONLY module importing FleetNetworking)
  ├── FleetServiceGraph   + makeConversationFactory → GatewayConversationSession per gateway
  ├── FleetSimulator      (DEBUG) + ScriptedConversationSession (walkable canvas)
  └── HermesFleetApp      @main; @State AppEnvironment

FleetCore (pure domain + seams)
  ├── ConversationSessionProviding  NEW — U3 bundle: connectivity + conversation + replay
  │                                  + history over ONE transport + reauthenticate() (M11)
  └── ConversationEvent              + sessionID accessor + isTurnTerminal helper

FleetNetworking (concrete services)
  └── GatewayConversationSession  NEW — ConversationSessionProviding over one transport
      (SingleGatewayConnection + GatewayConversationClient + GatewayReplayEngine +
       GatewaySessionHistoryClient share ONE socket; seq watermarks + event channel coherent)

FleetUI (SwiftUI; imports FleetCore/FleetSecurity/FleetPersistence ONLY — never FleetNetworking)
  ├── ConversationViewModel  NEW — @Observable: phase / transcript / isStreaming /
  │                           replayNotice / authRequired / cold-start hydration
  ├── ConversationView       REAL canvas (was U1 placeholder): transcript + composer +
  │                           Stop/interrupt + reconnect/replay banner + 4401 re-auth UX
  ├── AppEnvironment         + conversationFactory seam + conversationSession(for:) +
  │                           makeConversationViewModel(route:sessionID:)
  ├── FleetScreen            conversation(Route, sessionID: String?) — nil = create new
  └── FleetRootView          passes environment into ConversationView
```

Seam pattern unchanged: FleetUI depends on FleetCore protocols; the app target
wires the concrete FleetNetworking services. `ModuleBoundaryTests` proves the new
seam stays constructible in the app context.

## 3. Test evidence (all green)

| Suite | Result |
|---|---|
| FleetCore package (swift test) | 123 tests, 0 failures |
| FleetNetworking package (swift test) | 157 tests, 0 failures |
| FleetSecurity package (swift test) | 20 tests, 0 failures |
| FleetPersistence package (swift test) | 15 tests, 0 failures |
| xcodebuild test (iOS Simulator, iPhone 17 Pro) | **All tests passed** |
| ModuleBoundaryTests | 23 tests, 0 failures (incl. new `testConversationSessionSeamIsConstructibleInComposition`) |
| ConversationViewModelTests (U3, new) | 10 tests, 0 failures |
| ConversationFixtureLoopTests (U3, new) | 2 tests, 0 failures |

### ConversationViewModelTests (scripted seams, deterministic)

Cover: create + resume paths (connect count, phase, authoritative messages
supersede cache); connect failure classification; **incremental streaming render**
(start → deltas → complete, isStreaming transitions); failed-turn
(`message.complete status:"error"` marks row failed + surfaces error); interrupt
stops streaming; **cold-start cache hydration** (M10 — cached transcript rendered,
`hydratedFromCache` true); **reconnect runs replay + shows notice**;
**replay dedupe visible in transcript** (partial turn → forced offline → reconnect
→ replayed tail arrives — exactly ONE assistant row, no duplicated prefix,
notice "Reconnected · replayed 1 missed event"); **4401 re-auth UX no silent
retry** (status → `.authRequired`, connect count UNCHANGED, explicit
re-authenticate drives a fresh connect + replay); **replay truncation / epoch
change refetch authoritative history** (M4 seam).

### ConversationFixtureLoopTests (REAL transport + shared in-process gateway fixture)

The U3 acceptance centerpiece, hosted on the iOS simulator against the SHARED
`InProcessWebSocketServer` (compiled into the app test bundle from the
FleetNetworking test target — single source of truth):

- **Full loop with forced disconnect mid-stream**: connect → `session.create` →
  `prompt.submit` → connection 1 streams `message.start(seq1)` / `message.delta
  "Hel"(seq2)` / `message.delta "lo"(seq3)` → the test ABORTS the socket
  mid-stream (before `message.complete`) → view model detects the drop →
  `.disconnected`, partial assistant row preserved → explicit Reconnect opens
  connection 2 → `replayAfterReconnect` runs `session.events.since(last_seen=3)`
  → replayed `seq4 " world"` + `seq5 message.complete "Hello world"` are
  injected back through the live channel → the UI transcript completes to
  **"Hello world" with exactly ONE assistant row and the "Hello" prefix appearing
  exactly once** (seq ≤ watermark dropped) → `replayNotice == "Reconnected ·
  replayed 2 missed events"`.
- **Reconnect with nothing missed**: clean "Reconnected · nothing new" notice.

## 4. Design decisions (review notes)

1. **`ConversationSessionProviding` bundles everything over ONE transport.**
   Mirrors the M8 `GatewayRosterSession` pattern: connectivity + M5 conversation +
   M6 replay + M4 history share the same `GatewayWebSocketTransport`, so seq
   watermarks, the streamed event channel and replayed-event injection stay on a
   single socket — replay dedupe is coherent by construction, and `reauthenticate()`
   (M11) is the one explicit re-auth entry point.
2. **The view model is fully observable and seam-driven.** `ConversationViewModel`
   (@MainActor @Observable) renders phase / transcript / isStreaming / replayNotice /
   authRequired from the FleetCore seams only; SwiftUI never imports the transport
   module (M0 guard preserved, verified by grep + ModuleBoundaryTests).
3. **Replay hydration is explicit + visible.** A mid-stream drop keeps the partial
   transcript and shows a Reconnect banner; reconnecting runs the M6 engine and
   surfaces the outcome ("replayed N missed events") — the acceptance's "replay
   dedupe visible in UI" is proven by the fixture loop test asserting a single,
   non-duplicated assistant row after forced drop + reconnect.
4. **4401 is surfaced, never silently retried (M11).** The status watcher maps a
   `.authenticationRequired` close to `.authRequired`; the test asserts the
   connect count does not change, and only the explicit "Re-authenticate" button
   drives `reauthenticate()` (fresh ticket).
5. **Cold-start history is honest (M10).** Cached transcript renders immediately on
   open (offline/relaunch), flagged `hydratedFromCache`; authoritative
   create/resume messages supersede it when they arrive; the transcript persists
   back to the cache after each turn so the next cold start has the latest view.
6. **The in-process gateway fixture is SHARED, not duplicated.** The app test
   bundle compiles the same `InProcessWebSocketServer.swift` file the networking
   suite uses (project.yml source reference), so hosted fixture tests exercise the
   REAL transport + REAL conversation session against a scripted gateway — no
   live Hermes node, no divergent fixture copy.

## 5. Residual risk / carry-forward

- Reconnect is currently user-explicit (the banner's Reconnect button), matching
  the "show replay hydration" UX; an auto-reconnect policy could be layered on in
  a later milestone without changing the seams.
- The DEBUG scripted conversation session streams a canned turn; Release wires the
  real `GatewayConversationSession` (same seams, live gateway).
- XCUITest happy-path automation remains scheduled in U4 (G1 debt).

— End of U3 evidence. No secrets, keys, or credentials recorded. —
