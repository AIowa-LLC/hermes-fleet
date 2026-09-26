# Unread indicators and read state

**Status:** Approved for spec — Tony approved decisions 1–3; implementation pending.
**Scope:** Dogfood fix for theme-colored unread indicators, drawer Recents parity,
and device-local read state.
**Owner decision recorded:**

1. Existing conversations are baselined as read on first observation so a new
   install does not show every historical chat as unread.
2. Unread indicators appear in both Chats and the drawer's Recents section.
3. The menu badge has no white outline/ring.

**User-facing contract:** Fleet shows one consistent, theme-colored unread dot
beside unread conversations in Chats and drawer Recents; the menu badge follows
the same aggregate, existing sessions are baselined on first observation, new
activity lights a dot, and opening that exact conversation marks it read.

No implementation code, build, simulator run, device operation, gateway
mutation, commit, or external SPEC edit is authorized by this document.

## 1. Evidence and root cause

### 1.1 Cosmetic defect

The notification indicators do not consume the active Fleet theme:

| Surface | Current source | Current behavior | Target |
|---|---|---|---|
| Menu badge fill | `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift:33-43` | `Color.red` | `theme.highlight` |
| Menu badge outline | `FleetTabView.swift:39` | Fixed white 1.5-point ring | No outline |
| Chats title dot | `Packages/FleetUI/Sources/FleetUI/FleetDestinations.swift:297-305` | `Color.blue` | `theme.highlight` |
| Drawer Recents | `Packages/FleetUI/Sources/FleetUI/FleetNavigationDrawer.swift:273-311` | No unread indicator | Same dot as Chats |

The active appearance-resolved highlight already exists at the root theme seam:
`FleetThemeRoot` supplies `EnvironmentValues.fleetTheme`, and the shell reads
`theme.highlight` for interactive controls. The unread shapes must use that seam,
not a second notification color palette. The existing theme contrast correction
remains authoritative in light, dark, and Increase Contrast appearances.

No pixel measurements were performed in this research-only pass. The table above
is source-grounded; screenshot/pixel receipts belong to the later QA pass.

### 1.2 Read-marking defect

The unread dot never clears for real gateway sessions because the read lookup
compares different identity domains:

1. `ConversationView.swift:113-119` uses `viewModel.resolvedSessionID` to find
   the listed `SessionSummary` and then mark it read.
2. `ConversationViewModel.swift:559-565` stores `resumed.sessionID` in
   `openedSessionID`.
3. `ConversationSession.swift:3-18` defines two identities:
   - `sessionID`: the runtime/session-transport identity;
   - `storedSessionID`: the persistent session-list row key.
4. `GatewayConversationClient.swift:188-207` already decodes
   `stored_session_id`, but `ConversationViewModel` does not retain it for the
   read/Continue identity.
5. The real Hermes gateway's `session.resume` response returns a runtime
   `session_id` plus a persistent `stored_session_id`. The runtime value is
   therefore not guaranteed to equal `SessionSummary.id`.

The lookup fails closed by omission: no listed row is found, so
`markConversationRead` is never called. Transport operations must continue to
use the runtime ID; read state and the Continue index must use the durable row
identity.

The scripted fixture masks this contract mismatch. `FleetSimulator.swift:1562-1621`
returns the incoming ID as `ConversationSession.sessionID`, whereas the real
wire can return a distinct runtime ID. The current UI test therefore proves only
the equal-ID fixture case.

### 1.3 Initial all-dot behavior

`FleetUnreadStore` and `AppEnvironment` currently define unread as:

- `lastActive == 0`: unknown, never unread;
- otherwise, `lastActive > stored watermark`;
- missing watermark: treated as `0`.

That rule is valid after a watermark exists, but it floods a new install. The
current Hermes gateway session projection computes a positive activity stamp for
historical sessions with activity and may fall back to `started_at`; the Fleet
client receives that as `lastActive`. Consequently, every previously observed
session can appear unread before the user has ever seen it in Fleet.

The deterministic fixture seeds only one nonzero `lastActive`, so it does not
represent the live fleet's historical-session distribution.

### 1.4 Drawer scope

