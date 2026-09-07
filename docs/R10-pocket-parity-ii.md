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

## T4 — Voice (client-side STT/TTS, documented deviation)

Commit: see `git log --grep t_703c65a6`.

### Wire truth (verified 2026-09-04)

- hermes-agent 0.21 has NO client-audio WS upload method. The WS registry
  exposes no audio-in method; `/voice` toggles the gateway's OWN local-mic
  loop: `full_duplex_listen` (`server.py:17334`, armed by
  `_arm_full_duplex_listener` `server.py:17223/17246`) records the gateway
  host's microphone, `transcribe_recording` runs server-side, and the
  transcript is fed to the agent as a local interjection
  (`server.py:17334-17360`). None of that path accepts remote audio.
- Interrupt semantics for spoken replies:
  `mark_speech_interrupted` (`tools/tts_streaming.py`, called at
  `server.py:17191` on voice-mode change and `server.py:17303` when a voice
  interjection arrives mid-turn) — speech is cut when a new user turn lands.

### DEVIATION BY DESIGN

Desktop's `/voice` loop listens on the gateway's local mic. iOS cannot feed
a remote mic into it — no wire exists — so the iOS implementation is
CLIENT-SIDE and documented here as a deviation:

- STT: on-device `SFSpeechRecognizer` (on-device recognition requested when
  supported; only recognized TEXT is ever submitted, via the normal
  `prompt.submit` path — no audio leaves the device).
- TTS: local `AVSpeechSynthesizer`, chunked by streaming `message.delta`s
  (each delta is one queued utterance; a turn that arrives as a single
  complete frame is spoken exactly once — the never-double rule).
- Interrupt: a new user turn cuts speech locally at `send()` entry —
  mirroring `mark_speech_interrupted` (server.py:17191), applied to the
  local synthesizer since the speech is local.

No wire was invented; nothing here claims gateway-side voice.

### Implementation

- `FleetCore/VoiceSeam.swift` — `VoiceTranscript`, `VoiceAuthorization`,
  `VoiceError`, the `VoiceTranscribing` seam +
  `UnsupportedVoiceTranscriber` fail-closed default (FleetUI never imports
  AVFoundation/Speech — M0 discipline).
- `HermesFleetApp/VoiceIO.swift` — `SpeechVoiceIO`: the concrete engine
  (AVAudioSession playAndRecord+duckOthers, SFSpeechAudioBufferRecognition
  request with on-device recognition when supported, one parked
  continuation resumed exactly once — final > partial > nil; AVSpeech
  queue with per-utterance completion bridge; stopSpeaking cuts the queue).
- `ConversationViewModel` — `voice` seam (default fail-closed),
  `toggleMic()` (authorize → gate or capture), `latestVoiceTranscript`
  (review-first), `isSubmitOnSilenceEnabled` (final-only auto-submit;
  partials NEVER auto-submit), voice mode speaking in `render`, speech cut
  at `send()` entry, never-silent `voiceError`.
- `ConversationView` — mic button (`fleet.conversation.mic`,
  listening/stop states), "Speak Replies" toggle in the "+" menu
  (`fleet.conversation.voiceMode.toggle`), transcript review chip
  (Use/Send/Discard), honest denied banner with Settings deep link,
  never-silent voice error banner.
- `AppEnvironment` — `FleetVoiceEngineFactory` seam, threaded into the
  conversation VM (nil ⇒ fail-closed, affordances hidden).
- `FleetServiceGraph` — production wires `SpeechVoiceIO`;
  `FleetSimulator` wires the env-knobbed `ScriptedVoiceEngine`
  (`HERMES_FLEET_VOICE_DENIED=1`, `HERMES_FLEET_VOICE_TRANSCRIPT=1`).
- `Info.plist` — `NSSpeechRecognitionUsageDescription` +
  `NSMicrophoneUsageDescription`.

### Tests

