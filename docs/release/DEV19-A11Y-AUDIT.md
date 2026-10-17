# DEV19 L5 — Accessibility sweep audit

Scope: Chats list, Bots list and Bot Detail, Conversation (1:1), Group chat
(`RoomChatView`), Gateways and Gateway Detail, Settings, Pairing (QR scanner
and awaiting-approval), navigation drawer, approval banner. Source lives in
`Packages/FleetUI/Sources/FleetUI` and `Components/`.

Line numbers refer to the base commit `ba3de484` (before this lane's edits).

Method: a `grep` sweep of every `Image(systemName:` and `withAnimation` /
`.animation(` / `.transition(` / `frame(height:` / `lineLimit(1)` in the scope
files, then a read of each interactive or animated site found. Each
`Image(systemName:` in a `Label`, `ContentUnavailableView`, or row with a
sibling `Text` is classed as decorative-or-text-carried and not re-listed.

Coverage caveat: the Chats list rows were not located as a single file in this
lane; the row-level grouping review (see D6, D7) is therefore partial.

## Totals

| Status   | Count |
|----------|-------|
| Found    | 23    |
| Fixed    | 16    |
| Deferred | 7     |

## Fixed (modifiers only)

| # | file:line (base) | Issue | Fix |
|---|------------------|-------|-----|
| F1 | ConversationView.swift:609 | Header Back glyph had a 32pt hit area | `.frame(minWidth: 44, minHeight: 44)` + `.contentShape` (visual unchanged) |
| F2 | ConversationView.swift:622 | Header Menu glyph had a 32pt hit area | same as F1 |
| F3 | ConversationView.swift:1657 | Composer "Add to message" glyph had a 36pt hit area | 44pt minimum frame and `Circle` content shape |
| F4 | ConversationView.swift:1704 | Composer mic glyph had a 36pt hit area | same as F3 |
| F5 | ConversationView.swift:1743 | Composer Send glyph had a 30pt circle hit area | 44pt minimum frame after the background (fill stays 30pt) |
| F6 | ConversationView.swift:2698, 2704 | Copy-confirmation fade ran `withAnimation` without a Reduce Motion gate | `reduceMotion ? nil : ...` on both transitions |
| F7 | RoomChatView.swift:1242 | Decorative lock/bolt glyph read by VoiceOver beside the room name | `.accessibilityHidden(true)` |
| F8 | RoomChatView.swift:1631 | Decorative `chevron.up.forward` prompt glyph read in the composer | `.accessibilityHidden(true)` |
| F9 | FleetNavigationDrawer.swift:278 | Settings destination circle had a 40pt hit area | 44pt minimum frame and `Rectangle` content shape |
| F10 | FleetNavigationDrawer.swift:330 | Drawer `circleAction` had a 34pt hit area | same as F9 |
| F11 | FleetSettingsView.swift:83, 120 | Decorative up/down chevrons read in the Appearance and Accent rows | `.accessibilityHidden(true)` |
| F12 | FleetSettingsView.swift:102 | Accent menu checkmark not hidden, and selected accent not exposed as selected | checkmark hidden; `.accessibilityAddTraits(.isSelected)` on the current accent |
| F13 | GatewaysView.swift:596 | Gateway row ellipsis Menu had no label and a ~28pt target | `.accessibilityLabel("Gateway actions")` and 44pt minimum frame; identifier kept |
| F14 | ApprovalBanner.swift:60 | Decorative shield icon in the "Approval required" label read aloud | `.accessibilityHidden(true)` |
| F15 | ApprovalBanner.swift:200 | Decorative Face ID glyph read inside the Approve button label | `.accessibilityHidden(true)` |
| F16 | Components/SectionHeader.swift:68 | Section title `Text` lacked `.isHeader`, so VoiceOver rotor skipped section headers | `.accessibilityAddTraits(.isHeader)` on `titleView` (used by both layouts) |

## Deferred

| # | file:line (base) | Issue | Why deferred |
|---|------------------|-------|--------------|
| D1 | ConversationView.swift:1812 | Toolbelt chip zone is hard-clamped with `.dynamicTypeSize(...xxxLarge)`, so AX5 users never get the larger sizes there | Deliberate layout cap, not a modifier bug. Lifting it changes the composer and transcript geometry. Needs a product decision. |
| D2 | ConversationView.swift:2002, 2028, 2053, 2109 | Error banners use `.accessibilityElement(children: .combine)` around a labeled Dismiss button. Under VoiceOver the Dismiss action is folded into the banner and can't be reached on its own | Correct fix is `.accessibilityAction(named:)` on the banner, which is a behavior change. Needs a VoiceOver device check. |
| D3 | ConversationView.swift:2084 | Voice-denied row combines children and hides child id `fleet.conversation.voice.denied.settings` from XCUITest | Pre-existing. Un-combining changes the grouping that UI tests and VoiceOver rely on, so it is left alone. |
| D4 | ConversationView.swift:1951 | Attachment filename chip uses `.lineLimit(1)` with the default tail truncation | Low value. Middle truncation would keep the extension visible, but this is a copy-adjacent behavior change. |
| D5 | ConversationView.swift:2390, 2479 | Disclosure chevrons inside text buttons are still read as images | Low impact (the button label already carries the text). Left for a follow-up sweep to keep this lane to the highest-value fixes. |
| D6 | Chats, Bots, and Gateways list rows | No `.accessibilityElement(children: .combine)` added to list rows | Not completed in this lane. Each row must first be checked for child identifiers queried by UI tests (for example `fleet.gateways.row.*`) before it is combined. |
| D7 | Chats list screen | Chats list source was not isolated to a single file, so only the icon-only and motion sweep ran there | Partial coverage. Needs a follow-up pass once the list file is confirmed. |

## Verified, no change needed

- Motion: `WorkingDots` (ConversationView.swift:995) is only rendered when Reduce Motion is off, with a static `ellipsis` glyph otherwise (lines 1190-1202). Scroll-follow animations at lines 1287, 1373, 1429, and 1488 are gated. The tool-group disclosure at 2464 is gated. The user-bubble entrance transition at 2555 and 2628 is gated. The approval banner transition and drawer animation are gated.
- Find-bar controls, the header Find button, the RoomChat send button, and the drawer Menu button already meet 44pt.
- Pairing scanner hero glyphs (`camera.aperture`, `video.slash`) are already hidden.
- `GatewayDetailView` identity glyph is already hidden.
- `BotDetailView` unknown-route and `BotsView` empty/outage icons sit inside `ContentUnavailableView` `Label`s next to text, so the text carries the meaning.
- Headers already exposed with `.isHeader` in FleetNavigationDrawer, PairingAwaitingApprovalView, and others; `SectionHeader` now joins them (F16).
- AX5 handling already present: `ViewThatFits` in GatewaysView and SectionHeader, and `dynamicTypeSize` branching in ApprovalBanner.

## Guard coverage

`AccessibilityIconButtonGuardTests.testIconOnlyButtonLabelsCarryAccessibilityLabel`
(in `HermesFleetAppTests/FleetChatsWiringGuardTests.swift`) is a line and
indentation scan over the scoped files. It flags a `} label: {` whose body is
a bare `Image(systemName:` with no sibling text and no `.accessibilityLabel(`
in the trailing modifier run. Against the base `GatewaysView.swift` it flags the
ellipsis menu (line 595 in the pre-edit copy), so it discriminates. It is a
heuristic, not a Swift parser.