The authoritative lane currently renders an unread dot only in the Chats list.
`FleetNavigationDrawer` Recents rows have no dot site. This pass adds the same
read-state presentation to Recents. Pinned rows remain unchanged because the
approved request is specifically Chats plus drawer Recents.

## 2. Design decisions

### D1 — One indicator color

All unread dots and the aggregate menu badge use the active appearance-resolved
`theme.highlight`. There is no notification-specific red or blue token. The dot
is a filled shape with no white ring, glow, animation, or semantic status color.

The unread state is also communicated through accessibility text and the menu
badge label; color is never the only state cue. This reuses the existing Fleet
interactive token and does not introduce a new §14 identity decision.

### D2 — Two identity domains, one explicit bridge

The conversation engine keeps the runtime ID for transport, event filtering,
approvals, tooling, history, and prompts. The UI exposes/retains a durable
identity for device-local read state and the Continue index:

- Existing listed conversation: prefer the original `ConversationView.sessionID`
  because it is the exact row key that produced the navigation.
- Newly created conversation: use `ConversationSession.storedSessionID` when
  available.
- Last-resort fallback: use the runtime ID only when no durable ID exists; such a
  fallback must not silently claim that a listed row was marked read.

The durable identity remains source-qualified by `Route`, matching the existing
`fleet.chats.readwatermarks.v1` key shape (`route.id/session.id`).

### D3 — Per-route first-observation baseline

The first successful observation of a route's session list establishes the
baseline for the sessions returned by that observation:

- For each observed session with `lastActive > 0` and no stored watermark, store
  the current server stamp as its read watermark.
- Mark that route as baselined so the same historical sessions do not repeatedly
  reset to read on future refreshes.
- A session ID first observed after that route is baselined is treated as new;
  its positive `lastActive` can light a dot.
- A session whose gateway reports `lastActive == 0` remains unknown and does not
  light a dot.
- Opening a conversation advances only that session's watermark to the listed
  server stamp. It never uses the device clock.
- If a server activity stamp advances after the mark, the dot may legitimately
  reappear.

The baseline must be persisted together with the watermark map and mirrored in
observable AppEnvironment state. The cache-first launch path baselines cached
routes before network revalidation when no route baseline exists, preventing a
first-paint notification flood. A later live stamp that is newer than the cached
watermark remains visible as unread.

`NAV_RESET` clears both watermark data and route-baseline data. A normal relaunch
preserves them. No cross-device or push-notification synchronization is implied.

### D4 — Same state in Chats and drawer Recents

Chats and drawer Recents call the same `AppEnvironment.isConversationUnread`
seam for the same `Route` + persistent session ID. They differ only in layout
and accessibility identifiers. Opening from either surface routes to the same
conversation and clears the same watermark.

The menu badge is the aggregate of the same observable state. It is present if
any loaded session is unread and disappears only after the final unread session
is cleared or otherwise baselined.

## 3. Target presentation

| Element | Old | New | Acceptance metric |
|---|---|---|---|
| Menu badge fill | Fixed red | Resolved `theme.highlight` | Sampled badge fill matches the active theme highlight in light and dark appearances |
| Menu badge outline | Fixed white ring | No outline | No fixed white halo pixels around the badge; no `.white` notification stroke remains |
| Chats dot | Fixed blue | Resolved `theme.highlight` | Chats dot and menu badge resolve to the same theme color for the same appearance |
| Drawer Recents dot | Missing | Dot after the conversation title | Every unread Recents row has one dot; read rows have none; no duplicate dot per row |
| Existing sessions on first route observation | All positive activity can appear unread | Baseline read | Initial baseline fixture shows zero historical unread dots |
| New session after baseline | No explicit contract | Unread when `lastActive > 0` | A new listed session produces one dot in both surfaces |
| Opened listed session | Mark can be skipped by runtime-ID mismatch | Durable row is marked read | Mismatched runtime/stored-ID fixture clears the exact row dot |
| Menu aggregate | Can remain lit because row marks fail | Mirrors the same unread set | Badge transitions visible → hidden after the final row is cleared |

### Accessibility

- Chats dot identifier remains `fleet.chats.unread.<entry.id>`.
- Drawer Recents gets `fleet.drawer.recent.unread.<entry.id>`.
- Both indicators expose the spoken label `Unread` without relying on color.
- The menu badge keeps `fleet.menu.unread-badge` and the existing
  `Unread conversations` label.
