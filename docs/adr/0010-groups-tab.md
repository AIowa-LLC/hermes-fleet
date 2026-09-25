# ADR-0010: Groups as a first-class tab

**Status:** Accepted (dogfood lane `dogfood/build-41-integration`, 2026-09-19 — Tony approved; implementation pending)
**Spec:** [`../groups-tab.md`](../groups-tab.md)

## Context

Groups (hosted and desktop-legacy rooms) currently render inside the Chats
screen as a `Section("Groups")` with rows, an empty state, and a New Group
entry in the floating new-chat menu. Ordinary conversations and groups are
different object types — a conversation is a route+session with outage
retention semantics; a group is a room with members, sync state, and its own
destination (`FleetScreen.room`). Mixing them into one list makes Chats
harder to scan and gives Groups no home surface.

The root shell exposes six tabs (Build 43 order: Bots, Chats, Scheduled,
Kanban, Fleet, Settings). The `gateways`→`fleet` tab retirement (Build 43)
established the decode-time migration pattern for persisted navigation
state (`fleet.navigation.v1`): raw-value keyed paths, remap in the custom
decoder, no wire-format change.

## Decision

1. **Groups becomes a first-class tab, directly under Chats** —
   `FleetTab.groups`, label "Groups", symbol `person.3` (the established
   group icon across roster rows, Gateway Detail, and create flows).
   Enum position fixes the drawer order: Bots, Chats, **Groups**, Scheduled,
   Kanban, Fleet, Settings.
2. **`FleetScreen.room.owner` becomes `.groups`** — every room deep link
   (Command Center, drawer pins, attention items, Gateway Detail, roster
   rows) routes onto the Groups stack.
3. **The Chats screen drops groups entirely** — the Groups section, the
   New Group menu entry, and its `CreateRoomSheet` wiring are removed; the
   floating action button becomes a direct New-conversation button.
4. **The Groups tab is the fleet-wide groups home** — `GroupsHomeView`:
   gateway filter, search, room rows (`RoomRowView` + sync warnings),
   empty state, New Group FAB (moves from Chats), loading/refresh via the
   existing `loadRooms` seam.
5. **Persisted navigation migrates on decode** — `.room` screens in a
   persisted Chats path are moved to the Groups path (order preserved,
   other tabs untouched), following the Build 43 `gateways` remap
   precedent.

## Alternatives rejected

- **Keep groups in Chats under a filter.** Rejected: the reported problem
  is exactly the mixing; a filter adds chrome without separating the
  object types.
- **Groups as a pushed destination (e.g. under Chats or Fleet).** Rejected:
  a pushed screen hides behind navigation, needs manual deep-link wiring
  everywhere, and gives groups no persistent home — the tab is the owning
  surface, matching how Kanban was elevated (Build 41).
- **Move groups OUT of the roster scope picker too.** Rejected for this
  change: the picker is SPEC §9 roster behavior with its own test
  contract; its room taps now route onto the Groups tab anyway. Removing
  it is a separate decision.
- **Bump `fleet.navigation.v1` version.** Rejected: the custom decoder can
  remap in place without breaking older payloads; a version bump would
  discard every user's navigation state unnecessarily.

## Consequences

- The root shell has seven tabs; on iPad the top control paginates past
  five (known UIKit behavior — the universal drawer remains the complete
  entry; Settings already depends on it).
- Chats loses its groups surface — `fleet.chats.groups.empty` and
  `fleet.chats.group.*` identifiers retire (no UITest references today —
  verified by grep; `FleetChatsWiringGuardTests` pins their absence).
- Restored installs land rooms on the Groups tab; users who last had a
  room open restore into it on the Groups stack (selection unchanged).
- Tab-list pins in four UITest classes and `AppCompositionTests` update
  (arrays gain `"groups"`/`"Groups"`); the FOS-5 Chats group tests move to
  the Groups tab; no new UITest class, so no `c1_ui_matrix.sh` change.
- SPEC §9 amendment drafted in the spec; external SPEC file edited only
  on Tony's explicit go.
