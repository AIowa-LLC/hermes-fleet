# Navigation and surfaces

How the current app is organized: four tabs, one resource hub per machine, and
a routing model that keeps every object in exactly one owning tab. This
document describes shipped behavior; for module boundaries see
[`architecture.md`](architecture.md).

## The four tabs

```text
Fleet                    Chats                     Bots                         Gateways
├ Needs You              ├ ordinary conversations  ├ Bot Detail                 ├ Gateway Detail
├ Active Now             └ Compose → new chat      │ ├ Bot Chat                 │ ├ Bots (gateway filter)
├ Continue                                         │ ├ Conversations            │ ├ Groups (gateway filter)
├ Gateway summary rows                             │ ├ Routines                 │ ├ Projects → project/lanes
└ Connection activity                              │ └ Configuration            │ ├ Kanban → board
                                                   └ Group                      │ ├ Schedules → profile
                                                     ├ Conversation             │ ├ Skills → profile
                                                     └ Details → RoomLink       │ ├ Memory → profile
                                                                                └ Connection / capabilities
Fleet toolbar: Settings sheet                     Global: Command Center       └ Add Gateway
```

- **Fleet** is the glance surface: a compact fact strip, known attention
  items, real execution activity, this phone's recent destinations, compact
  gateway rows, and connection activity. See
  [`features.md`](features.md#fleet-home-and-coverage-honesty) for exactly
  what is and is not covered.
- **Chats** owns ordinary human sessions across gateways.
- **Bots** owns the fleet-wide roster, Bot Detail, canonical Bot Chats,
  Routines, and Groups/RoomLink.
- **Gateways** owns the machine registry and **Gateway Detail**, the cockpit
  for one machine: identity, connection controls, current work, the
  machine's Needs You item, and dense resource rows (Bots, Groups, Projects,
  Kanban, Schedules, Skills, Memory, Connection/capabilities).

Settings is a sheet opened from the Fleet toolbar gear (all tabs keep their
own stacks under it). Command Center is a global search-and-jump sheet
(`⌘K` with a hardware keyboard) reachable from every tab's toolbar.

## Ownership model

Every screen has exactly one owning tab:

- ordinary sessions → Chats
- Bot details, canonical Bot Chats, Routines → Bots
- Groups and RoomLink → Bots
- gateway resources and diagnostics → Gateways (via Gateway Detail)
- fleet summaries (attention, activity, Continue, connection activity) → Fleet

Cross-tab navigation changes to the owning tab and opens the target there;
the source tab's stack is preserved. Repeated opens of the same exact
destination focus the existing screen instead of stacking duplicates. Back
navigation stays within the destination tab's stack. Popping from a
canonical conversation lands on Bots; popping from an ordinary conversation
lands on Chats — never on whichever tab happened to link in.

## Typed destinations and restoration

Navigation uses a small Codable enum (`FleetScreen`) carrying identity only —
gateway IDs, routes, session IDs, room provenance, board/resource scope.
Payloads never contain credentials, grants, or mutable room-authority
snapshots; capabilities and lineage are re-resolved on arrival.

Per-tab paths are persisted (`fleet.navigation.v1`) and restored on launch
behind the App Lock gate. Legacy tab names from older builds map forward:
`home` → Fleet; `control`, `workspace`, `projects`, `kanban` → Gateways.
Deleted or missing destinations are not silently substituted with same-named
objects.

## Where the old roots went

The former Control and Workspace tabs were retired and redistributed:

| Old surface | Now lives under |
|---|---|
| Registry, connection history, health | Gateways tab / Gateway Detail |
| Projects, Kanban, Schedules, Skills, Memory | Gateway Detail resource rows |
| Settings (was its own tab) | Fleet toolbar gear sheet |
| Command Center | unchanged — global toolbar sheet |

There is no fifth tab, no Work tab, and no standalone Control or Workspace
surface in the current shell.