- The conversation title remains the primary row identity; the indicator is a
  separate accessible child and must not swallow the row's navigation action.
- Dynamic Type, Increase Contrast, Reduce Transparency, and VoiceOver must keep
  the dot visible or explicitly announced without adding a fixed-color fallback.

## 4. Work items

### W1 — Route indicator colors through the active theme

**Primary files:**

- `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift`
- `Packages/FleetUI/Sources/FleetUI/FleetDestinations.swift`

Add the Fleet theme environment read to `FleetDrawerMenu`. Replace fixed red and
blue notification fills with `theme.highlight`; remove the white badge stroke.
Keep the hamburger mark and its neutral chrome unchanged.

**Acceptance:** no notification indicator uses `Color.red`, `Color.blue`, or a
fixed white outline; screenshot sampling matches the resolved theme token in
both appearances.

### W2 — Add unread dots to drawer Recents

**Primary file:** `Packages/FleetUI/Sources/FleetUI/FleetNavigationDrawer.swift`

Render the dot in the existing Recents title row using the exact entry route and
session ID. Keep pinned rows unchanged. Preserve Recents sorting, filtering,
row navigation, and pinned exclusion.

**Acceptance:** one synthetic unread entry appears with a dot in both Chats and
Recents; opening it from either surface clears both indicators.

### W3 — Preserve durable session identity across resume

**Primary files:**

- `Packages/FleetUI/Sources/FleetUI/ConversationViewModel.swift`
- `Packages/FleetUI/Sources/FleetUI/ConversationView.swift`
- `Packages/FleetCore/Sources/FleetCore/ConversationSession.swift` (only if the
  existing stored-ID seam needs a naming/accessibility adjustment)

Retain the runtime ID for transport and the stored/list ID for read/Continue
operations. Use the exact input list ID for an existing listed navigation and
`storedSessionID` for newly created sessions. Do not change event filtering or
prompt/approval/tooling session IDs.

**Acceptance:** a test double returning `sessionID = runtime-1` and
`storedSessionID = stored-1` still sends transport calls to `runtime-1`, while
read marking and Continue identity use `stored-1`/the original listed row key.

### W4 — Persist a per-route first-observation baseline

**Primary files:**

- `Packages/FleetUI/Sources/FleetUI/FleetUnreadStore.swift`
- `Packages/FleetUI/Sources/FleetUI/AppEnvironment.swift`
- `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift` (NAV_RESET hygiene)

Extend the existing device-local store with route-baseline state. Keep the
observable mirror and persistence twin write-through. Baseline cached routes
before the first live replacement when required; do not overwrite a watermark
for a route already baselined. Keep server stamps as the only timestamp input.

**Acceptance:** first observation produces no historical dots; later activity,
new sessions, and opening/closing behavior survive relaunch; NAV_RESET clears
both watermarks and baseline state.

### W5 — Propagate the aggregate badge to every menu toolbar path

**Primary files:**

- `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift`
- `Packages/FleetUI/Sources/FleetUI/ConversationView.swift`
- `Packages/FleetUI/Sources/FleetUI/RoomChatView.swift`
- `Packages/FleetUI/Sources/FleetUI/FleetRosterView.swift`

Audit every `FleetDrawerMenu()` call. Toolbar paths that own an
`AppEnvironment` must receive the same `anyUnreadSessions` aggregate rather than
silently using the default `false`.

**Acceptance:** the badge has identical state on tab roots, conversations,
room destinations, and other pushed surfaces where the menu control appears.

### W6 — Add regression coverage for the real wire identity contract

**Primary files:**

- Existing `HermesFleetAppUITests/FleetUnreadBadgeUITests.swift`
- `HermesFleetAppTests` unread/environment tests
- `HermesFleetApp/FleetSimulator.swift` only if a DEBUG-only mismatched-ID
  fixture seam is needed

Extend the existing UI test class; do not add a new UI matrix row. Cover:

1. first-observation baseline;
2. Chats dot rendering and clearing;
3. drawer Recents dot rendering and clearing;
4. menu aggregate transitions;
5. distinct runtime/stored IDs;
6. persisted marks and NAV_RESET hygiene;
7. theme-colored indicators in both appearances.

