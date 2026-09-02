# H1 — Last-Event-ID resume semantics for gateway WS conversation streams

**Task:** t_8401d3c3 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete; local CI gate PASS=9 FAIL=0; handed to
apple-qa.

## Scope

Card t_8401d3c3: a reconnecting gateway WebSocket conversation stream
resumes from the client's last received event — zero lost tokens, zero
replayed flood, explicit signal on unrecoverable gaps, composing with RT1
replay-hold.

## Mechanism (documented choice — see ADR-0003)

- **Server-side gap replay already exists** (`event_replay.py`: per-session
  monotonic `seq` stamp + `session.events.since(last_seen)` ring replay).
  This card delivers the missing CLIENT half.
- **Client-side no-gap validation** at the conversation layer: every
  `ConversationEvent` carries `seq`; the view model tracks its last APPLIED
  event id (cursor) and classifies each inbound event (`contiguous` /
  `duplicate` / `gap` / `unknown`).
- **Gap ⇒ targeted recovery** via the new `resumeEvents(since:sessionID:)`
  seam (reuses `session.events.since` from the client cursor).
- **Unrecoverable gap ⇒ explicit** `ConversationError.gapUnrecoverable`
  (ring evicted / truncated) → integrity notice + authoritative
  `session.history` refetch. Never silent loss.
- **Last-Event-ID on subscribe**: `resumeSession(lastEventID:)` sends
  `last_seen` in `session.resume` params (wire-safe today; server ignores
  unknown keys — verified `methods_session.py`).
- **RT1 composition**: cursor gate (conversation) and replay-hold gate
  (transport) enforce the same strictly-newer rule at two layers — both
  enabled cannot drop or duplicate. Existing RT1/M6 tests unchanged, green.

## Files

| Layer | File | Change |
|---|---|---|
| FleetCore | `ConversationEvent.swift` | `seq: Int?` on every case; `EventContinuity`; `ConversationEventCursor` |
| FleetCore | `ConversationProviding.swift` | `resumeSession(lastEventID:)`, `resumeEvents(since:)`, `ConversationError.gapUnrecoverable` |
| FleetNetworking | `GatewayConversationClient.swift` | seq threading in `decodeEvent`; `last_seen` on resume; `resumeEvents` (truncated ⇒ `.gapUnrecoverable`) |
| FleetUI | `ConversationViewModel.swift` | cursor tracking; continuity gate (dup dropped / gap recovered); `integrityNotice`; history refetch on unrecoverable |
| FleetUI | `ConversationView.swift` | integrity banner + preview stub update |
| App | `FleetSimulator.swift` | scripted stub updates (never gaps) |
| Tests | `LastEventIDResumeTests.swift` (new, 5) | exact-resumption proof, last_seen-on-subscribe, truncated ⇒ explicit, seq-space composition |
| Tests | `ConversationDomainTests.swift` (+3) | seq round-trip, cursor classification, gap error vocabulary |
| Tests | `ConversationViewModelTests.swift` (+3) | gap recovered exactly, duplicates dropped, unrecoverable ⇒ history refetch |
| Docs | `docs/adr/0003-last-event-id-resume.md` | the documented mechanism choice |

## Validation (2026-09-02, apple-dev)

`bash scripts/c1_ci_validate.sh` → **C1 CI: PASS=9 FAIL=0**

- FleetCore: 176 tests, 0 failures
- FleetNetworking: 212 tests, 0 failures (incl. 5 new LastEventIDResumeTests)
- FleetPersistence: 23 / FleetSecurity: 37 — 0 failures
- App unit tests (HermesFleetAppTests): 159 tests, 0 failures (incl. 3 new
  VM gap tests)
- Deterministic UI suites: 43 tests, 0 failures
- Module boundary guard: 0 `import FleetNetworking` in FleetUI
- gitleaks: no leaks

Centerpiece evidence (`testDisconnectMidStreamReconnectResumesExactly`):
live seq 1-3 → abnormal drop → reconnect (resume sends `last_seen: 3`) →
`resumeEvents(since: 3)` returns 4-5 → live tail 6 on the same pipe →
union sorted == [1,2,3,4,5,6] AND all ids unique (zero lost, zero
duplicated), rendered text lossless.

## Known limitations / handoff

- The cursor is in-memory per view model (matches M6 watermarks; persistence
  is the separate P5 scope).
- `last_seen` on `session.resume` is ignored by the current gateway — the
  field is forward-declared; recovery relies on `session.events.since`.
- RT1 merge note: RT1's branch retains the transport-level sparse-batch
  test (`{5,7}` applied as-is). That behavior is unchanged at the transport;
  the CONVERSATION layer now validates continuity and recovers/surfaces.
