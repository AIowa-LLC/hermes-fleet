# Theme-coupled compose pill + White accent

**Status:** Spec — approved by Tony (decisions 1–3, 2026-09-19). Not yet implemented.
**Lane:** `dogfood/build-41-integration` (this file rides the implementation commit).
**Companion decision record:** [`adr/0009-compose-pill-theme-coupling-and-white-accent.md`](adr/0009-compose-pill-theme-coupling-and-white-accent.md)

## Problem

1. The drawer's Chat button ignores the user's accent entirely: it fills with
   `FleetTheme.composeFill`, a token fixed to `#5B35D5` in both appearances
   (ADR-0008 round-3 Codex parity). Whatever accent is picked in Settings, the
   pill stays violet.
2. The Settings accent picker offers seven curated colors (Blue, Green, Yellow,
   Pink, Orange, Purple, Black). White is not among them, and cannot be added
   naively: a literal `#FFFFFF` highlight over the light Fleet canvas
   (`#F8F9FC`) measures **1.05:1**, below the `FleetThemeController.apply`
   invisible-pair guard (`invisibleRatio = 1.2`), so the controller refuses
   it. White highlights are only viable in dark mode.

## Measured before → targets

| Element | Before (measured) | Target | Ratio check |
| --- | --- | --- | --- |
| Pill fill (light, default palette) | fixed `#5B35D5` | `theme.highlight` → `#5B35D5` (unchanged) | white ink 7.20:1 |
| Pill fill (dark, default palette) | fixed `#5B35D5` | `theme.highlight` → `#FFFFFF` (B41 dark default) | dark ink 19.42:1 |
| Pill ink | hardcoded `.white` | `theme.onHighlight` (max-contrast ink seam) | see table below |
| Accent set | 7 (`black` = `#2C2C2E` both modes) | 8 — White as a monochrome accent: `#1C1C1E` light / `#FFFFFF` dark | 16.16:1 / 18.75:1 on canvas |

**Ink on the pill per accent** (`FleetThemeContrast.maxContrastInk` semantics —
the higher-contrast ink wins, exact ratios):

| Accent (fill) | Ink chosen | Ratio |
| --- | --- | --- |
| default violet `#5B35D5` | white | 7.20:1 |
| Blue `#0A84FF` | dark `#0D0D0F` | 5.32:1 |
| Green `#30B94D` | dark | 7.56:1 |
| Yellow `#E2B203` | dark | 9.80:1 |
| Pink `#FF2D8A` | dark | 5.54:1 |
| Orange `#FF8A00` | dark | 8.22:1 |
| Purple `#8B5CF6` | dark | 4.59:1 |
| Black `#2C2C2E` | white | 13.94:1 |
| White (light) `#1C1C1E` | white | 17.01:1 |
| White (dark) `#FFFFFF` | dark | 19.42:1 |

Note: ChatGPT renders white ink on its blue pill (3.65:1) — below our
body-text floor. We keep the max-contrast ink seam instead; saturated accents
render dark ink on the pill.

## Work items

### W1 — Couple the drawer pill to the theme

**File:** `Packages/FleetUI/Sources/FleetUI/FleetNavigationDrawer.swift` (footer, ~lines 173–187)

| Old | New |
| --- | --- |
| comment: "The pill is the fixed deep Fleet violet with white content in both appearances (white-on-#5B35D5 = 7.2:1)" | comment: fill follows the active theme highlight; ink is the guaranteed-legible `onHighlight` token |
| `.foregroundStyle(.white)` (line 181) | `.foregroundStyle(theme.onHighlight)` |
| `.background(FleetTheme.composeFill, in: Capsule())` (line 184) | `.background(theme.highlight, in: Capsule())` |

Layout, padding, `Capsule()`, label text, and the AX identifier
`fleet.drawer.new-chat` are untouched.

**Acceptance:** sampled pill fill in a rendered screenshot — light + default
palette `#5B35D5`; dark + default palette `#FFFFFF` with dark ink; Blue accent
selected `#0A84FF`. Screenshot sampling per
`scripts/measure_drawer_screenshot.py` (RGB cluster sample, tolerance ±3 per
channel to allow compositor rounding).

### W2 — Remove the `composeFill` token (full removal, not orphan)