**Acceptance:** the test fails if the implementation compares a runtime ID to a
listed stored ID, and passes only when the durable row clears in both surfaces.

## 5. Test-impact inventory

- **Existing class extended:** `FleetUnreadBadgeUITests`; no `c1_ui_matrix.sh`
  change is needed because no new UI test class is introduced.
- **New accessibility identifier:** `fleet.drawer.recent.unread.<entry.id>`;
  no identifier is retired.
- **Existing identifiers retained:** `fleet.chats.unread.<entry.id>`,
  `fleet.menu.unread-badge`, `fleet.drawer.open`.
- **Existing source contract:** `ConversationSession.storedSessionID` is already
  decoded by the networking client; implementation should consume it rather
  than add a second wire field.
- **Persistence hygiene:** baseline state must be cleared at the same
  `NAV_RESET` choke point as existing unread watermarks.
- **Generated project state:** no project.yml change is expected if the change
  extends existing files. If a new test source is added and project.yml uses an
  explicit source list at implementation time, regenerate with xcodegen and
  verify the project diff.

## 6. Validation plan (later implementation pass)

No build is run for this spec pass. The implementation pass must use the
smallest relevant gates first, then the full net:

1. Hosted unit tests for watermark persistence, route baselines, unknown
   `lastActive == 0`, server-stamp-only marking, and runtime/stored identity.
2. Existing `FleetUnreadBadgeUITests` extended for Chats + drawer Recents and
   aggregate badge transitions.
3. Fresh dedicated simulator, with separate derived data. Capture screenshots
   in light and dark appearances using a deterministic active-theme fixture;
   sample the actual dot/badge pixels against the resolved `theme.highlight`.
4. Run the affected navigation/regression suites covering Chats, drawer,
   conversations, and room destinations. Read `Executed N tests` receipts.
5. Run the full `HermesFleetAppUnitTests` bundle and the complete UI net on
   dedicated simulator resources. Do not share a simulator between xcodebuilds.
6. Run the public-safety guard and staged-scope secret scan for the final change.
7. Verify the lane is clean except for intentional implementation files; do not
   push or create a PR from the dogfood lane without separate authorization.

## 7. Out of scope

- Gateway-side unread/read RPCs or cross-device unread synchronization.
- Push notifications or system notification scheduling.
- Chats ordering changes; `startedAt` ordering remains unchanged.
- Reinterpreting `startedAt` in FleetUI as activity when `lastActive` is unknown.
- Unread dots on pinned drawer rows in this pass.
- New notification colors, red/blue status semantics, badge counts, animation,
  glow, or white outlines.
- Changes to the theme picker, Fleet palette values, selected navigation fill,
  or other §14 identity tokens.
- Canonical Bot Chat inclusion in ordinary Chats unread rows; canonical
  ownership remains governed by the existing Bot Mode path.

## 8. External SPEC amendment draft (not applied)

The external Fleet OS SPEC is not edited by this pass. The following amendment
is the proposed text for the deferred unread requirement in §17:

> **Bounded device-local unread indicators — Class C.** Fleet may present unread
> indicators for ordinary source-qualified conversation rows using durable
> device-local watermarks keyed by `Route` plus the gateway's persistent session
> row identity. On first observation of a route, currently observed sessions are
> baselined read; later server activity stamps and newly observed sessions may
> become unread. Opening a conversation advances that row's watermark using the
> server-provided activity stamp, never the device clock. The state is observable
> in Chats and drawer Recents and may drive a local aggregate menu badge. A zero
> or absent activity stamp is unknown and does not light an indicator. This
> feature does not imply push delivery, server-side read state, or cross-device
> synchronization. Runtime transport session IDs remain distinct from the
> persistent row identity used for local read state.

This draft resolves the current SPEC §17 note that unread state is deferred
because it needs user/device semantics, durable watermarks, and event identity.
The external document remains unchanged until Tony explicitly authorizes that
amendment.

## 9. ADR impact

No new ADR is required for this pass. The change reuses the accepted interactive
theme token and extends an existing device-local watermark design. ADR-0008
(drawer selection/material constraints), ADR-0009 (theme coupling and contrast),
and ADR-0012 (cached-first launch and watermark-backed dots) remain applicable.
No SPEC §14 identity token is added or changed.
