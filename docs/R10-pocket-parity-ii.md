# R10 — Pocket Parity II

Round evidence for the R10 wave (plan
`.hermes/plans/2026-09-04_073102-r10-pocket-parity-ii.md`). Wire truth
verified against the installed hermes-agent 0.21.0 source at
`~/.hermes/hermes-agent/tui_gateway` (file:line citations below) — product
docs are not authority.

## T2 — Tapback-style message reactions (`message.react`)

Commit: see `git log --grep t_8f7350ae`.

### Wire truth (verified 2026-09-04)

- `message.react` — `methods_session.py:1563-1614`. Params
  `{session_id, row_id? | newest_role in {user,assistant}, emoji}`; `emoji`
  is a non-empty string OR an explicit JSON `null` (clear — the server
  distinguishes null from absent, :1585). Optional `author in {user,agent}`
  (server default "user"; the iOS client omits it — the local user IS
  "user"). Result `{row_id: Int, reactions: [{emoji, author, at?}]}` —
  the message's FULL post-write reaction list (server truth).
- Errors: 4023 (row_id or newest_role required), 4024 (emoji empty), 4025
  (author invalid), 4040 (message not found in this session / no message to
  react to yet), 4001 (runtime session reaped — recover via
  session.resume, `server.py:3676-3696`), 5007 (db).
- Per-author single-reaction semantics — DB layer
  `set_message_reaction` (`hermes_state.py:12972-13055`): one reaction per
  author per message; re-sending the SAME emoji retracts it; a different
  emoji replaces it; `emoji: null` clears unconditionally. The iOS client
  mirrors these only for the optimistic snapshot; the server enforces.
- Read-back — VERIFY-FIRST risk resolved: reactions DO ride the wire.
  `_rows_to_conversation` (`hermes_state.py:14153-14156`) forwards decoded
  `display_metadata`, and `_history_to_messages` (`server.py:9936-9938`)
  forwards it per message, alongside the durable `row_id`
  (`server.py:9921-9927`). So `session.history` rows carry
  `display_metadata.reactions` and the app renders existing reactions.
  Live in-memory rows never carry reactions (no event pushes them) —
  reactions render only on rows that came back from durable history, and a
  just-reacted live row settles from the `message.react` result itself:
  the settle PROMOTES the addressed live row to the returned durable row
  id, so the row projects through the durable key and the chip survives
  (QA round-1 defect: the settle previously dropped the live-* key while
  the row still projected through it — the chip vanished exactly when the
  server confirmed the write).

### Implementation

- `FleetCore/MessageReaction.swift` — `MessageReaction`,
  `MessageReactionResult`, `MessageReactionTarget` (`.durable(rowID:)` /
  `.newest(role:)`; failable `init?(liveRole:)` — a static `newest(role:)`
  builder shadowing the enum case factory misbinds at runtime, observed as
  SIGSEGV in the test runner), `MessageReactionsSnapshot`
  (value-semantics optimistic merge), `MessageReactionPalette`
  (👍 ❤️ 😂 😮 🎉 👀).
- `FleetCore/ReactionProviding.swift` — the seam + typed `ReactionError`
  vocabulary + `UnsupportedReactionProviding` fail-closed default +
  `ReactionCapable` marker (the AttachmentStagingCapable one-cast
  discipline).
- `FleetNetworking/GatewayReactionClient.swift` — the wire client
  (client-side 4023/4024 guards fire before the RPC; error-code mapping;
  tolerant result decode).
- `GatewaySessionHistoryClient.decodeMessage` — decodes
  `display_metadata.reactions` onto `SessionMessage.reactions` (new
  field; nil = not disclosed).
- `GatewayConversationSession` — conforms `ReactionCapable`, exposes
  `reactions` on the shared transport.
- `FleetPersistence` — `CachedMessageRow.reactionsData` (additive optional
  JSON column; legacy rows decode nil via lightweight migration; `"[]"`
  keeps "disclosed none" distinct from "not disclosed").
- `ConversationViewModel` — `react(rowID:kind:emoji:)` /
  `clearReaction(rowID:kind:)`: durable rows send `row_id`, live rows send
  `newest_role`; optimistic update with rollback on error; server truth
  settles (a live write adopts the returned durable row id);
  `reactionsByRowID` projected onto `transcript`; history/cache/resume
  loads adopt carried reactions; never-silent `reactionError` banner.
- `ConversationView` — long-press context menu (palette + Clear Reaction,
  user/assistant rows only), reaction chips under the bubble (own emoji
  accented), reaction error banner.
- `FleetSimulator` — `ScriptedReactionSeam` (records calls, mirrors the
  DB retract semantics, `HERMES_FLEET_REACTION_FAIL=1` 4040 hook) +
  `HERMES_FLEET_REACTION_FIXTURE=1` durable-row resume projection (one
  seeded 👀) for the deterministic UI suite.

### Tests (RED-first, all watched fail before implementation)

- FleetCore `MessageReactionDomainTests` — 9 tests.
- FleetNetworking `GatewayReactionClientTests` — 10 wire tests (params
  shape incl. explicit `emoji: null`, error mapping 4023/4024/4040/4001,
  malformed result, history read-back decode, fail-closed default).
- FleetPersistence `CachedMessageReactionsTests` — 2 round-trip tests.
- Hosted `MessageReactionsViewModelTests` — 9 tests (target resolution,
  optimistic settle, rollback + never-silent error, clear-null, history
  render, fail-closed; round-2 live-path coverage: chip survives a
  successful settle on a newest_role row, promotion to the durable id,
  clear on a settled live row).
- UI `R10MessageReactionsUITests` — 4 deterministic tests (long-press →
  chip; same-emoji retract; failure banner + rollback; live-row
  react → chip survives settle → Clear Reaction reachable → clears).
  Registered in `scripts/c1_ci_validate.sh` (the R9-T7 QA rule: every UI
  suite joins the gate).

### Deviations / honest notes

- Reactions on LIVE rows are addressed via `newest_role` — the wire offers
  no per-live-message id. Reacting to an older live row after newer turns
  of the same role would target the wrong row; the UI therefore offers the
  palette on any row but the durable-id path is the precise one after a
  resume. Matches the desktop's constraint (methods_session.py:1576-1579).
- `author` is never sent (always the local user). The gateway's "agent"
  author surface is future desktop parity.
- The reacted live row's chip re-renders from the settle result; there is
  no push event for third-party reactions (none exists on the wire).
