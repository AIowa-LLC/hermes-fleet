# M4 Session Read Path (GATED)

**Task:** t_03682a39 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa). M5 remains gated.

## 1. Scope (M4 only)

Per the authorized card (USER AUTHORIZED M4 at 2026-08-29) and synthesis §20
Phase 2 mapping: **session read path** — `session.list` / `session.history` /
`session.status`, read-only. Built on M3 commit `7d1874b` in repo
the repository root.

Card scope line: *"session.list/history/status read-only; observation NEVER
implies ownership (no mutating calls from read screens). Acceptance: spec §31
sessions + §5.4; session-safety tests (read-only never mutates)."*

Deliverables:
- **`SessionMessageRole` / `SessionMessage`** (FleetCore) — the projected
  transcript row (`_history_to_messages`, `server.py:9296`): role, text,
  timestamp, row_id, display_kind, reasoning, tool name/context. Tolerant
  decoding (spec §5.5): unknown roles → `.unknown` preserving content, empty
  rows dropped.
- **`SessionHistory`** (FleetCore) — `session.history` value: session id +
  count + ordered messages. No mutating operations (spec §5.4).
- **`SessionStatus`** (FleetCore) — `session.status` value: authoritative raw
  text block (`{"output": ...}`, `methods_session.py:2775`) + best-effort
  parse of the documented lines (session id, model, provider, title, agent
  running) that falls back to `nil` per field (spec §5.5).
- **`SessionHistoryProviding`** (FleetCore) — the M4 seam protocol +
  `SessionHistoryError` (notConnected / malformedPayload / rpcFailed /
  sessionNotFound). Read-only BY CONSTRUCTION: the protocol exposes only
  `fetchSessionHistory` / `fetchSessionStatus` — no create/resume/interrupt/
  close/delete/undo, no prompt.submit. FleetUI stays free of FleetNetworking
  (M0 guard preserved).
- **`GatewaySessionHistoryClient`** (FleetNetworking) — concrete
  `SessionHistoryProviding` over the M1 transport `request()` correlation:
  sends ONLY `session.history` / `session.status`; maps 4001 "session not
  found" → `.sessionNotFound`, transport failures → `.rpcFailed`.

Explicitly NOT in M4: conversation streaming (M5), replay (M6), session
create/resume/interrupt (P3), persistence (P5), UI wiring (P6). The read path
never implies ownership; `session.list` stays on the M2 `RosterProviding`
client (unchanged).

## 2. Files

### FleetCore (pure domain + seam)
| File | Responsibility |
|---|---|
| `SessionMessage.swift` | `SessionMessageRole` (user/assistant/tool/system/unknown) + `SessionMessage` transcript row; `hasContent` includes tool metadata |
| `SessionHistory.swift` | `SessionHistory` value (session id, count, messages) |
| `SessionStatus.swift` | `SessionStatus` value; best-effort `parse(output:)` of the gateway's status text block |
| `SessionHistoryProviding.swift` | M4 seam protocol (read-only) + `SessionHistoryError` vocabulary |

### FleetNetworking (transport)
| File | Responsibility |
|---|---|
| `GatewaySessionHistoryClient.swift` | concrete `SessionHistoryProviding`: session.history / session.status decode; 4001 → sessionNotFound; transport error mapping |

### Tests
- `FleetCoreTests/SessionReadDomainTests.swift` — 11 tests: role vocabulary +
  tolerant decode, content detection (incl. reasoning-only and tool rows),
  row_id identity, history value/hash, status parse (typical / no-running /
  missing-fields / model-without-provider), error vocabulary.
- `FleetNetworkingTests/SessionHistoryClientTests.swift` — 8 tests:
  history decode (roles, tool, reasoning, unknown preserved, empty dropped),
  session_id param capture, 4001 → sessionNotFound, not-connected, status
  decode + caller fallback, malformed status → malformedPayload, and the
  **session-safety gate**: the full read path (history + status + M2
  roster reads) issues ONLY `{session.history, session.status, session.list,
  profiles.list}` — zero mutating calls.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified)* — app-level
  proof the M4 seam is constructible in the composition root and classifies an
  unconnected transport as `.notConnected` (no network, no mutation).

## 3. Design decisions (ADR-style)

1. **The seam is read-only by construction, not by convention.** The protocol
   (`SessionHistoryProviding`) literally has no mutating method — a screen
   driven by it cannot issue `session.create` / `session.resume` /
   `session.interrupt` / `session.close` / `session.delete` / `prompt.submit`
   even by accident. That is the structural form of spec §5.4 "Observation
   Must Not Imply Ownership" and §36 "read-only screens do not accidentally
   issue mutating calls". The session-safety test proves the wire behavior:
   the exact method set a full read pass sends is asserted to be a read-only
   whitelist.
