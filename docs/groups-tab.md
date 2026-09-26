# Groups tab: separating groups from chats

**Status:** Spec — approved by Tony (2026-09-19, decisions 1–3 accepted with my recommendations).
**Lane:** `dogfood/build-41-integration` (this file rides the implementation commit).
**Companion decision record:** [`adr/0010-groups-tab.md`](adr/0010-groups-tab.md)

## Problem

Groups (hosted/legacy rooms) are mixed into the Chats screen as a `Section("Groups")` with rows, an empty state, and a New Group entry in the floating new-chat menu. Groups are a different object type than ordinary conversations: they have members, sync state, and their own destination (`FleetScreen.room`). Mixing them into Chats makes the Chats list harder to scan and gives Groups no home surface.

## Current state (measured)

| Element | Where today |
| --- | --- |
| Tab enum | `FleetTab`: `bots, chats, cron, kanban, fleet, settings` (FleetTabView.swift:23-52) |
| Chats' Groups section | `FleetDestinations.swift:243-265` — rows via `NavigationLink(value: FleetScreen.room(...))`, empty state `fleet.chats.groups.empty`, filter `groups` computed at 154-159 |
| New Group in Chats | `FleetDestinations.swift:460-465` — Menu item + `showingGroupCompose` state + `CreateRoomSheet` at 384-388 |
| Room ownership | `FleetScreen.room.owner == .chats` (FleetScreen.swift:35) |
| Groups on other surfaces | Roster scope picker (SPEC §9, untouched); Gateway Detail groups list; Command Center `group:` results; drawer pinned `.group` rows; attention items → `.room` |
| Nav-state persistence | `fleet.navigation.v1` — `[FleetTab: [FleetScreen]]` keyed by raw value; `gateways`→`fleet` remap precedent in the custom decoder (FleetScreen.swift:98-153) |

## Work items

### W1 — `FleetTab.groups` (position: directly under Chats)

**File:** `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift` (enum at lines 23-52)

| Old | New |
| --- | --- |
| `case bots, chats, cron, kanban, fleet, settings` | `case bots, chats, groups, cron, kanban, fleet, settings` |
| — | label: `"Groups"` |
| — | systemImage: `"person.3"` |

- `isPrimary` (`self != .settings`) automatically includes Groups — drawer renders it in the Navigate section, in enum order: Bots, **Chats, Groups**, Scheduled, Kanban, Fleet (Settings separate). "Directly under Chats" satisfied by enum position.
- iPad `sidebarAdaptable`: 7 cases now — the top control paginates past five (UIKit hides the trailing bar button). Known accepted behavior (the universal drawer remains the always-visible complete entry). `hostedTabs`/`tabs` unchanged mechanically.

**Acceptance:** `FleetTab.allCases.map(\.label)` == `[Bots, Chats, Groups, Scheduled, Kanban, Fleet, Settings]` (unit pin, updated in AppCompositionTests); drawer exposes `fleet.drawer.destination.groups` between `chats` and `cron` (UI test loops updated); every SF Symbol resolves (`testEveryTabSystemImageResolvesToRealSFSymbol` auto-extends).

### W2 — `FleetScreen.room.owner` → `.groups`

**File:** `Packages/FleetUI/Sources/FleetUI/FleetScreen.swift:35`

| Old | New |
| --- | --- |
| `case .room: .chats` | `case .room: .groups` |

Reroutes every deep link into the room destination — Command Center, drawer pins, attention items, Gateway Detail, roster rows — onto the Groups stack. This is the desired unification.

### W3 — Decode-time migration of persisted `.room` screens

**File:** `Packages/FleetUI/Sources/FleetScreen.swift` (custom decoder, lines 111-141)

Persisted Chats paths from installs that used groups (the phone, sims) contain `.room` screens. Without migration, a restored Chats stack would push RoomChatView — now off-owner — and `open(.room)` from Chats would push on the wrong stack.

| Old | New |
| --- | --- |
| decode per-key `screens` appended verbatim into `merged[tab]` | after decoding each tab's screens, `.room` screens are REMOVED from the `chats` path and appended to the `groups` path (order preserved, dedupe) |

- Pre-`groups` installs restore rooms under the new tab; `selection` untouched (a restored selection of `chats` stays Chats; `raw "groups"` is now a live case, no remap needed).
- Wire-format: unchanged array-of-pairs shape; `groups` key appears only in post-change payloads.

