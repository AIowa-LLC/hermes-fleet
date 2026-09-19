# Drawer — Codex-parity round 3 (metric pass + dismissal rework)

**Status:** Approved for implementation — 2026-09-18
**Baseline:** lane branch `dogfood/build-41-integration` @ `01de630` (worktree `.worktrees/build-41`)
**Evidence:** `IMG_7116.PNG` (ours, iPhone 17 Pro Max 1320×2868@3x) vs `IMG_7117.PNG` (Codex reference). All pixel measurements below were taken from those rasters programmatically (PIL), not by eye.

## 1. Goal

Close the remaining visual gap between the Fleet navigation drawer and the Codex drawer: type scale, list rhythm, selection treatment, footer composition, and dismissal affordances. Owner decisions (2026-09-18): **(1) neutral-gray selected row, (2) white-on-deep-violet compose pill, (3) remove the ✕ close button for strict parity; add interactive left-swipe dismissal.**

## 2. Measured deltas (ours → reference)

| Metric | Ours | Codex ref | Target |
|---|---|---|---|
| Title glyph height | ≈63 px | ≈62 px | unchanged (`.title2` ≈22 pt) |
| Nav label glyph | ≈56 px | ≈48 px | ≈48 px → `.body` (17 pt) |
| Nav icon height | ≈102–104 px | ≈67–74 px | ≈70 px (~24 pt) |
| Nav row pitch | ≈215–230 px | ≈185 px (62 pt) | ≈186 px (vpad 12 + `.body`) |
| Selected row fill | `#211C35` + violet `#8B5CF6` content | `#212121` + white content | neutral elevated surface + white |
| Section header glyph | ≈56 px `.title3.bold` | ≈37 px | `FleetTheme.sectionHeaderFont` (headline semibold 17) |
| Recents row pitch | ≈105–116 px (≈36 pt) — “paragraph” | (hidden in ref shot) | ≈145–155 px (vpad 10) |
| Compose pill | “New Chat”, ink `#0F1116` on `#8858F0` | “Chat”, white ink on lavender | “Chat”, white ink on fixed `#5B35D5` |
| Gear | solid `tertiarySystemBackground`, adjacent to pill | charcoal glass-look, trailing edge | `.ultraThinMaterial` circle, trailing |
| Close (✕) | present (compact) | absent | removed |

## 3. Work items

All drawer edits are in `Packages/FleetUI/Sources/FleetUI/FleetNavigationDrawer.swift` unless noted. No identifier renames except the planned removals in WI-7.

### WI-1 — Nav type/icon scale (primary rows + Artifacts row)
- `.font(.title3.weight(selected ? .semibold : .regular))` → `.font(.body.weight(selected ? .semibold : .regular))` (both the `ForEach(primaryTabs)` row and the Artifacts row).
- Keep `.imageScale(.large)` (icons land ≈24 pt with `.body`).
- `.padding(.vertical, 13)` → `12` (both).
- Acceptance: label glyph ≈48 px, icon ≈70 px, row pitch ≈186 px on a fresh screenshot; vertical rhythm otherwise unchanged.

### WI-2 — Section headers
- `drawerSection` header: `.font(.title3.weight(.bold))` → `FleetTheme.sectionHeaderFont` (`.headline` semibold, 17 — the existing SPEC §14 token).
- Acceptance: header glyph ≈37 px.

### WI-3 — Selected-row treatment (neutral surface)
- Row background: `theme.highlight.opacity(0.14)` → `FleetTheme.neutralFill` (tab rows + Artifacts row; explicit light/dark values — `surfaceElevated` proved invisible on the light canvas in QA).
- Row content color: `selection == tab ? theme.highlight : theme.textPrimary` → `theme.textPrimary` unconditionally (selection keeps `.semibold` weight as a non-color cue; violet remains for interactive tint and badges).
- AX contract unchanged: `accessibilityValue("Selected")` + `.isSelected` trait stay.
- Acceptance: sampled row fill ≈`#2C2C2E` dark / `#E4E4E9` light; white label+icon; no violet in the selection state.

