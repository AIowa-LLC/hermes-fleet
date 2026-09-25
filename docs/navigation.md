# Navigation and surfaces

How the current app is organized: five tabs, one resource hub per machine, and
a routing model that keeps every object in exactly one owning tab. This
document describes shipped behavior; for module boundaries see
[`architecture.md`](architecture.md).

## The five tabs (Build 43)

```text
Bots                     Chats                     Kanban                    Fleet                        Settings
├ fleet-wide roster      ├ ordinary conversations  ├ board chooser           ├ Needs You                  ├ App Lock
├ Create / organize      └ Compose → new chat      ├ interactive board       ├ Active Now                 ├ Local data
└ Bot Detail                                        └ (board detail)          ├ Continue                   ├ Appearance
  ├ Bot Chat                                                                   ├ Gateways                   ├ Theme editor
  ├ Conversations                                                               │  ├ compact rows            ├ Set Up Another Server
  ├ Routines                                                                    │  └ Manage Gateways →       └ Version / Privacy / Support
  └ Configuration                                                               │     full registry cockpit
    └ Edit / Duplicate / Delete                                                  └ Connection activity
                                                                                (deeper: Gateway Detail →
                                                                                 Bots / Groups / Projects /
                                                                                 Kanban / Schedules / Skills /
                                                                                 Memory / Connection)
Settings: fifth tab (Build 43; was a Fleet-toolbar sheet)   Global: Command Center (every tab toolbar, ⌘K)
```

- **Bots** owns the fleet-wide roster, Bot Detail, canonical Bot Chats,
  Routines, and Groups/RoomLink. It is the launch tab.
- **Chats** owns ordinary human sessions across gateways.
- **Kanban** owns the board chooser and interactive boards.
- **Fleet** is the glance surface: a compact fact strip, known attention
  items, real execution activity, this phone's recent destinations, compact
  gateway rows, and connection activity. Since Build 43 it also owns
  **gateway management**: the Gateways section's "Manage Gateways" entry
  pushes the full registry cockpit (add / edit / pair / connect / remove),
  and Gateway Detail's resource rows live beneath it. See
  [`features.md`](features.md#fleet-home-and-coverage-honesty) for exactly
  what is and is not covered.
- **Settings** is a first-class tab (Build 43): App Lock, local data,
  appearance, the theme editor, setup prompt, version/help. It replaced the
  Fleet-toolbar gear sheet; no competing presentation exists.

Command Center is a global search-and-jump sheet (`⌘K` with a hardware
keyboard) reachable from every tab's toolbar; its Go-to list selects tabs
directly.

## Ownership model

Every screen has exactly one owning tab:

- ordinary sessions → Chats
- Bot details, canonical Bot Chats, Routines → Bots
- Groups and RoomLink → Bots
- Kanban boards → Kanban
- gateway management, gateway resources, and diagnostics → Fleet (via
  Manage Gateways / Gateway Detail)
- fleet summaries (attention, activity, Continue, connection activity) → Fleet
- observed generated media (Artifacts) → Fleet (a pushed destination; the
  navigation drawer's Navigate section opens it)

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
behind the App Lock gate. Legacy values from older builds map forward:
`home` → Fleet; `control`, `workspace`, `projects`, `gateways` → Fleet
(gateway management moved under Fleet in Build 43 — a persisted `gateways`
tab selection or stack restores onto Fleet without discarding unrelated
tabs' saved paths); `settings` → the Settings tab. Deleted or missing
destinations are not silently substituted with same-named objects.

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
| Registry, connection history, health | Fleet → Manage Gateways / Gateway Detail |
| Projects, Kanban boards, Schedules, Skills, Memory | Gateway Detail resource rows |
| Settings (was a Fleet-toolbar sheet) | Settings tab (fifth, Build 43) |
| Gateways tab (retired Build 43) | Fleet → Manage Gateways pushes the registry cockpit |
| Command Center | unchanged — global toolbar sheet |

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
