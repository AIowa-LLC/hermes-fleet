# Feature guide

Hermes Fleet exposes Hermes fleet and session controls in a native iOS interface. Availability can vary with the capabilities provided by a connected gateway. This guide describes source behavior; [`../RELEASES.md`](../RELEASES.md) identifies the source commit and status recorded for each distributed build.

## Navigation surfaces

The app has eight top-level destinations — **Bots, Chats, Groups, Scheduled, Kanban, Fleet, Settings, About** — with separate navigation state and explicit screen ownership. Shared links select the canonical owner and open the target there, including rooms selected from the Bots roster. Command Center is a global search-and-jump sheet. See [`navigation.md`](navigation.md) for the ownership and restoration model.

## Fleet and gateways

- register, edit, test, and remove gateways
- password/session, API key, and token authentication where supported; OAuth-only provider sign-in remains tracked in #61
- connection lifecycle and reconnect controls
- multi-gateway roster aggregation
- bot and session discovery
- per-gateway health information
- QR-assisted gateway pairing
- **Gateway Detail** — per-machine cockpit: identity, contextual connection controls, current work, the machine's Needs You item, and dense resource rows (Bots, Groups, Projects, Kanban, Schedules, Skills, Memory, Connection)

## Fleet Home and coverage honesty

The Fleet tab is a glance surface: a compact fact strip, Needs You, Active Now, Continue, gateway summary rows, and connection activity. Its coverage is deliberately bounded:

- **Needs You is known-items only.** It lists already-observed actionable items — classified gateway authentication/configuration failures plus attention observed in rooms this phone has opened. Unobserved rooms contribute nothing; when gateway coverage is incomplete the section is labeled "N known items" rather than reading as a complete (empty) inbox. Live Ops adds reported approval items from supporting gateways; missing or stale reporting remains explicit.
- **Active Now is real execution only.** Working/thinking/using-tool states come from actual roster signals; a recent worker heartbeat renders as "Recent worker activity", never as executing. Supporting gateways also report Live Ops operations, subagent trees, and timelines. Missing, stale, disconnected, or unsupported coverage stays explicit; unseen bots are not claimed to be idle.
- **Continue is device-local.** A recent-open index stored on this phone (at most 50 references, 30-day retention, pruned when gateways are removed or destinations tombstone). It is not synchronized across devices and implies nothing about other clients.
- **Unknown never renders as zero.** Not-yet-loaded bot counts, partial outages, and unclassifiable gateways display as unknown or partial — never as "0" or "all quiet".

## Live Ops

Fleet Home observes operations and Needs You approvals across reporting gateways.
Operation Detail shows one operation, its subagent tree, and timeline. Approval
actions use the biometric gate; child controls require verified session
attachment. Desktop reporting requires the optional Hermes reporting plugin;
see [setup and coverage](../integrations/hermes-liveops/README.md).

## Conversations

- Chats and drawer Recents apply Hermes Desktop's human-facing Recents rules
  within each gateway/profile and order conversations by last activity.
  Scheduled runs and external messaging threads belong to their own surfaces
  and do not appear as duplicate chats.
- create and resume sessions
- stream assistant output and tool activity
- reconnect and recover missed events
- preserve cached conversation history for cold-start presentation
- show device-local unread indicators in Chats and drawer Recents; existing sessions are baselined on first observation and opening a conversation marks its gateway timestamp as read
- unsent composer drafts persist per conversation: keyed by gateway + profile +
  session ID (canonical Bot Chat included), restored when the conversation
  reopens (navigation, App Lock, relaunch), and cleared only after a successful
  send — a failed send keeps the draft. Drafts are device-local, written
  debounced to a single file with complete file protection and excluded from
  backup, bounded (50 drafts, 20,000 characters each, 30 days), and removed when
  their gateway is removed or local cache is cleared