### WI-4 — Recents row rhythm
- `recentRow`: add `.padding(.vertical, 10)` to the row content.
- Pinned rows (`conversationRow`): keep existing `.padding(.vertical, 10)` (already token-compliant; consistent with recents).
- Acceptance: recents pitch ≈145–155 px; no more “wall of text”.

### WI-5 — Footer composition + glass gear
- Footer `HStack` order: `[pill, gear, Spacer]` → `[pill, Spacer(minLength: 0), gear]` so the gear sits at the drawer's trailing edge (Codex position).
- Gear background: `theme.surfaceElevated` → `.background(.ultraThinMaterial, in: Circle())` + hairline `.overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))`.
  - Rationale: SPEC §14 sanctions Liquid Glass for floating control layers; `.ultraThinMaterial` is the **test-safe** implementation — `.glassEffect()` computes AX hit points at `{-1,-1}` (measured) and breaks XCUITest taps. FleetUI already ships `.ultraThinMaterial` in `FleetDestinations`/`FleetRosterView`.
- Keep identifier `fleet.drawer.destination.settings` (never touched).
- Acceptance: gear trailing edge aligned to drawer trailing inset; vertically centered with pill; frosted translucency visible over scrolled rows.

### WI-6 — Compose pill
- Label text: `"New Chat"` → `"Chat"` (identifier `fleet.drawer.new-chat` unchanged).
- Ink: `.foregroundStyle(theme.background)` → `.foregroundStyle(.white)`.
- Fill: `theme.highlight` → new fixed token `FleetTheme.composeFill` = `#5B35D5` (fixed in both appearances).
  - `FleetTheme.swift`: add `FleetColors.composeFill: UInt32 = 0x5B35D5` + `FleetTheme.composeFill` Color (not appearance-adaptive).
  - `FleetThemeTests`: pin the new token; extend `scripts/fos7_contrast_gate.py` if it enumerates component pairs.
- Contrast: white on `#5B35D5` = **7.2:1** (≥4.5 body) ✓.
- Acceptance: pill width shrinks toward ≈133 pt (label change), white content, sampled fill `#5B35D5`.

### WI-7 — Header: remove ✕ (strict parity)
- Remove the `if compact { circleAction("Close"…) }` block and the `onClose` property + init parameter from `FleetNavigationDrawer`.
- `FleetTabView.swift`: drop the `onClose:` argument at the call site.
- Dismissal story (all preserved or added): scrim tap (exists — `fleet.drawer.scrim`, isButton, label “Close navigation drawer”), auto-dismiss on destination select (exists), and NEW swipe-left (WI-8). VoiceOver users keep an explicit dismiss control via the scrim button.

### WI-8 — Swipe-left dismissal (interactive, ChatGPT-style)
- `FleetTabView.tabShell` (compact drawer block):
  - `@State private var drawerDrag: CGFloat = 0`.
  - Apply `.offset(x: drawerDrag)` to the drawer; attach `.simultaneousGesture(DragGesture(minimumDistance: 16))` with axis lock (`|width| > |height|` else ignore — keeps vertical ScrollView intact).
  - `onChanged`: `drawerDrag = min(0, translation.width)` (leftward follow only). Reduce Motion: no live follow.
  - `onEnded`: dismiss when `translation.width < -max(80, width * 0.25)` **or** `predictedEndTranslation.width < -160`; otherwise spring back to 0 (≈0.2 s ease-out). Dismiss resets `drawerDrag` and flips `drawerPresented` (existing `.move(edge: .leading)` transition plays).
- Applies to iPhone compact and the iPad universal drawer (same code path).

## 4. SPEC §14 amendment (proposed text, apply to `fleet-os-spec/SPEC.md`)

