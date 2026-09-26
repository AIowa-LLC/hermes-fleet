# ADR-0008: Drawer selection surface, compose pill, and swipe dismissal (Codex-parity round 3)

**Status:** Accepted — 2026-09-18

## Context

The drawer parity work (rounds 1–2: pinned footer, header diet, type ramp) was measured against the Codex drawer on the same device class. The comparison showed four identity-level deltas: violet-tinted navigation selection, a black-on-violet compose pill, a compact-only ✕ close button with no swipe dismissal, and a solid gear button adjacent to the pill.

SPEC §14 currently assigns the fixed Fleet violet to “interactive tint **and selected navigation**” and specifies “filled violet buttons use white text in light mode and dark canvas text on the pale dark-mode violet.”

## Decision

1. **Selected navigation uses a neutral fill** (`FleetTheme.neutralFill` — light `#E4E4E9` / dark `#2C2C2E`) with primary-label content; weight (semibold) remains the non-color selection cue. (Round-1 QA: the system tertiary background is invisible on the light canvas, so the fill is explicit per-appearance.) Fleet violet stays the interactive tint for links, controls, and the compose affordance.
2. **The compose pill is fixed deep violet `#5B35D5` with white content in both appearances** (contrast 7.2:1) and reads “Chat”.
   *Superseded 2026-09-19 by [ADR-0009](0009-compose-pill-theme-coupling-and-white-accent.md): the pill fill now follows the active theme highlight with `onHighlight` ink.*
3. **The ✕ close button is removed for strict parity.** Dismissal = scrim tap (existing), destination-select auto-dismiss (existing), and a new interactive left-swipe with spring-back; Reduce Motion gets instant dismiss without follow.
4. The settings (gear) control moves to the drawer's trailing edge and adopts the floating-glass layer (`.ultraThinMaterial` circle — chosen over `.glassEffect()` because glassEffect computes AX hit points at `{-1,-1}` and breaks XCUITest taps).

SPEC §14/§15 are amended accordingly (see `docs/drawer-codex-parity.md` §4). `fleet.drawer.close` is retired from the AX contract; the scrim carries `fleet.drawer.scrim` with a button trait and “Close navigation drawer” label.

## Alternatives rejected

- **Keep violet selection (SPEC status quo).** Rejected: it is the single most visible parity gap; the goal of this pass is the Codex look. Neutral selection also improves contrast (label on `#2C2C2E` ≈ 14:1).
- **Keep the ✕ button.** Rejected by owner decision (strict parity). Cost is bounded: 10 tap sites across 5 suites move to a scrim-tap helper; VoiceOver keeps an explicit dismiss control (scrim button).
- **`.glassEffect()` for the gear.** Rejected: breaks synthesized taps in the UI test net (measured); material renders equivalently and stays tappable.
- **White ink on the pale dark-mode violet `#BDA7FF`.** Rejected: ≈3:1 — would not clear body-text contrast and would silently weaken SPEC §14.

## Consequences

- `FleetTheme` gains one fixed token (`composeFill`) with a test pin; no existing tokens change, so `FleetThemeTests` pins and the contrast gate keep passing apart from the new pin/pair.
- Five UI suites touch the dismissal helper; one new swipe test lives in the existing `U3TabNavigation` matrix row.
- The drawer's footer is no longer part of the “compact-only” close affordance story — dismissal is native-gesture-first on both idioms.