- FleetCore `VoiceSeamDomainTests` — 4 tests (values, fail-closed default).
- Hosted `ConversationVoiceViewModelTests` — 9 tests, scripted seams, no
  live speech: denied gate never captures; final transcript lands for
  review (review-first default); submit-on-silence auto-submits FINALS
  only; partials never auto-submit; deltas spoken chunked + complete text
  exactly once; every user turn cuts speech; voice-off never speaks;
  capture failure surfaces the never-silent banner; fail-closed default
  hides affordances + honest error.
- UI `R10VoiceUITests` — 2 deterministic tests (denied gate banner +
  Settings action, no capture; transcript chip → Send submits through the
  composer path and the scripted turn streams back). Registered in
  `scripts/c1_ci_validate.sh` (the R9-T7 QA rule).
- Live mic/speech verification is a LOCAL-ONLY environmental suite (real
  device dogfood lane) — never in CI.

### Deviations / honest notes

- CLIENT-SIDE VOICE IS THE DEVIATION (above). If hermes-agent later adds a
  client-audio WS method, the seam is the swap point.
- Speech recognition may require network for some locales even with
  `requiresOnDeviceRecognition` requested; the usage description says
  "on-device" only for locales that support it — the permission copy
  states text-only submission honestly.
- Submit-on-silence defaults OFF (review-first); manual stop always lands
  a PARTIAL that is never auto-submitted.

### Round evidence (T4)

- Commits: `d8c964c` (implementation) + `007b6c9` (round 2 — the voice-mode
  Toggle had landed as a bare switch INSIDE the composer HStack, breaking
  R10AttachmentTrayUITests with an AX-query timeout; baseline HEAD~1
  verified green isolating the regression; moved into the "+" Menu as a
  titled Button).
- Local CI gate `scripts/c1_ci_validate.sh` on tip `007b6c9`: GATE_EXIT=0 —
  PASS xcodegen; PASS FleetCore 229 tests; PASS FleetNetworking 313;
  PASS FleetPersistence 30; PASS FleetSecurity 37; PASS M0 guard
  (0 `import FleetNetworking` in FleetUI); PASS unit bundle 298 tests
  (incl. 9 voice VM tests + 4 FleetCore voice-domain tests); PASS
  deterministic UI 69 tests / 23 suites (incl. 2 R10VoiceUITests);
  PASS gitleaks.
- Pushed to origin/main (`54f51e7..007b6c9`).

## T5 — Memory-graph edit/delete (`learning.edit` / `learning.delete`)

Unlocks the R9 read-only limitation (docs/R9-pocket-desktop.md:114).

### Wire truth (hermes-agent 0.21.0, installed source)

- Handlers registered in `tui_gateway/methods_tools.py:1079-1082`: all
  three learning mutations dispatch to `agent/learning_mutations.py`
  with str-coerced params — `learning.detail {id}`, `learning.delete
  {id}`, `learning.edit {id, content}`.
- `edit_node` (learning_mutations.py:136-157): success
  `{ok: true, message: "updated …"}`; refusals are RESULT data
  `{ok: false, message}` — empty memory body → "empty memory — use
  delete to remove it" (:152-153); stale id → "memory node id is
  stale — refresh the graph".