1. **Identity decision (§14):** “…Use a fixed Fleet violet for interactive tint **and selected navigation**, balanced by…” → “…Use a fixed Fleet violet for interactive tint; **navigation selection renders as the neutral elevated surface with primary-label content** (round-3 Codex-parity decision), balanced by…”.
2. **Tokens table, Fleet interactive row:** usage “Links, selected controls, primary action; not arbitrary metadata” → “Links, primary action, compose affordance; **selected navigation uses the neutral elevated surface**; not arbitrary metadata”.
3. **Contrast note (§14):** after “Filled violet buttons use white text in light mode and dark canvas text on the pale dark-mode violet.” add: “**Exception:** the drawer compose pill uses the fixed deep violet `#5B35D5` with white content in both appearances (7.2:1) — round-3 Codex-parity pass.”
4. **§15 motion table:** add row — “Drawer dismissal | Interactive left-swipe follow; spring back below threshold | Reduce Motion: no follow, instant dismiss”. Scrim-tap dismissal already native.

Also update `FleetTheme.swift` doc comments that describe selection as violet (lines ≈164–167) to match.

## 5. Test impact

- **Identifier surface:** `fleet.drawer.close` retired. All other drawer identifiers unchanged.
- **Call-site updates (10 sites / 5 suites)** — replace `app.buttons["fleet.drawer.close"].tap()` with new helper `UITabNavigation.closeDrawer(app)` (scrim tap, deterministic):
  - `U3TabNavigationUITests` (lines 39, 47, 194, 213)
  - `FOS3FourRootShellUITests` (52, 64)
  - `ArtifactsDestinationUITests` (100)
  - `B43NavigationEditingUITests` (58, 70)
  - `CronTabUITests` (61)
- **New coverage (existing class — no `c1_ui_matrix.sh` row change):** `U3TabNavigationUITests.testDrawerSwipeLeftDismisses` — open drawer, `descendants(.any)["fleet.drawer"].swipeLeft()`, assert dismissal (`waitForNonExistence`), re-open works.
- **Helper:** add `closeDrawer(_:)` to `HermesFleetAppUITests/UITabNavigation.swift` next to `openDrawer`.
- No unit-test impact: no token renames (`FleetThemeTests` only gains the new `composeFill` pin); no `project.yml`/pbxproj change (drift gate untouched).

## 6. Validation plan

1. Fresh dedicated sim (`xcrun simctl create DRAWER-R3 "iPhone 18 Pro"`), own derived-data path; fixture seam for drawer states.
2. Screenshot the drawer; re-measure against §2 targets (glyphs/pitch/fills sampled the same way as the reference).
3. Suite run: U3TabNavigation + ArtifactsDestination + FOS3FourRootShell + B43NavigationEditing + CronTab + FOS5BotsGroupsChats, then FULL `HermesFleetAppUnitTests` bundle.
4. Reduce Motion + Increase Contrast spot-checks (drawer + footer).
5. iPad regular-width sanity: universal drawer opens via top control, swipe dismiss works, footer glass renders.
6. Device build per the local WiFi lane when the net is green.

## 7. Out of scope (deferred, with reasons)

- **Canvas `#101216` → `#000000`:** global `canvasDark` token decision, every screen affected — needs its own pass + §14 amendment.
- **Leading chat-bubble icons on Pinned/Recents rows:** Codex's Recents rows are hidden behind the compose pill in the reference shot; need another screenshot before matching.
- **Pinned section empty-state:** unchanged (header-only by design; `ArtifactsDestinationUITests` relies on the header text).
- **Drawer width / header title:** measured within a few px of reference — do not churn.

## 8. QA round 1 (sim, 2026-09-18) — findings folded back

- **Test-helper fix:** `closeDrawer()` taps the scrim's trailing strip
  (normalized 0.9) — the drawer covers the scrim's center on every device, so
  a center tap dismissed nothing. Swipe-left dismissal verified working, and
  the ✕-retired ("close" absent) verification passed.
- **Light-mode fill catch:** `surfaceElevated` (tertiarySystemBackground) is
  invisible on the light canvas — selection and the drawer's circular
  controls now use `FleetTheme.neutralFill` (light `#E4E4E9` / dark
  `#2C2C2E`), pinned in `FleetThemeTests`.
- **Cross-run pin leak (round 2):** FOS5's pin test toggles to "Unpin" when a
  pin written by an earlier suite persists on a shared simulator; `NAV_RESET`
  now clears `fleet.conversation.pins.v1` inside `AppEnvironment.load()` —
  the hydration choke point — because pins hydrate eagerly, before the
  shell's hygiene block runs.
