# DEV19 implementation plan — historical record

Status: **completed; Dev 0.1.0 (19) and public 0.2.0 (98) are in TestFlight.**
See [release notes](DEV19-RELEASE-NOTES.md) and [release records](../../RELEASES.md)
for confirmed identities, dates and source commits. The lane instructions below
record the original development plan and are not pending cleanup work.
Baseline: DEV18 = `3ff41b79d10ea35ef9af4dda26d46a3c6b99725f` (owner-verified).

## Goal and guardrails

DEV19 is the last public TestFlight build before App Store submission, so the bar is
"polish what exists, break nothing":

- No new protocol surfaces, extensions, entitlements, push, or persistence schema changes.
  The one exception is the client-only paging fix in L1, because an external tester hit it.
- No changes to security predicates (TLS trust, warning gates, App Lock, approval biometrics).
  Wording can change; behavior stays the same.
- Keep the existing accessibility identifiers, since the UI suites depend on them.
- Every lane ships with focused tests and leaves `make dev-check` green.

## Lanes

Each lane gets its own worktree off `dev19/integration`. Lanes in the same wave own
disjoint files.

### Wave 1 (parallel)

**L1 — Long Bot Chats open to the recent page (#188, P0).**
An external tester can't open chats with more than 20k messages: the gateway returns error 4130.
- Before coding, check the issue's claims against the read-only Hermes clone: the
  `session.resume` flags `omit_messages`/`defer_history`, the paged
  `GET /api/sessions/{id}/messages?order=latest&limit=&offset=` route, and the 500-message cap.
  Also confirm which Hermes versions support them.
- `GatewayConversationClient`: resume without full history when the gateway supports it.
  `GatewaySessionHistoryClient`: load the latest page, then older pages on scroll-to-top.
- Map 4130 to typed failure copy ("This chat is very long — showing recent messages") and keep
  whatever has loaded usable.
- Fall back to current behavior on older gateways (capability-gated, no silent breakage).
- Tests: synthetic transport fixtures for paged loads, the 4130 mapping, and the older-gateway fallback.
- Files: FleetNetworking history/conversation clients, the history-loading parts of
  `ConversationViewModel`. Highest risk, so I review it most closely.

**L2 — Group chat parity with 1:1 chats.**
`RoomChatView` has no long-press menu. Add Copy Message (same policy as 1:1), and add
find-in-chat by reusing `ConversationFindPolicy`. Check that the Latest control and retry
behave the same in both chat types.
Files: `RoomChatView.swift` plus a small shared helper if needed.

**L3 — FleetHaptics vocabulary (#106).**
Add a single `FleetHaptics` (send, success, warning, selection, approve, deny). Move the four
existing `sensoryFeedback` sites onto it, then add haptics for approve/deny, a completed
pull-to-refresh, a failed send, and a finished pairing. Respect Reduce Motion where relevant,
with no new setting.
Files: new `Components/FleetHaptics.swift` and call sites (shared files coordinated with L4).

**L4 — Copy and error polish.**
- #62: HTTP gateway warning copy in `GatewayFormSheet` (wording only; the predicate is unchanged).
- `GatewayAuthSheet`: replace the bare "Error" heading with specific failure copy.
- Find raw `localizedDescription` strings reaching users and route them through the
  `*FailureCopy` types.
- One consistent pass over the 22 `ContentUnavailableView` empty states: same tone, and a
  primary action wherever there's an obvious next step.
Files: the sheets/views listed, `BotFailureCopy`, `GatewayFailureCopy`.

**L5 — Accessibility sweep (audit first, then fix).**
- VoiceOver labels on icon-only buttons and 44pt hit targets.
- Reduce Motion on animated chrome.
- Dynamic Type at AX5 on Chats, Bot Detail, Conversation, Gateways, Settings and Pairing.
- Output: an audit list, then fixes limited to labels/modifiers (no layout rewrites).
  New issues needing a redesign get filed, not fixed.

### Wave 2 (after Wave 1 merges)

**L6 — Loading and notice states (#116).**
- Show skeleton rows (`.redacted(reason: .placeholder)`) on cold load for Chats, Bots and
  Gateways instead of a bare `ProgressView()`.
- Give `FleetNoticeBar` a severity order (info < warning < error) and one recovery action
  per notice.

**L7 — Streaming presence (#107).**
Replace `WorkingDots` with a "thinking" placeholder row, a soft caret while streaming, and a
first-token haptic through L3's `FleetHaptics`. Static under Reduce Motion.

### Wave 3 — integration and release candidate (me)

- Merge lanes into `dev19/integration` in order L1→L7, running `make dev-check` after each.
- Full gate: `xcodegen generate`, `make test-core`, `make test`, `bash scripts/c1_ci_validate.sh`,
  public safety guard, gitleaks.
- Simulator screenshot pass of every touched screen in light/dark and at AX5.
- Build DEV19 with `scripts/fleet_dev_build.sh`, record it in RELEASES.md, and draft the
  "What to Test" text for testers.

## #188 verified contract (Hermes 0.22.1 read-only source)

- `session.resume` refuses with **4130** when the full lineage exceeds `sessions.max_resume_messages`
  (default 20000). With `omit_messages`/`lazy`/`defer_history` the guard counts the **tip only**
  (`tui_gateway/methods_session.py` `_resume_guard`); `omit_messages` returns `messages: []`,
  `messages_omitted: true`, and still reports `message_count`.
- `session.history` has **no paging**: it always materializes the whole lineage, so a 80–226 MB chat
  cannot cross Fleet's 16 MB frame cap.
- REST `GET /api/sessions/{id}/messages?order=latest&limit=N&offset=K&inline_images=false&profile=P`
  (`hermes_cli/web_routers/sessions.py`, same authenticated dashboard surface as `/api/cron/jobs`):
  limit capped at 500; `latest` pages back from the newest, `offset` counts from the newest, rows
  returned chronological; includes compression ancestors; body
  `{session_id, profile, messages:[raw rows], pagination:{limit, offset, order, returned}}`.
  Rows are raw DB rows (`id`, `role`, `content`, `display_content?`, `display_kind?`, `tool_name?`,
  `tool_calls?`, `timestamp`, `reasoning?`, `display_metadata?`), not the `session.history` projection.
- App strategy: the existing path stays the default (DEV18 behavior for every chat that opens today).
  Only when resume fails with 4130 (or the frame is too large) does Fleet re-resume with
  `omit_messages: true` and page history over REST, newest first, with "Load earlier messages" on demand.
  If REST paging is unavailable, the chat stays open (composer usable) with an actionable notice.

## Deferred (not for the final public beta)

- Multilingual voice #185 (uploads audio; needs opt-in and privacy-copy review).
- Offline outbox #145, Inbox destination #113, Command Center #143.
- iPad split view #119, Liquid Glass #112, push/Live Activities, and splitting the large
  `AppEnvironment`/`ConversationViewModel` objects #101.

## Orchestration

- Each lane is one Haiku 5.5 subagent with `isolation: worktree`. Its prompt names the lane's
  exact files, acceptance criteria and tests, and what it must not touch.
- I own the shared files: `project.yml`, the UI test matrix inventory, and release metadata.
- I review every lane diff before it merges and send back work that misses the criteria.
- Local-first: no pushes, tags or PRs unless you ask. Never `git add -A` the generated
  `.xcodeproj`.
- Known environmental flake: the RoomLinkMentions and FleetSettingsAccent UI classes hit the
  Xcode watchdog stall. Re-run them separately through `scripts/c1_ui_matrix.sh`; these stalls
  don't count as product failures.

## Resolved release decisions

- DEV18 baseline: `3ff41b79d10ea35ef9af4dda26d46a3c6b99725f`.
- L1 (#188) shipped, together with L2–L7 and the largest-text follow-up.
- Production ships as `com.aiowa.hermesfleet`, `0.2.0 (98)`; the independent
  Dev app ships as `com.aiowa.hermesfleet.dev`, `0.1.0 (19)`.
- Deferred limitations remain documented in the release notes and accessibility audit.