2. **Wire decode is tolerant (spec §5.5).** Unknown roles decode to
   `.unknown` while preserving content (a newer gateway's "developer" row is
   never dropped and never fatal); only rows with no renderable content
   (empty text + no reasoning + no tool metadata) are dropped; status parsing
   is per-field best-effort — a changed or absent status line yields `nil`,
   never a failure.
3. **The gateway's raw status text is preserved verbatim.** `SessionStatus`
   keeps `rawOutput` so a faithful renderer exists even if the line format
   drifts; the parsed fields are an addition, never a lossy replacement.
4. **row_id is the durable message identity.** `SessionMessage.id` prefers the
   gateway's `row_id` (the persisted row address) and only synthesizes a
   role+timestamp+content key when absent — the client never invents a stable
   id that could collide with real addressing.
5. **4001 "session not found" is a classification, not a hang.** The upstream
   `_sess_nowait` returns 4001 when a session-scoped RPC hits a runtime id the
   gateway no longer holds (`server.py:3400`); the client maps it to
   `.sessionNotFound` so the UI can surface "refresh / session gone" instead
   of an opaque failure — and, per §5.4, does NOT auto-resume (resume is a
   mutating call reserved for explicit user action in a later milestone).
6. **Tests against in-process servers, never a live node.** Consistent with
   M1–M3; `InProcessWebSocketServer` scripts `session.history` /
   `session.status` payloads and records every inbound method for the safety
   gate.

## 4. Verified protocol contracts (source-grounded)

- `session.history` → `{"count": N, "messages": [...]}` where each message
  follows `_history_to_messages` (`server.py:9296-9399`): `{role, text,
  timestamp?, row_id?, display_kind?, reasoning?/reasoning_content?/
  reasoning_details?, ...}`; tool rows `{role:"tool", name, context, args?}`.
  Read-only: handler uses `_sess_nowait` (`methods_session.py:2780`,
  `server.py:3380`) — in-memory lookup, no activation, no resume.
- `session.status` → `{"output": "..."}` human-oriented text block
  (Session ID / Path / Title / Model / Created / Last Activity / Tokens /
  Agent Running) — `methods_session.py:2702-2775`. Read-only via
  `_sess_nowait`.
- `session.list` (M2, unchanged) → `{"sessions": [{id, title, preview,
  started_at, message_count, source}]}`, deny-lists `tool`/`kanban` sources —
  `methods_session.py:165-277`.
- 4001 "session not found" is a JSON-RPC error frame `{code, message}` —
  `server.py:2892 _err`, raised by `_sess_nowait` at `server.py:3400`.

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2.

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **41 tests, 0 failures** (30 prior + 11 new) |
| `swift build --package-path Packages/FleetNetworking` | Build complete, 0 errors (pre-existing M1 `await setLastInbound()` warning not touched) |
| `swift test --package-path Packages/FleetNetworking` | **64 tests, 0 failures** (56 prior + 8 new) |
| `xcodegen generate` | Regenerated; the development team present (4 hits); package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED** (see evidence) |
| Secrets scan (M4 sources) | No keys/tokens/passwords; fixture token is a literal test value only |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Session-read evidence (in-process servers, no live node):
- history decode: user/assistant/tool rows, reasoning-only turn kept, unknown
  role preserved with content, empty system row dropped ✓
- session_id param sent and captured on `session.history` ✓
- 4001 → `sessionNotFound`; unconnected → `notConnected`; malformed status →
  `malformedPayload` ✓
- status parse: typical block (session id/model/provider/title/running),
  no-running, missing fields → nil, model-without-provider ✓
- **session-safety gate**: full read pass (history + status + profiles.list +
  session.list) sent exactly `{session.history, session.status, session.list,
  profiles.list}` — no mutating call observed ✓
- app composition: M4 seam constructible + unconnected classification ✓

## 6. Known limitations / handoff notes

- `session.status` is text (the gateway's TUI-facing block). The client
  parses the documented lines best-effort; if Hermes later emits a structured
  status payload, `SessionStatus` gains a structured initializer without
  breaking the raw-text contract.
- Reasoning disclosure keys are read under three known aliases; a future key
  name degrades to nil reasoning rather than failing the history.
- Reconnect/replay (M6), conversation streaming (M5), session create/resume/
  interrupt (P3) and UI wiring (P6) remain out of scope.

## 7. Out-of-scope respected

NO conversation streaming · NO replay · NO session create/resume/interrupt ·
NO destructive ops · NO live Hermes gateway connection · NO persistence · NO
UI wiring. `FleetUI` imports 0 `FleetNetworking` (structural guard preserved).
