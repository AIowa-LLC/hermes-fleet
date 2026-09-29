# Navigation and surfaces

How the current app is organized: eight top-level destinations, one resource
hub per machine, and a routing model that assigns each screen an owning
destination. This document describes the current integration source;
for module boundaries see
[`architecture.md`](architecture.md).

## Eight top-level destinations

The tab model contains Bots, Chats, Groups, Scheduled, Kanban, Fleet, Settings,
and About. The navigation drawer presents six main destinations plus separate
Settings and About rows.

```text
Bots             Chats             Groups             Scheduled         Kanban
├ Bot roster     ├ sessions        ├ hosted rooms     └ schedules       ├ board chooser
├ Bot Detail     └ Compose         ├ history archive                    └ boards
├ Bot Chat                          └ New Group
└ Routines

Fleet            Settings          About
├ Needs You      ├ Theme           ├ app identity
├ Active Now     ├ Security        ├ version
├ Continue       ├ Data & Storage  ├ Terms / Privacy
├ Gateways       ├ Manage Gateways └ Support
└ Activity       └ Setup prompt

Global: Command Center (opened from the drawer search control)
```

- **Bots** owns the fleet-wide roster, Bot Detail, canonical Bot Chats, and
  Routines. The roster's Groups filter shows matching rooms; selecting a row
  opens that room in Groups.
- **Chats** owns ordinary conversations across gateways. Its unread marks are
  device-local and share read state with drawer Recents.
- **Groups** owns hosted rooms and the historical read-only room archive.
  New Group and room conversations live here, apart from ordinary Chats.
- **Scheduled** is the schedules destination; **Kanban** owns board selection
  and board detail.
- **Fleet** is the glance surface: a compact fact strip, known attention
  items, real execution activity, this phone's recent destinations, gateway
  summaries, and connection activity. It also owns gateway management and
  Gateway Detail. See [`features.md`](features.md#fleet-home-and-coverage-honesty)
  for coverage limits.
- **Settings** owns appearance, accent, security, local data, gateway
  management entry, problem reporting when a runtime is available, and the
  agent setup prompt. Its About row opens the About destination.
- **About** owns app identity, version, and legal/support links.

The Command Center is a search-and-jump sheet opened from the drawer search
control on every destination.

## Ownership model

The shared routing contract assigns each screen exactly one owning
destination:

- ordinary sessions → Chats
- Bot details, canonical Bot Chats, and Routines → Bots
- rooms and RoomLink → Groups
- board selection and boards → Kanban
- gateway-scoped schedules → Fleet; the Scheduled root aggregates schedules
- observed generated media (Artifacts) → Fleet
- gateway registry, Gateway Detail, most gateway resources, and fleet summaries → Fleet; the gateway room index is under Bots and each room conversation is under Groups
- security and local-data settings → Settings
- app identity and legal/support information → About

Shared cross-destination navigation changes to the owning destination and
opens the target there; the source stack is preserved. This includes room
selections from the Bots roster, which open in Groups. Repeated opens of the same exact
destination focus the existing screen instead of stacking duplicates. Back
navigation stays within the destination tab's stack. Popping from a
canonical conversation lands on Bots; popping from an ordinary conversation
lands on Chats — never on whichever tab happened to link in.

## Typed destinations and restoration

Navigation uses a small Codable enum (`FleetScreen`) carrying identity only —
gateway IDs, routes, session IDs, room provenance, board/resource scope.
Payloads never contain credentials, grants, or mutable room-authority
snapshots; capabilities and lineage are re-resolved on arrival.

Per-destination paths are persisted (`fleet.navigation.v1`) and restored on
launch behind the App Lock gate. Legacy destinations are mapped or migrated
when their owner changes: retired Gateways paths return under Fleet, and
saved room destinations move from their former owners to Groups. Deleted or
missing destinations are not silently substituted with same-named objects.

## Artifacts destination

`Artifacts` is a pushed destination on the Fleet stack, opened from the
navigation drawer (compact) or the Command Center's Go-to list (every width).
It lists the generated-image artifacts THIS DEVICE has observed, each with
the gateway that hosts it and the source conversation recorded when the
citation landed — the list is device-local observation, not a fleet-wide
inventory (the gateway publishes no media listing API; nothing is simulated).

- Retrieval is live per row through the gateway's authenticated
  `GET /api/media` (`path` never renders; rows show the basename).
- Expired artifacts (the gateway's cache aged them out) say so and are not
  retried; transient failures offer an explicit Retry.
- In a conversation, a completed `image_generate` result renders inline
  INSIDE the citing tool row. Replayed/reconnected frames re-use the same
  entry (dedupe by gateway + path), and the model's restated path/URL is
  stripped from the rendered reply (the artifact slot is the presentation).
- Removing a gateway prunes its observed artifacts and any retrieved bytes.

## Where the old roots went

| Old surface | Now lives under |
|---|---|
| Registry, connection history, health | Fleet / Gateway Detail |
| Projects, gateway-scoped Kanban and Schedules, Skills, Memory | Fleet / Gateway Detail resource rows; Kanban and Scheduled own their top-level destinations |
| Settings (formerly a Fleet toolbar sheet) | Settings destination |
| Groups (formerly mixed into Chats and other room lists) | Groups destination |
| Version and legal/support links (formerly in Settings) | About destination |
| Command Center | unchanged — global sheet opened by Search in the navigation drawer |

Settings and About are represented as top-level destinations alongside the
six primary destinations; the drawer provides access to the complete set.

## Bot editing availability (Build 43)

Bot Detail's Configuration segment always renders the Edit action. When the
owning gateway answered the latest roster refresh, Edit is enabled and opens
the existing editor (title, description, avatar, SOUL, model, skills,
toolsets, MCP, organization). When the owning gateway is unreachable or the
bot is a last-known ghost, the control stays visible but disabled, with an
explanation naming the owning gateway (e.g. "Editing requires a connection
to this Bot's gateway (Workstation)."); no write is attempted, queued, or
rerouted while offline, and the action re-enables automatically when the
gateway's next successful refresh lands.
