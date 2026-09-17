# Hermes Fleet — Repository Recovery & Reconciliation Ledger
Date: 2026-09-17 (CDT) · Mission: full local recovery after Build 46 regression
Author: apple-dev profile (Hermes)

## 1. Root cause (CONFIRMED, evidence-backed)

**What happened:** Build 45 (0.2.0(45), the correct overnight dogfood build from
`dogfood/build-41-integration` @ 1685b240 + 106 uncommitted mission files) was
installed on Tony's iPhone at 12:36 on 2026-09-17. At **13:14 CDT** a **Codex
Desktop session** (`~/.codex/sessions/2026/09/17/rollout-2026-09-17T13-14-23-01a0b093-ad01-76c2-8686-a6f314c81d47.jsonl`,
cwd `~/code/hermes-fleet-ios`) began executing a "Build 46:
Final Stabilization and UI Refinement" spec authored in ChatGPT.

**The failure:** The spec said "Starting point: Build 45" — but Codex's cwd was
the **stale public-mirror repo** (`main` @ b8a95ff, Sep 6, an unrelated
sanitized public-archive history; my operating notes mark it "detached public
mirror — never work there"). That tree does NOT contain:

- the 16 commits of `dogfood/build-41-integration` (slash-command parity,
  Continue-as-Hosted rooms, five-tab Kanban navigation, build-41 integration
  merge), nor
- the ~106 uncommitted overnight files (Cron destination + management, secure
  artifact transport, inline chat media, image-generation animation, B44 bug
  fixes, D1–D3 fixes, RoomChat race fix, gitleaks allowlist).

Codex treated that stale tree (which carried a Sep-16 evening WIP snapshot from
WebUI sessions that had also landed in the wrong tree) as "the Build 45
lineage", built "Build 46" from it, and at **13:41:57 CDT installed it over
b45 on the iPhone** (devicectl AppInstall success, unified-log receipt).

**The cascade:** Tony flagged the regression ("massive regression ... very old
build"). Codex self-audited, discovered the wrong-tree mistake, then rebuilt
from the mirror's `codex/product-readiness-integration` worktree (local commits
`b4e5712` "Build 46: recover full product lineage and stabilize shell" and
`08f7444` "Build 46: route shell colors through active theme") and reinstalled.
Those commits were built on the **mirror's** product-readiness lineage — still
the wrong repository: none of the dogfood-lane commits and none of the
overnight files. Result: "a mixture of old fixes and new fixes ... doesn't
have a lot of what we just built the last two days."

**Why the phone shows the wrong app:** every Codex install (13:41, and the
later "corrected" reinstalls) replaced the in-place b45 install of
`com.aiowa.hermesfleet` with builds from the mirror lineage.

### Confirmed vs hypothesis
- CONFIRMED (log evidence): Codex session id/timestamps; mirror-tree mtimes
  (13:29–13:43); devicectl AppInstall success 13:41:57; Codex rollout
  narration admitting "I built from the old `main` base plus the Build 46
  edits"; b4e5712/08f7444 parentage on the mirror repo.
- CONFIRMED: overnight work intact in build-41 worktree (identical twin in
  rc-363bc; tracked diffs byte-identical, untracked sets differ only by
  `scripts/overnight_install_retry.sh`).
- HYPOTHESIS (high confidence, not device-verified): the mirror Sep-16 WIP
  snapshot came from the two Sep-16 WebUI apple-dev sessions ("theme avatar
  coupling" 10:14, "Restore bot editing and consolidate navigation" 12:49)
  which worked in the mirror tree by mistake. File mtimes (Sep 16 19:24–20:46)
  and the Sep-16 Codex sessions in the mirror (17:48, 19:19, 21:42, 21:43)
  bracket the same edits.
- NOT FOUND: launch-readiness session `20260916_223041_843723` — searched all
  6 profile DBs, kanban DBs, sessions.json, state snapshots, mdfind. Not on
  this machine. Likely another machine or a mis-transcribed id.

## 2. Repositories & worktrees inventory (final)

| Repo / worktree | Branch / HEAD | State | Disposition |
|---|---|---|---|
| ACTIVE `~/code/hermes-fleet` | `feat/continue-as-hosted` @ 293c637 | clean | integration source (merge already inside dogfood lane) |
| ACTIVE `.worktrees/build-41` | `dogfood/build-41-integration` @ 1685b240 | 68 M + 38 ?? | **AUTHORITATIVE** — all overnight work; integration performed here |
| ACTIVE `.worktrees/rc-363bc` | detached @ 1685b240 | 68 M (identical) | QA twin; lacks only `scripts/overnight_install_retry.sh` |
| ACTIVE `.worktrees/slash-parity` | `feat/slash-command-parity` @ 8e477fe | clean | already merged into dogfood lane via d097b8b |
| ACTIVE `workspace/testflight-dogfood-0.2.0/worktree` | detached @ d0f607b | clean | historical TF preflight lane |
| MIRROR `~/code/hermes-fleet-ios` | `main` @ b8a95ff (Sep 6) | 25 M + 37 ?? (Sep-16 WIP + Codex b46 edits) | **quarantined**; superseded; preserved |
| MIRROR `.worktrees/product-readiness-integration` | `codex/product-readiness-integration` @ 08f7444 | clean | Codex b46 source; quarantined; preserved |

## 3. Session → code reconciliation ledger

| Session | Objective | Where the work lives | Status |
|---|---|---|---|
| apple-dev 20260915_221557 (b41 dogfood assembly) | 0.2.0 dogfood build | dogfood lane commits ≤ bfb1fa6 | Already integrated |
| apple-dev 20260915_233914 (build-41 nav/Kanban) | five-tab nav + Kanban | 1685b240 (amended tip) | Already integrated |
| apple-dev 20260916_212402 ("Recover build 44") | B44 bug fixes | build-41 uncommitted (A-card files) | **Recovered → committed** |
| apple-dev 20260917_011737 + kanban workers (fleet-overnight, 13/13 cards A–G + D1–D3 + RoomChat + gitleaks + UI-matrix) | Cron, Artifacts, chat images, animation, bug hunt, TF readiness | build-41 uncommitted (~106 paths) | **Recovered → committed** |
| apple-qa kanban workers (B r2, D2, D3, RoomChat QA) | independent verification | verified on build-41/rc-363bc twins | Already integrated (QA-approved) |
| default 20260826_011030 (orchestrator, 13:00 inspection) | read-only b45 audit | no repo writes | No action (read-only, correct) |
| apple-dev webui 5338025da4be + 1f225426208e (Sep 16) | theme/avatar fix; bot editing + nav consolidation | landed in MIRROR tree by mistake | Superseded (same work landed better in dogfood lane; mirror copies preserved) |
| Codex 2026-09-17T13:14 (Build 46 spec) | stabilization | mirror commits b4e5712, 08f7444 + mirror dirty tree | **Partially recovered**: portable unique pieces ported (ReasoningPresentation + preference wiring, pathSafeBasename + send-site, Settings sections, Build46StabilizationTests); rest superseded |
| Launch-readiness `20260916_223041_843723` | (per mission) | not found on this machine | **Unrecoverable locally** — flagged for owner |

## 4. Integration decisions

Baseline chosen: `dogfood/build-41-integration` @ 1685b240 + its 106-file
uncommitted working set (the only tree containing ALL lanes: slash parity via
merge d097b8b, Continue-as-Hosted via merge d097b8b, five-tab Kanban nav at
1685b240, overnight A–G/D1–D3/RoomChat in the working set). The newest commit
is not the baseline — the newest *complete* integration is.

Competing implementations resolved:
- Mirror's Sep-16 nav rewrite (FleetTabView/FleetScreen/FleetNavigationDrawer)
  vs dogfood lane's: dogfood versions are the later, matrix-tested five-tab
  shell; mirror's are older/reduced variants of the same session's work.
  Kept dogfood. (Drawer theme routing Codex fixed in 08f7444 was already
  present in the dogfood drawer.)
- Codex's drawer sheet vs dogfood's drawer: kept dogfood's (B43 tests + UI
  matrix cover it).
- `ReasoningPresentation` (preference + override state machine): genuinely new
  capability from the approved Build 46 spec — ported verbatim + synthesized
  wiring that PRESERVES the dogfood P0-8 streaming auto-expand behavior.
- `pathSafeBasename`: additive hardening at the attachment send site — ported
  with its tests.
- Settings "Manage Gateways" NavigationLink + "Reasoning by default" picker:
  ported (spec items; consistent with dogfood Settings-as-tab structure).

Sanitizations:
- `scripts/overnight_install_retry.sh`: hardcoded iPhone UDID removed — now
  resolves via shared `fleet_device.sh` (HERMES_FLEET_DEVICE_ID override /
  single-iPhone auto-discovery), APP path via env, per repo policy (no device
  identifiers in tracked files).

## 5. Preservation record

`~/fleet-recovery-20260917_162210/` (48 MB):
- `bundles/active-hermes-fleet-all-refs.bundle` — full refs of active repo
  (verified: "records a complete history")
- `bundles/mirror-hermes-fleet-ios-all-refs.bundle` — full refs of mirror
  (incl. b4e5712, 08f7444) (verified)
- `patches/build41-tracked.patch` (7,402 lines), `patches/mirror-root-tracked.patch` (2,233 lines)
- `untracked/build41/` (38 files), `untracked/mirror-root/` (121 files incl. Design/icon-wing-*)
- `records/`: SHA lists, worktree inventories

## 6. Feature reconciliation matrix (post-integration)

| Area | Evidence in dogfood lane | Status |
|---|---|---|
| A. Navigation (Bots/Chats/Kanban/Fleet+Settings, Bots launch) | FleetScreen.swift FleetTab enum; `selection = .bots` default; B43NavigationEditingUITests; U3TabNavigationUITests | Integrated |
| B. Full Kanban (create/update/move/complete/block/unblock/archive/restore/delete/reclaim + boards) | KanbanBoardViewModel public funcs (14); KanbanBoardUITests + KanbanInteractiveUITests | Integrated |
| C. Bots & Bot Mode (route-canonical identity, cross-gateway distinct) | BotAvatarIdentity.swift route-id keying; BotAvatarIdentityColorTests; BotsPresenceSyncUITests | Integrated |
| D. Group conversations (rooms, CreateRoomSheet, hosted authority, legacy banner) | RoomChatView, CreateRoomSheet, RoomLinkView, GatewayRoomProviders; CrossGatewayRoomSetupTests; Continue-as-Hosted commits (8a7465b, 293c637, c730215) | Integrated |
| E. Theme system (picker, default accent, avatar isolation) | FleetTheme/Palette; FleetThemeTests; BotAvatarThemeDecouplingTests; FleetSettingsAccentUITests | Integrated |
| F. Conversation UI (compact chrome, streaming, RoomChat convergence) | ConversationCompactChromeUITests; RoomChat fix (t_363bc529 convergence loop) in working set | Integrated |
| G. Composer & slash commands (catalog, completion, dispatch, palette eager VStack) | GatewaySlashCommandClient + tests; SlashCommandParityUITests; Issue4SlashSkillUITests; commits daac1b3..8e477fe | Integrated |
| H. Connection & session reliability (intent restore, session reuse, TLS) | ConnectionIntentStore, GatewaySessionStore, GatewayAuthenticator; 407a025 + 7beb9f0 lineages via origin/main | Integrated |
| I. Cron destination + management (B card) | CronDashboard core+UI+client+tests; CronManagementUITests (matrix-registered); ScriptedCronDashboard | Integrated (committed this pass) |
| J. Secure artifact transport + inline chat media (C/D cards) | ArtifactTransport, GatewayArtifactClient(+Factory), ArtifactImageStore, ArtifactsView, ConversationArtifactView, FleetArtifactLibrary + tests | Integrated (committed this pass) |
| K. Image-generation animation (E card) | ImageGenerationActivity, FleetWingGenerationView, GeneratedImageCitations + tests | Integrated (committed this pass) |
| L. Build 46 stabilization (reasoning preference, pathSafe attachments, settings) | ReasoningPresentation.swift + wiring; pathSafeBasename; Build46StabilizationTests | **Integrated this pass** (ported from quarantined Codex commits) |
| M. gitleaks storageKey FP allowlist (G2) | .gitleaks.toml scoped line-anchored allowlist | Integrated (committed this pass; owner review requested) |

## 7. Git operations performed

- No resets, no force, no clean, no stash drops, no branch/worktree deletions.
- All work committed on `dogfood/build-41-integration` in logical chunks.
- Nothing pushed. Remote untouched (fetch-only earlier).

## 8. Open items for owner approval

1. Mirror tree disposition: quarantine maintained. The mirror repo's own
   history and its Codex commits are preserved in the recovery bundle. Owner
   decides eventual cleanup/archive.
2. `feat/continue-as-hosted` and `feat/slash-command-parity` branch cleanup:
   both fully contained in the dogfood lane; deletion candidates ONLY with
   owner approval.
3. rc-363bc worktree: safe to remove once owner confirms (its dirty state is
   byte-identical to build-41 minus one script, both preserved).
4. Device reinstall of the recovered build (next phase) — WiFi dev install.
5. Push/PR: NOT performed (requires explicit owner instruction).
6. gitleaks allowlist entry for ConversationPinning storageKey (G2): committed;
   flagged for owner review at commit time per overnight handoff.

## 9. Validation record (committed SHA 53e58b2)

All gates run at the committed state (fresh worktree `/tmp/fleet-rc-verify-53e58b2`):

| Gate | Result |
|---|---|
| FleetCore package | 513/513 PASS |
| FleetPersistence | 31/31 PASS |
| FleetSecurity | 37/37 PASS |
| FleetNetworking (focused: slash client 12, conversation 20) | 32/32 PASS |
| HermesFleetAppUnitTests (app bundle, sim) | 697/697 PASS (was 692 pre-Build46) |
| Focused UI: U3 settings 1/1, R9 cron 1/1 | PASS |
| Focused UI: ConversationCompactChrome 5/5, Issue4SlashSkill 3/3 | 8/8 PASS |
| UI-matrix audit | 54 CI + 11 environmental = 65 classes, all accounted once |
| theme call-site audit | PASS |
| public-safety guard | PASS |
| gitleaks (staged + new-file tree scan) | clean |
| Release build (generic/platform=iOS, CURRENT_PROJECT_VERSION=47) | BUILD SUCCEEDED, codesign valid |

Full C1 matrix + hosted CI remain to run on the pushed SHA (owner gate G6).

## 10. Delivery record (owner-authorized 2026-09-17)

- **TestFlight build 0.2.0(47)** uploaded from SHA `53e58b2` (dogfood/build-41-integration).
  IPA SHA-256 `3936807c286f78877f06318a6e35a266f6c6b0b1f23057285b6fd647aef126e2`.
  ASC Delivery UUID `8ac2522f-3395-46d7-9d8f-ec151313e5b9`; processing state **VALID**
  (2026-09-17 17:19 CDT); groups: Internal Testers + AIowa; en-US "What's New" set.
  Build number 47 chosen to clear the tainted "46" (two wrong-lineage 46s were
  installed on the device from the mirror repo).
- Local WiFi device install of the Release 47 app attempted at 17:12 CDT: device
  unreachable (CoreDeviceError 4016, phone asleep — owner away). On-disk artifact:
  `build/rc-release-dd/Build/Products/Release-iphoneos/HermesFleetApp.app`.
  TestFlight is the delivery channel for this build.
- Xcode 27.0 (27A266a) was used for archive/export/upload; the release-lane
  script's hard Xcode 26.x check (G5) was superseded by explicit owner
  authorization today (same SDK/toolchain family used for all b4x builds).