**File:** `Packages/FleetUI/Sources/FleetUI/FleetTheme.swift`

| Old | New |
| --- | --- |
| `FleetColors.composeFill: UInt32 = 0x5B35D5` (~lines 27–32, incl. doc comment) | deleted |
| `FleetTheme.composeFill: Color` (~lines 187–193, the non-adaptive `UIColor` closure) | deleted |

**Acceptance:** `git grep composeFill -- '*.swift'` returns zero hits;
project builds. (Historical mentions in `docs/` ADR/parity files remain
deliberately — they document the round-3 decision this change reverses.)
`scripts/fos7_contrast_gate.py` is **not** touched: its `#5B35D5` row pins the
*interactive* token pair, which stays.

### W3 — Add the White accent (monochrome)

**File:** `Packages/FleetUI/Sources/FleetUI/FleetAccent.swift`

| Old | New |
| --- | --- |
| cases end at `case black` (line 23) | `case white` appended after `black` |
| — | `highlight`: `FleetStoredColor(hex: 0x1C1C1E)` (the stored value is the light representation) |
| — | `label`: `"White"` |

**File:** `Packages/FleetUI/Sources/FleetUI/FleetThemePalette.swift`

| Old | New |
| --- | --- |
| `FleetThemePaletteAppearance`: `.adaptiveFleetDefault` / `.adaptiveCustomHighlight` / `.fixed` (~lines 174–178) | new case `.adaptiveMono` |
| `palette(forDarkAppearance:)` switch (~lines 269–285) | `.adaptiveMono` returns the Fleet dark text/background with highlight `#FFFFFF` (i.e. `fleetDefaultDark` with its highlight preserved from the light triple's mono intent) |

Semantics: `.adaptiveMono` keeps the palette's own highlight in light mode and
resolves it to pure white in dark mode, over the Fleet-default dark
text/background. The White accent's `palette` property constructs
`highlight #1C1C1E` / text+background Fleet-default / `appearance: .adaptiveMono`.

**Codability:** the new enum case is additive; persisted V1 payloads never
carry it, older app versions fall back to the default palette, and
`FleetStoredColor`/version validation is untouched. No migration code.

**Acceptance:** unit pin — `FleetThemeValues(palette: whiteAccent.palette,
isDarkAppearance: false).resolvedPalette.highlight == #1C1C1E`, and with
`isDarkAppearance: true == #FFFFFF`; `whiteAccent.palette.hasInvisiblePair ==
false` (guard accepts: light 16.16:1, dark 18.75:1 — measured).

### W4 — Settings row correctness for the new accent

**File:** `Packages/FleetUI/Sources/FleetUI/FleetSettingsView.swift`

| Old | New |
| --- | --- |
| `accentColorHighlight` = `currentAccent?.highlight ?? activePalette.highlight` (~lines 228–230) — always the stored light representation, so a White pick would show a near-black swatch in dark mode too | resolve for the current appearance: `theme.resolvedPalette.highlight` |

`FleetAccent.matching(active:)` needs no change: it compares stored triples,
and White's light highlight `#1C1C1E` does not collide with Black's `#2C2C2E`.

**Acceptance:** dark-mode screenshot of the Settings accent row shows a white
swatch circle labeled `White`; selecting White applies immediately and
survives relaunch (new UITest, W6).

### W5 — Test updates (see impact list for counts)

| Old | New |
| --- | --- |
| `FleetThemeTests.testComposeFillIsFixedDeepViolet` (FleetThemeTests.swift ~201–210) | deleted; replaced by the W3 resolution pins (new test methods in the same class) |
| `AppCompositionTests.testAccentPickerPalettesAllApply` comment "all 7" (~line 26) | "all 8" — the `allCases` loops extend automatically |
| `FleetSettingsAccentUITests.testAccentRowRendersAndMenuOffersSevenColors` (~16–28) | renamed count-agnostic (`...OffersAllCuratedAccents`); `"White"` appended to the expected-name array |
| — | new test `testSelectingWhiteAppliesMonoAndPersistsAfterRelaunch` mirroring the Purple test (select, assert row reflects White, relaunch, assert persisted) |

### W6 — Docs

- ADR-0009 (companion file, this change).
- ADR-0008 addendum: decision 2 (fixed violet pill) is reversed by ADR-0009.
- `docs/drawer-codex-parity.md`: one-line note at the round-3 pill section
  pointing to ADR-0009.
- `FleetAccent.swift` doc comment: "ChatGPT-style accent set" — note the
  eighth mono accent.

## Test impact

**AX identifier retirements: none.** `fleet.drawer.new-chat` is preserved
(call sites: `FleetNavigationDrawer.swift` (owner),
`ArtifactsDestinationUITests.swift` (taps it) — zero test edits required).

| Test asset | Effect |
| --- | --- |
| `FleetThemeTests.testComposeFillIsFixedDeepViolet` | retired (token removed) |
| `FleetThemeTests` (new) | White-accent light/dark resolution pins + guard-accepts pin |
| `AppCompositionTests.testAccentPickerPalettesAllApply` | auto-extends to 8 via `allCases`; comment update only |
| `BotAvatarThemeDecouplingTests.testAccentSelectionsNeverChangeAvatarIdentity` | auto-extends via `allCases`; no edit (avatar identity must stay accent-independent) |
| `FleetSettingsAccentUITests` (existing class — **no `c1_ui_matrix.sh` change**) | rename + `"White"` in menu array + new White persistence test |
| `ArtifactsDestinationUITests` | color-agnostic; verify green, no edit |
| `scripts/c1_ui_matrix.sh` | no change (no new UI test class) |
| `scripts/fos7_contrast_gate.py` | no change (pins interactive token, not composeFill) |

## Validation plan (Phase 3 net)

1. Fresh dedicated simulator `QAPILL` (`iPhone 18 Pro`), own
   `-derivedDataPath`, deleted after. `pgrep xcodebuild` first. Dark evidence
   runs set `xcrun simctl ui <UDID> appearance dark` before the run.
2. Targeted units: `FleetThemeTests`, `AppCompositionTests`,
   `BotAvatarThemeDecouplingTests`.
3. Targeted UI: `FleetSettingsAccentUITests`, `ArtifactsDestinationUITests`
   (full class names incl. `UITests` suffix; read `Executed N tests` receipts,
   never just `** TEST SUCCEEDED **`).
4. Full unit bundle — `HermesFleetAppUnitTests` scheme (not optional).
5. Screenshot evidence via the per-file `attachScreenshot` helper, extracted
   and sampled programmatically: light default pill `#5B35D5`, dark default
   pill `#FFFFFF` + dark ink, Blue-accent pill `#0A84FF`, White-accent picker
   row swatch (dark appearance) white.
6. Long runs backgrounded with per-suite logs + `Executed` receipts under
   `/tmp` (interruptible/recoverable).

## SPEC §14 amendment draft (external file — awaits explicit go)

The SPEC lives outside the repo at `~/code/fleet-os-spec/SPEC.md`. Draft
amendment text (to insert after the §14 sentence "Filled violet buttons use
white text in light mode and dark canvas text on the pale dark-mode violet."):

> **Amendment (dogfood build-41): the drawer compose pill is theme-coupled.**
> The compose affordance fills with the active highlight (accent-adaptive)
> and uses the max-contrast ink token, not a fixed violet. With the default
> palette this is visually identical in light mode (`#5B35D5`); in dark mode
> the default highlight is white, so the pill renders white with dark ink.
> The accent picker offers an eighth curated accent, **White** — a monochrome
> accent: near-black (`#1C1C1E`) in light mode, white (`#FFFFFF`) in dark
> mode, over the Fleet-default text/background. (ADR-0009.)

The external SPEC file is edited only on Tony's explicit go.

## Out of scope

- Every other `theme.highlight` consumer (tints, links, selected controls —
  ~70 foreground/tint call sites): they already follow the active theme;
  behavior there is unchanged by this work.
- The retired full theme editor (`FleetThemeEditorView`) internals — White is
  reachable through the accent picker only.
- Increase-Contrast variants for the mono accent — none needed: both mono
  resolutions already clear the 4.5:1 increased-contrast minimum (16.16:1 /
  18.75:1), so `correctedForeground` returns the highlight unchanged.
- Weakening or exempting anything in the invisible-pair guard.
- Commit, push, PR, TestFlight — this spec and the implementation land as one
  lane commit on Tony's go; nothing leaves the Mac without word-for-word
  instruction.