**Acceptance:** new hosted units — restore with a persisted chats path containing `.room` → rooms land in `paths[.groups]`, chats path loses them, other tabs untouched; round-trip encode/decode byte-shape unchanged for non-room payloads.

### W3b — `legacyTab` mapping

`FleetScreen.swift:155-168`: add `case "groups": .groups` for AUTO_NAV/legacy-name support (no current producer, defensive).

### W4 — New `GroupsHomeView` (the Groups tab root)

**File:** new — `Packages/FleetUI/Sources/FleetUI/GroupsHomeView.swift`

Structure (mirrors Chats' proven patterns):

- List with gateway filter (same `Picker` seam as Chats), per-room rows reusing `RoomRowView` + `roomSyncWarnings` badge + unavailable-host states, search (`searchable` prompt "Search groups and members"), empty state (`ContentUnavailableView` — "No groups yet" / filter-aware variants), background loading row, bottom breathing room (`FleetChatsListLayout.bottomBreathingRoom`), `fleet.groups` surface id, `.scrollContentBackground(.hidden).background(theme.background)`, `navigationTitle("Groups")`.
- `NavigationLink(value: FleetScreen.room(room.id))` rows — deep-link parity with every other surface.
- Rows in the flat fleet-wide order Chats used (same `groups` computed logic: `environment.allRooms`, gateway filter, query match on name + member names, sorted by canonical identity for stability).
- Room availability: room list reflects `environment.allRooms` only — no outage retention semantics (rooms are roster-driven, not session-driven). A room whose host gateway is removed simply disappears (FOS-5 retention applies to conversations, not rooms).
- `.task { await environment.loadRooms() }` + `.refreshable { await loadRooms(force) }` — same load seam as Chats today (AppEnvironment.loadRooms already re-reads all gateway rooms).

**Acceptance:** `fleet.groups` renders; groups rows navigable; empty state identifier `fleet.groups.empty` with filter-aware copy; new hosted unit pins the row set from a scripted environment (count + order).

### W5 — Chats diet

**File:** `Packages/FleetUI/Sources/FleetUI/FleetDestinations.swift`

| Old | New |
| --- | --- |
| `Section("Groups")` block (243-265) | deleted |
| `groups` computed var (154-159) | deleted |
| `showingGroupCompose` state (110) + sheet (384-388) | deleted |
| New-chat Menu: `New conversation` + `New Group` items (452-465) | single `New conversation` button — no Menu wrapper needed |
| `CreateRoomSheet` usage | removed from Chats (moves to Groups tab W4) |

- `fleet.chats.groups.empty`, `fleet.chats.group.<id>` identifiers retired (grep-verified absence in UITests: no references today — the FOS5 suite asserts the roster's `fleet.room.row.*` and menu labels, not these ids).
- The single-entry FAB keeps its glass circle + `square.and.pencil` glyph; `fleet.chats.new` identifier and behavior (opens `ComposeBotPickerSheet`) unchanged.

**Acceptance:** `fleet.chats` renders no Groups section (UI test asserts absence); New Group not offered in Chats (menu gone — the FAB directly opens the bot picker); Chats unit/source-guard tests updated (`FleetChatsWiringGuardTests` gains the absence pin).

### W6 — FleetTabView wiring

**File:** `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift`

| Old | New |
| --- | --- |
| `root(_ tab:)` switch (357-369) | `case .groups: GroupsHomeView(environment: environment)` |
| drawer `onNewChat` (196-200) | unchanged (Chats roster) |
| `performAutoNavIfNeeded` (436+) | `if autoNav == "groups" { navigation.selection = .groups }` — new AUTO_NAV lane for UI tests |

### W7 — FleetNavigationState path fixup (optional seam)

`open()` already routes by `screen.owner` — W2 makes `.room` open on Groups everywhere. No change needed here beyond W3's decode migration. (Explicitly listed to show it was considered.)

### W8 — Tests

| Asset | Change |
| --- | --- |
| `AppCompositionTests.testAppTabModelCoversFiveOwningDomains` | array gains `"Groups"` after `"Chats"` (6→7) + comment; SF-symbol/uniqueness loops auto-extend |
| `U3TabNavigationUITests` (two drawer loops: 30-60, 180-220) | raw arrays gain `"groups"` |
| `B43NavigationEditingUITests` (40-72) | raw arrays gain `"groups"`; iPad `labels` array gains `"Groups"`; tab-bar label equality gains `"Groups"` |
| `FOS3FourRootShellUITests` (35-70) | raw arrays gain `"groups"`; `labels` array + count 6→7 |
| `FOS5BotsGroupsChatsUITests.testChatsFloatingClusterNewChatAndSettings` (149-175) | remove `New Group` menu assertions; FAB is now a direct button |
| `FOS5BotsGroupsChatsUITests.testChatsNewGroupCreatesAndOpensCrossGatewayRoom` (280-358) | rewrite: New Group entry moved to Groups tab — navigate to Groups (drawer), FAB opens CreateRoomSheet, create cross-gateway room, assert `fleet.room.chat` opens ON the Groups stack |
| `FOS5BotsGroupsChatsUITests` scope-picker + terminology tests | untouched (roster surface, SPEC §9) |
| `FleetChatsWiringGuardTests` | new pins: Chats source no longer contains `CreateRoomSheet`, `showingGroupCompose`, `Section("Groups")` |
| New hosted units (in `FOS5BotsGroupsChatsTests`) | nav-state migration (W3), Groups row set, `FleetScreen.room.owner == .groups` |
| `c1_ui_matrix.sh` | NO change — extending existing classes only (FOS5 suite covers the new surface) |
| New UITest class for Groups tab? | none — FOS5 extensions cover it |

### W9 — Docs

- ADR-0010 (companion, this change).
- `docs/README.md` only if it enumerates tabs (check; likely no).
- ADR-0008 addendum not needed (drawer structure unchanged — Groups is just another primary row).

## Test impact summary

**No AX identifier retirements that break existing tests** (`fleet.chats.group.*` and `fleet.chats.groups.empty` are unreferenced in UITests — verified by grep). The retired strings are still removed from the source, so `FleetChatsWiringGuardTests` guards their absence.

| Surface | Effect |
| --- | --- |
| Tab list pins (4 UITest classes + AppCompositionTests) | arrays updated with `"groups"`/`"Groups"` |
| FOS5 Chats group tests | 2 tests rewritten (menu → FAB; creation moved to Groups tab) |
| Nav-state migration | new hosted unit |
| Roster/GatewayDetail/CommandCenter | no test edits (owner reroute is behavior-preserving for them — they route by `.room` value) |
| c1_ui_matrix | no new class → no row |

## Validation plan

1. Fresh dedicated sim `QAGROUPS` (`iPhone 18 Pro`), own `-derivedDataPath`, deleted after; `pgrep xcodebuild` first.
2. Targeted units: `AppCompositionTests`, `FOS5BotsGroupsChatsTests`, `FleetChatsWiringGuardTests`, `FleetChatsPresentationTests`.
3. Targeted UI: `FOS5BotsGroupsChatsUITests`, `U3TabNavigationUITests`, `B43NavigationEditingUITests`, `FOS3FourRootShellUITests`, `ConversationCompactChromeUITests` (drawer-heavy regression).
4. Full unit bundle (`HermesFleetAppUnitTests`).
5. Nav-restore evidence run: seed persisted nav state with a chats-path `.room`, relaunch with restore, assert the room lands on Groups (new UI test or hosted unit with the exact restore seam).
6. Long runs backgrounded, per-suite logs + `Executed N tests` receipts under `/tmp/qagroups/`.

## SPEC §9/§14 amendment draft (external file — awaits explicit go)

The SPEC's tab/destinations model (§9 navigation) describes the five-tab root shell. Draft amendment:

> **Amendment (dogfood build-41): Groups is a first-class tab.** The root shell exposes seven destinations: Bots, Chats, Groups, Scheduled, Kanban, Fleet, Settings — Groups directly under Chats. The Chats screen lists ordinary conversations only; group rows, the New Group entry, and room destinations live on the Groups tab. The roster's All/Bots/Groups scope picker (§9) is unchanged and routes room taps onto the Groups stack. Persisted navigation state migrates room entries from the Chats stack to the Groups stack on decode. (ADR-0010.)

External SPEC file edited only on Tony's explicit go.

## Out of scope

- Roster scope picker / Gateway Detail groups list / Command Center group results — untouched (they route by `.room` and now land on Groups; their own UI is unchanged).
- RoomChatView internals, room sync warnings, hosted/legacy room semantics.
- iPad tab-pagination redesign (7 cases paginate in the top control; the drawer is the complete entry — accepted).
- Commit/push/PR/TestFlight — lands as one lane commit on go; WiFi device build after QA green.