- approvals and per-session control surfaces
- model selection and context information
- steer, rename, and fork workflows where supported
- session thinking level: a composer gauge button (right cluster, between
  the field and the mic — ChatGPT placement; the needle encodes the level)
  opens a drag slider (overlay above the composer) that sets how much this
  session reasons — eight stops (None/Minimal/Low/Medium/High/Extra
  High/Max/Ultra — the gateway's full effort ladder, verified live),
  session-scoped only, theme-highlight colored; failures surface inline,
  never silent
- attachments and message reactions
- generated-image artifacts: an `image_generate` result is retrieved through
  the owning gateway's authenticated media API and renders inline on the tool
  row that cited it (device-local observed-artifact library behind the
  Artifacts destination)
- a branded, indeterminate animation (FleetWingMark) marks a **verified**
  in-flight `image_generate` call. It carries no percentage or ETA — nothing
  is fabricated — holds still under Reduce Motion, and stops on the result, an
  explicit failure, an interrupt, or a transport drop; the delivered image
  takes its place

Very long conversations use a bounded display window while retaining authoritative cached history separately.

## Bot Mode

The Bots tab is a fleet-wide roster of every bot on every registered gateway. Bots are identified by source-qualified `(GatewayID + ProfileSlug)` identity — same-name bots on different gateways are never merged into one local slug.

- **Bot lifecycle** — create bots; edit name/display name, description, model/provider, SOUL, and Skills/Toolsets/MCP toggles; delete with confirm. Model changes that require confirmation surface the gateway's confirm-required flow honestly.
- **Sections, hidden, pinned** — organize the roster into collapsible sections (deleting a section returns its bots to Unassigned); hide bots from the default view (they remain mentionable); pin bots to the top.
- **Avatars** — real per-bot avatars, upload/clear, and a generated-portrait workflow (preview, then explicit confirm or discard).
- **Canonical Bot Chat** — one continuous chat per bot. `/new` and `/reset` are intercepted and replaced with `/compact` (Bot Chat context is never silently reset). Canonical Bot Chats are filtered out of the ordinary Chats list.
- **`@Bot` mentions** — roster-wide autocomplete with duplicate disambiguation: bare name when unique, `name-gateway-label` when duplicated (`@researcher-mac` vs `@researcher-4090`), and a short deterministic suffix only when the qualified label still collides. Mentions identify teammates; dispatch happens through the agent, not the client.
- **Bot Routines** — structured interval/time-of-day schedules with raw-expression editing; schedules are validated client-side and applied through the profile surface.
- The roster's Groups filter shows matching rooms within Bots; selecting a row opens the room in Groups. See [`groups-tab.md`](groups-tab.md) for the room home and ownership rules.

### Bot Mode limitations

- Cross-gateway `@Bot` DM relay is **not guaranteed by Fleet**: a remote mention passes identity to the agent, but Fleet does not verify or carry the remote messaging route.

## Groups

Groups has a separate fleet-wide home for hosted and archived room conversations. It supports gateway filtering, search by group or member, room navigation, refresh, and a New Group flow. Chats is reserved for ordinary conversations. Shared navigation links route rooms to Groups, including room selections from the Bots roster. Saved room paths from older app versions are migrated when navigation state is restored.

RoomLink capabilities depend on the connected gateways. Cross-gateway room traffic travels between gateways; the iPhone does not relay it in the background. Linked rooms are text-only. Promotion requires explicit confirmation and a caught-up replica; Fleet cannot verify that the previous authority has been externally fenced. See [`groups-tab.md`](groups-tab.md) for the current surface summary.

## Management surfaces

Depending on gateway support, the app includes:

- cron management
- skills management
- Kanban board visibility and task mutations when the connected gateway exposes a board operator
- Projects browsing
- memory/learning graph browsing and supported mutations
- connection-health details

Kanban is read-only when a gateway has no board operator. When that capability
is available, the client sends task creation, updates, and bulk changes to the
gateway; failed writes do not appear as successful local changes.

## Settings and About

Settings is a top-level destination for appearance and accent pickers, app security, local data, gateway management, problem reporting, and the agent setup prompt. About carries the app identity, version, Terms of Use, Privacy Policy, and support links. See [`settings-and-about-tabs.md`](settings-and-about-tabs.md) for the destination ownership summary.

## Voice

Voice input and spoken replies are implemented on the iOS device. Recognized text is submitted through the normal conversation path; the client does not invent a remote-audio gateway protocol when one is not available.

Speech-recognition behavior can vary by locale and platform capability.

## Security and privacy behavior

- credentials and tokens use Keychain-backed storage
- gateway endpoints are normalized at the registry boundary
- sensitive URL material is rejected or redacted
- private infrastructure should never be embedded in fixtures or documentation
- TLS-protected gateway endpoints are preferred

## Capability honesty

Hermes Fleet should not present unsupported gateway methods as available. Feature code should either:

- use a verified gateway capability, or
- fail closed with an explicit unavailable/error state

Simulator fixtures may demonstrate UI behavior, but they do not prove that a particular live gateway deployment exposes the same capability.
