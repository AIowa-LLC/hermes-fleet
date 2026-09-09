# Feature guide

Hermes Fleet exposes Hermes fleet and session controls in a native iOS interface. Availability can vary with the capabilities provided by a connected gateway.

## Navigation surfaces

The app is organized into four tabs — **Fleet, Chats, Bots, Gateways** — each owning an independent navigation stack. Every screen has exactly one owning tab; cross-tab links change to the owner and open the target there. Settings is a sheet from the Fleet toolbar; Command Center is a global search-and-jump sheet. See [`navigation.md`](navigation.md) for the full ownership model and restoration behavior.

## Fleet and gateways

- register, edit, test, and remove gateways
- multiple authentication strategies
- connection lifecycle and reconnect controls
- multi-gateway roster aggregation
- bot and session discovery
- per-gateway health information
- QR-assisted gateway pairing
- **Gateway Detail** — per-machine cockpit: identity, contextual connection controls, current work, the machine's Needs You item, and dense resource rows (Bots, Groups, Projects, Kanban, Schedules, Skills, Memory, Connection)

## Fleet Home and coverage honesty

The Fleet tab is a glance surface: a compact fact strip, Needs You, Active Now, Continue, gateway summary rows, and connection activity. Its coverage is deliberately bounded:

- **Needs You is known-items only.** It lists already-observed actionable items — classified gateway authentication/configuration failures plus attention observed in rooms this phone has opened. Unobserved rooms contribute nothing; when gateway coverage is incomplete the section is labeled "N known items" rather than reading as a complete (empty) inbox. There is no fleet-wide pending-action summary.
- **Active Now is real execution only.** Working/thinking/using-tool states come from actual roster signals; a recent worker heartbeat renders as "Recent worker activity", never as executing. There is no fleet-wide execution telemetry — unseen bots are not claimed to be idle, and incomplete coverage renders honest copy instead of a partial list dressed as the whole fleet.
- **Continue is device-local.** A recent-open index stored on this phone (at most 50 references, 30-day retention, pruned when gateways are removed or destinations tombstone). It is not synchronized across devices and implies nothing about other clients.
- **Unknown never renders as zero.** Not-yet-loaded bot counts, partial outages, and unclassifiable gateways display as unknown or partial — never as "0" or "all quiet".

## Conversations

- create and resume sessions
- stream assistant output and tool activity
- reconnect and recover missed events
- preserve cached conversation history for cold-start presentation
- approvals and per-session control surfaces
- model selection and context information
- steer, rename, and fork workflows where supported
- attachments and message reactions

Very long conversations use a bounded display window while retaining authoritative cached history separately.

## Bot Mode

The Bots tab is a fleet-wide roster of every bot on every registered gateway. Bots are identified by source-qualified `(GatewayID + ProfileSlug)` identity — same-name bots on different gateways are never merged into one local slug.

- **Bot lifecycle** — create bots; edit name/display name, description, model/provider, SOUL, and Skills/Toolsets/MCP toggles; delete with confirm. Model changes that require confirmation surface the gateway's confirm-required flow honestly.
- **Sections, hidden, pinned** — organize the roster into collapsible sections (deleting a section returns its bots to Unassigned); hide bots from the default view (they remain mentionable); pin bots to the top.
- **Avatars** — real per-bot avatars, upload/clear, and a generated-portrait workflow (preview, then explicit confirm or discard).
- **Canonical Bot Chat** — one continuous chat per bot. `/new` and `/reset` are intercepted and replaced with `/compact` (Bot Chat context is never silently reset). Canonical Bot Chats are filtered out of the ordinary Chats list.
- **`@Bot` mentions** — roster-wide autocomplete with duplicate disambiguation: bare name when unique, `name-gateway-label` when duplicated (`@researcher-mac` vs `@researcher-4090`), and a short deterministic suffix only when the qualified label still collides. Mentions identify teammates; dispatch happens through the agent, not the client.
- **Bot Routines** — structured interval/time-of-day schedules with raw-expression editing; schedules are validated client-side and applied through the profile surface.
- **Hosted Groups** — create rooms on a gateway, chat (`groups.send`), replay history (`groups.log`), rename, stop, retry, resolve pending approvals, and disband.
- **Cross-gateway Groups** — invite bots from other gateways into a hosted room. Setup choreography: create on the home gateway, invite on the target, register on the home gateway. Afterwards the gateways exchange room traffic **directly with each other** (upstream RoomLink); the iPhone is controller-only.
- **RoomLink panel** — per-room negotiation state (honest unsupported reason when the gateway disables RoomLink), scoped peer grants with explicit TTL and revocation, route registration using the target's exact advertised capability catalog (never a reconstruction), linked-peer status, manual replay/replication, and authority takeover with an explicit, previous-authority-naming confirmation.
- **Replication/promotion semantics** — replay submits the authority's verbatim log pages to the target replica (`groups.replicate` is idempotent and refuses sequence gaps and epoch regressions). Promotion continues the room on the promoting gateway at `epoch + 1` and fences the previous authority; it is only offered for a caught-up replica of a foreign authority and always requires explicit confirmation.

### Bot Mode limitations

- Cross-gateway `@Bot` DM relay is **not guaranteed by Fleet**: a remote mention passes identity to the agent, but Fleet does not verify or carry the remote messaging route.
- Cross-gateway rooms are text-only (upstream RoomLink advertises `attachments: false`).
- The iPhone performs no background couriering of room traffic; gateway-to-gateway linking is the gateways' own direct connection.

## Management surfaces

Depending on gateway support, the app includes:

- cron management
- skills management
- read-only Kanban board visibility
- Projects browsing
- memory/learning graph browsing and supported mutations
- connection-health details

The Kanban surface is intentionally read-only in the current client.

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
