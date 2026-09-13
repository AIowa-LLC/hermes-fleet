# Hermes Fleet external RC acceptance checklist v1

Status: execution required for every external TestFlight RC. This document is a gate, not evidence that a candidate passed.

## Candidate and gate rules

- Candidate SHA: ______________________________
- App version / build: ________________________
- Configuration: Release / RC
- Physical device class and OS: _______________
- Hermes gateway path class: __________________
- Tester / date: ______________________________

Use a fresh install of the exact Release build produced from the candidate SHA. Record PASS, FAIL, or HOLD for every journey; attach public-safe screenshots, screen recordings, and logs by reference only. Never put UDIDs, credentials, tokens, private hostnames, account identifiers, or signing data in evidence. A FAIL or HOLD blocks the RC; do not waive a failure in this checklist.

Result key: [ ] PASS  [ ] FAIL  [ ] HOLD
Evidence reference: ___________________________
Notes / defect issue: _________________________

## Repository gates (run before physical testing)

| Gate | Command / expected result | Result and evidence |
|---|---|---|
| UI inventory | `bash scripts/c1_ui_matrix.sh --audit` exits 0 and reports every class accounted for | |
| Static guards | `bash scripts/c1_static.sh` exits 0 | |
| RC preflight | `bash scripts/rc_preflight.sh` exits 0; physical actions remain listed as RC work | |
| Deterministic tests | Run the selected C1 UI shard(s), hosted unit tests, and package tests appropriate to the candidate; record exact commands and exit codes | |

## User journeys

For each row, perform the steps in order on the exact candidate build, then complete the result fields.

### 1. Install and lifecycle

Steps: clean-install; launch through onboarding; complete initial configuration; terminate and relaunch; background then foreground; force-quit then relaunch.

Expected evidence: app launches without crash; onboarding is understandable; configuration survives relaunch and lifecycle transitions; no protected content is exposed during a transition.

Deterministic mapping: `SplashUITests`, `F3OnboardingUITests`, `C2SetupPromptUITests`, `HermesFleetHappyPathUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 2. Gateway setup and fail-closed errors

Steps: register a gateway manually; repeat with QR pairing where available; authenticate; terminate/relaunch and confirm credentials remain usable without re-entry; verify roster/health; enter a deliberately invalid endpoint or invalid auth and observe the failure path.

Expected evidence: manual and QR flows create the intended gateway; authenticated roster/health is visible; persistence does not reveal secrets; bad endpoint/auth stays fail-closed, gives an understandable state, and does not show stale or unauthorized data.

Deterministic mapping: `P2GatewayFormDraftUITests`, `F2QRPairingUITests`, `U7GatewayQrLockSettingsUITests`, `FOS2GatewayDetailUITests`, `RT2RemovalAndEndpointSanitizationUITests`, `RT4FormSaveFailureUITests`, `RT4RosterEmptyStateUITests`, `S3CleartextWarningUITests`.

Environmental mapping: `F1TwoGatewayFleetLiveUITests`, `L1LiveGatewayUITests`, `L1FixLiveGatewayUITests`, `P3FixLANGatewayUITests`, `P3FixLoopbackGatewayUITests`, `T2FixTailnetGatewayUITests`, `P0_7LiveTailnetUITests`, `H2HealthDashboardUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 3. Direct chat, existing and new sessions

Steps: open an existing session; send a message and observe streaming; leave and re-enter; send again; create a new session; stream a response; interrupt network connectivity; restore it; return to the session.

Expected evidence: messages and streaming render coherently; existing and new sessions remain distinct; reconnect resumes or reports truthfully without duplicate/corrupt transcript entries; history is retained.

Deterministic mapping: `HermesFleetHappyPathUITests`, `HermesFleetReconnectUITests`, `P0_7SessionStateMachineUITests`, `Issue5StreamingRichTextUITests`, `SecondGenerationUITests`, `U6ConversationSkinUITests`.

Environmental mapping: `BotChatTapUITests`, `BotRosterSlice2UITests`, `P0_7LiveTailnetUITests`, `L1LiveGatewayUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 4. Skills, slash commands, and approval

Steps: discover/filter slash commands; invoke a supported skill against the live gateway; verify visible command/result payload behavior; invoke an approval-required operation where available and approve or reject it.

Expected evidence: command discovery is scoped and usable; supported invocation returns the expected user-visible state; approval is explicit and no unapproved action is represented as completed.

Deterministic mapping: `Issue4SlashSkillUITests`, `R9ConversationToolingUITests`, `R9ApprovalBannerUITests`, `BotRoutinesUITests`.

Environmental mapping: `L1LiveGatewayUITests`, `P0_7LiveTailnetUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 5. Bots, avatar, Pet, image/shape, and relaunch

Steps: open Bot detail; edit supported metadata; preview and save avatar appearance; select and save a Hermes Pet; exercise image-to-shape and shape-to-image transitions; relaunch and verify the authoritative appearance.