- `delete_node` (:108-131): deleting a SKILL archives it — the success
  message carries the restore recipe ("archived 'x' — restore with:
  hermes curator restore x", :124); deleting a memory rewrites its
  file; PINNED skills refuse ("'x' is pinned — unpin it first
  (hermes curator unpin x)", :119-120).
- No numeric RPC error codes distinguish refusals — they ride the
  `{ok: false}` envelope exactly like `learning.detail`.

### Implementation

- `FleetNetworking/GatewayLearningClient` — typed `editNode(id:content:)`
  and `deleteNode(id:)` returning the gateway message; shared
  `decodeMutation` maps `{ok:false}` → new
  `GatewayLearningError.mutationFailed` (message surfaces VERBATIM —
  gateway messages name the remedy).
- `FleetCore/LearningGraph.swift` — seam grows `editNode`/`deleteNode`;
  `UnsupportedGatewayLearning` fails closed on all four.
- `FleetUI/MemoryGraphViewModel` — `performEdit`/`performDelete`:
  mutate → RELOAD the graph from the server (no optimistic patching;
  labels change with content) → snapshot refresh removes deleted nodes
  from the offline store. Refusals set `mutationError` and leave the
  graph untouched; delete closes the drill-in sheet only on success.
- `FleetUI/MemoryGraphView` — drill-in sheet gains an ellipsis menu
  with Edit (TextEditor prefilled from `learning.detail`, Save/Cancel,
  refusal shown INLINE in the editor) and Delete (confirmation alert;
  skill deletes say "archived, restorable"); a mutation banner on the
  map surfaces the gateway message after the sheet closes.
- `HermesFleetApp/FleetSimulator` — scripted seam is now MUTABLE
  (delete removes the node from the fixture graph; edit refuses empty
  memory bodies with the real wire message), so the UI walkthrough is
  honest without a live gateway.

### Tests (RED observed first at each layer)

- `GatewayLearningClientTests` — 4 new wire tests: edit ask
  `{id, content}` + message decode; edit empty-body refusal →
  `.mutationFailed`; delete ask `{id}` + archive-message decode;
  pinned refusal verbatim. Suite 12/12.
- `MemoryGraphTests` — 4 new VM tests: edit reloads + message; edit
  refusal verbatim without reload; delete removes node from graph AND
  snapshot, closes sheet; delete refusal keeps the map intact.
  Suite 16/16.
- `R10MemoryGraphEditUITests` — 3 deterministic tests (scripted fleet,
  no live gateway): edit → save → success banner; delete → confirm
  alert → node count drops (server-truth reload); empty-body edit →
  verbatim refusal inline, editor stays open, node count unchanged.
  Registered in `scripts/c1_ci_validate.sh` (R10-T7 QA rule).

### Honest deviation note (T4 follow-up folded here)

QA noted (t_703c65a6, non-blocking): the T4 wire-truth sentence "The
WS registry exposes no audio-in method" was overbroad — `wake.feed`
(server.py:17861) accepts base64 client PCM, but ONLY to feed the
armed openWakeWord wake-word detector (wake.start capture:"client");
there is no remote-audio transcription path. The T4 design conclusion
(client-side STT, no wire invented) is unaffected.

### Round evidence (T5)

- Commits: `f134fe3` (implementation) + `1508e40` (round 2).
- Local CI gate `scripts/c1_ci_validate.sh` on round-2 tip `1508e40`:
  GATE_EXIT=0 — PASS xcodegen; PASS FleetCore 229 tests; PASS
  FleetNetworking 317 (incl. 4 new learning-mutation wire tests);
  PASS FleetPersistence 30; PASS FleetSecurity 37; PASS M0 guard;
  PASS unit bundle 302 tests (incl. 4 new VM mutation tests); PASS
  deterministic UI 72 tests / 24 suites (incl. 3
  R10MemoryGraphEditUITests); PASS gitleaks. Pushed to origin/main
  (`6be0c5a..1508e40`).
- Gate run 1 caught TWO defects, both fixed in round 2:
  1. REAL T4-surface bug: `speakAssistant` spawned an unstructured
     Task per streaming delta, so TTS chunks could reach the
     synthesizer OUT OF ORDER (observed speakCalls ["fleet", "Hello "]
     under full-bundle load; 6/6 green in isolation, which is why T4's
     own gate pass missed it). Fixed with a `SpeechQueue` actor
     (arrival-order serialization; `send`/`setVoiceMode` cuts also
     drain queued chunks so stale audio never plays after an
     interrupt).
  2. Simulator relaunch flakiness: XCUITest `launch()` under gate load
     occasionally surfaced the PREVIOUS test's screen (AX dump showed
     the prior run's memory graph + banner after a "fresh" launch;
     SpringBoard logs confirmed force-quit kills mid-test).
     `openMemoryDetail` retries once via terminate()+launch(); suite
     3/3 across three consecutive full-suite runs, then 3/3 inside
     gate run 2.
- Wire tests 4 new (edit ask/decode, empty-body refusal, delete
  ask/archive decode, pinned refusal verbatim) — suite 12/12.
- VM tests 4 new (edit reload+message, refusal verbatim no-reload,
  delete removes node from graph AND offline snapshot + closes sheet,
  refusal keeps map intact) — suite 16/16.
- NO build bump: CURRENT_PROJECT_VERSION stays 17.
- Known limitation: deleting a skill ARCHIVES it server-side
  (restorable via `hermes curator restore`); the alert copy says so —
  there is no un-archive wire method on the WS registry (YAGNI).

## T1/T3 evidence and route notes

### T1 — Attachments

- Accepted commit: `d40b675` (pushed to `origin/main`); independent QA
  verdict PASS. The client wire shapes are grounded at
  `methods_prompt.py:1163` (`image.attach_bytes`), `:1224` (`pdf.attach`),
  `:1350` (`file.attach`), `:1397` (`image.detach`), and server ceilings at
  `server.py:14284-14286`.
- The client uses `data:<mime>;base64,<b64>` for remote file staging and
  applies a conservative 10 MB client cap. QA measured the live image
  ceiling at 24.9 MB accepted and 25.1 MB rejected with 4018; the cap is
  therefore intentionally below the gateway ceiling. `pdftoppm` is absent
  on this Mac, so local PDF conversion remains an environment limitation;
  the client maps the gateway failure without silently swallowing it.
- RED-first wire/VM/UI coverage was independently accepted: 293 networking
  tests, 40 hosted attachment tests, and `R10AttachmentTrayUITests` 2/2;
  the suite is registered in `scripts/c1_ci_validate.sh`. The simulator
  picker uses the documented `HERMES_FLEET_ATTACHMENT_PICK` fixture hook;
  system picker automation is not claimed as deterministic.

### T3 — Projects browser and FleetScreen routes

- Accepted commit: `54f51e7` (round-2 correction, pushed to
  `origin/main`); independent QA verdict PASS. Wire citations are
  `methods_config.py:117-153` (`projects.tree`), `:157-191`
  (`projects.project_sessions` / 5063), `project_tree.py:540-571`
  (project nodes), `server.py:15827-15866` (session rows), and
  `methods_complete.py:41-326` (`complete.path`).
- `FleetScreen.projects(gatewayID, focusPath:)` carries an `@file:` path
  from the transcript. `ProjectsView` resolves the deepest segment-safe
  project prefix, shows a focus banner with the path and containing project,
  and badges that project as referenced. Relative or foreign paths resolve
  nil honestly; no raw filesystem-browser behavior is implied.
- The route and browser behavior are covered by parser, route, matcher, VM,
  and deterministic UI tests. QA independently ran FleetNetworking 313/313,
  FleetCore 225/225, FleetPersistence 30/30, app units 289/289, and the
  focused Projects UI suite 4/4. The simulator UI evidence was executed on
  iPhone 17 Pro / iOS 26.5; no unverified screenshot is presented as
  pixel evidence in this document.

## R10 aggregate acceptance and build 18 release boundary

Accepted feature SHAs, in execution order: T1 `d40b675`, T2 `c1caa39`,
T3 `54f51e7`, T4 `6be0c5a` (implementation `007b6c9`), and T5 `0ebc2b6`
(implementation gate `1508e40`). QA approved all five cards independently.
The release candidate is the exact clean local `main` tip after the
version-only commit `8cc4b49` and documentation commit `6717c51`; it is
version `0.1.0 (18)`, with `project.yml` and the generated pbxproj agreeing.

T4 remains intentionally client-side: `server.py:17334` is the gateway's
local microphone loop, while `server.py:17861` `wake.feed` only feeds the
openWakeWord detector and is not a remote transcription path. T4's
submit-on-silence capability defaults OFF and remains review-first.

The release authorization is the 2026-09-04 batch authorization on the T6
card. Upload is bounded to TestFlight build 18; no App Store submission,
public release, pricing change, or public tag push is authorized by this
evidence.