Expected evidence: supported edits save with truthful success/failure; preview matches saved state; image/shape transitions do not lose unrelated fields; relaunch hydrates the server-authoritative appearance.

Deterministic mapping: `U5BotDetailUITests`, `BotAvatarAppearanceUITests`, `BotPetAvatarUITests`, `FOS5BotsGroupsChatsUITests`.

Environmental mapping: `BotRosterSlice2UITests`, `BotChatTapUITests`, `B1LiveBoardPickerUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 6. Groups, RoomLink, and Latest history

Steps: open a group; send and receive; read older history; use Latest to return; mention a Bot/member where supported; inspect RoomLink state; exercise the non-destructive recovery/replication path for the test environment.

Expected evidence: group membership and messages are coherent; Latest returns to current history; RoomLink state is explicit and authoritative; recovery does not duplicate or corrupt messages.

Deterministic mapping: `RoomChatUITests`, `RoomLinkMentionsUITests`, `FOS5BotsGroupsChatsUITests`, `FOS8AccessibilityUITests`.

Environmental mapping: `B1LiveBoardPickerUITests`, `BotChatTapUITests`, `P0_7LiveTailnetUITests`, `L1LiveGatewayUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 7. Attachments, microphone, speech, and voice

Steps: attach a supported file/media item; send and observe handling; grant microphone permission; exercise speech recognition/input; exercise voice output/read-aloud where supported; deny/cancel permissions once and retry.

Expected evidence: attachment state and errors are truthful; permission prompts are understandable; denial/cancellation does not crash or leak content; speech and voice paths produce the expected visible/audio result when supported.

Deterministic mapping: `R10AttachmentTrayUITests`, `R10VoiceUITests`, `RT4VoiceOverUITests`, `FOS8AccessibilityUITests`.

Environmental mapping: `L1LiveGatewayUITests`, `P0_7LiveTailnetUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 8. App Lock and Face ID lifecycle

Steps: enable App Lock; background/foreground to trigger relock; unlock with Face ID; cancel or fail Face ID; verify protected content remains hidden; retry and unlock successfully; force-quit and relaunch.

Expected evidence: lock timing is correct; successful unlock reveals content; cancellation/failure never exposes protected content; relaunch preserves the configured security behavior.

Deterministic mapping: `U7GatewayQrLockSettingsUITests`.

Environmental mapping: `H1AppLockUITests` (quarantined from hosted CI; must be run on the physical RC device or documented N/A with concrete reason).

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

### 9. Failure recovery

Steps: remove network during an active session; observe degraded/offline state; restore network; wait for reconnect/reconciliation; revisit the session and repeat a safe send.

Expected evidence: offline state is truthful and non-destructive; reconnect is visible; reconciliation has no duplicate/corrupt entries and preserves session identity.

Deterministic mapping: `HermesFleetReconnectUITests`, `P0_7SessionStateMachineUITests`, `RT4FormSaveFailureUITests`.

Environmental mapping: `P0_7LiveTailnetUITests`, `L1LiveGatewayUITests`, `L1FixLiveGatewayUITests`, `P3FixLANGatewayUITests`, `P3FixLoopbackGatewayUITests`, `T2FixTailnetGatewayUITests`.

Result: [ ] PASS [ ] FAIL [ ] HOLD  Evidence: __________  Notes/defect: __________

## Environmental suite accounting

Every environmental class in `scripts/c1_ui_matrix.sh` is mapped above. Run each applicable suite against the RC and record PASS/FAIL/HOLD. If a suite is not applicable to the external-beta configuration, write the concrete reason and evidence here; omission is not an acceptable result.

| Suite | Journey above | Result | Command/evidence or concrete N/A reason |
|---|---|---|---|
| B1LiveBoardPicker | Bots / Groups | | |
| BotChatTap | Direct chat / Bots / Groups | | |
| BotRosterSlice2 | Direct chat / Bots | | |
| F1TwoGatewayFleetLive | Gateway setup | | |
| H2HealthDashboard | Gateway setup | | |
| L1FixLiveGateway | Gateway setup / Recovery | | |
| L1LiveGateway | Gateway/chat/skills/voice/recovery | | |
| P0_7LiveTailnet | Gateway/chat/skills/groups/voice/recovery | | |
| P3FixLANGateway | Gateway / Recovery | | |
| P3FixLoopbackGateway | Gateway / Recovery | | |
| T2FixTailnetGateway | Gateway / Recovery | | |
| H1AppLock | App Lock | | |

## Release decision

Blocking defects/issues: ______________________________________________________

Final gate: [ ] PASS  [ ] FAIL  [ ] HOLD
Approver: __________________  Date: __________  Evidence report: ______________

A passing simulator matrix alone cannot produce PASS. External TestFlight submission remains blocked until the exact RC passes the physical-device and live-Hermes journeys above.
