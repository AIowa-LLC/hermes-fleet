# ADR-0009: Compose pill theme coupling and the White accent

**Status:** Accepted (dogfood lane `dogfood/build-41-integration`, 2026-09-19 —
Tony approved decisions 1–3; implementation pending)
**Supersedes:** ADR-0008 decision 2 (fixed-violet compose pill) — ADR-0008
decisions 1, 3, 4 (neutral selection fill, swipe dismissal, footer layout)
stand unchanged.

## Context

ADR-0008 (round-3 Codex parity) fixed the drawer compose pill to deep violet
`#5B35D5` with white content in both appearances, via a new fixed token
`FleetTheme.composeFill`. Dogfood feedback on the result: the pill ignores the
user's accent entirely — Settings offers seven curated accents (Blue, Green,
Yellow, Pink, Orange, Purple, Black) that recolor the rest of the interactive
surface, but the pill stays violet whatever is picked. Second request: add
White to the curated set.

Research findings that constrain the design:

- The theme pipeline's `FleetThemeController.apply` refuses palettes whose
  highlight is effectively invisible (contrast < 1.2:1) on the canvas in
  **either** appearance resolution. A literal `#FFFFFF` highlight on the light
  Fleet canvas `#F8F9FC` measures **1.05:1** — refused. White highlights are
  viable in dark mode only (18.75:1 on `#101216`).
- Precedent: the curated Black accent already stores `#2C2C2E` in both
  appearances — the existing set is not literally-named-colors, it is
  curated *per-appearance legibility*, which legitimizes a mono White.
- The dark Fleet default already resolves the highlight to white (B41
  direction), so a theme-coupled pill flips to white-with-dark-ink in dark
  mode under the default palette.
- The app already owns a guaranteed-legible ink seam for content on a
  highlight fill: `FleetThemeValues.onHighlight`
  (`FleetThemeContrast.maxContrastInk` — dark `#0D0D0F` vs white, higher
  ratio wins). It is the pattern used by AppLock, Conversation and
  GatewayOnboarding filled controls.

## Decision

1. **The compose pill fill follows the active theme highlight**
   (`theme.highlight`), and its ink is `theme.onHighlight`. Layout, capsule
   shape, label, and the `fleet.drawer.new-chat` AX identifier are unchanged.
2. **White joins the curated accent set as a monochrome accent**: stored
   light-representation highlight `#1C1C1E` (16.16:1 on the light canvas),
   resolving to `#FFFFFF` in dark mode over the Fleet-default dark
   text/background, via a new additive `FleetThemePaletteAppearance` case
   `.adaptiveMono`. The invisible-pair guard is untouched and accepts the
   palette by construction.
3. **The `composeFill` token is removed entirely** (the `FleetColors` UInt32,
   the `FleetTheme` Color, and its test pin) — not left as an orphan.

## Alternatives rejected

- **Literal `#FFFFFF` highlight in both appearances.** Invisible in light
  mode (1.05:1); `apply()` refuses it. Shipping it would require exempting
  White from the guard, which would also make every foreground use of the
  accent (links, selected controls) invisible on the light canvas.
- **Exempting White from the invisible-pair guard.** Rejected: the guard
  protects ~70 foreground call sites, not just the pill. Weakening a
  validation rule to admit one swatch violates the repo's working rules.
- **Keep the fixed violet pill.** Rejected: it is the reported defect — the
  pill ignores the user's accent.
- **Keep `composeFill` as an orphaned token.** Rejected: a pinned token no
  view consumes invites drift and false confidence in its test pin.
- **White pill ink hardcoded (as today's `.white`).** Rejected: on a white or
  pale fill it fails body-text contrast; `onHighlight` is the established
  seam and clears ≥ 4.59:1 for every curated accent (measured; ChatGPT's
  own white-on-blue is 3.65:1, below our floor).

## Consequences

- Dark mode under the **default** palette changes the pill from violet to
  white with dark ink — consistent with the B41 white-dark-highlight
  direction and with every other highlight-following control; light mode
  under the default palette is visually unchanged (`#5B35D5`).
- Saturated accents (Blue, Green, Yellow, Pink, Orange, Purple) render dark
  ink on the pill where ChatGPT renders white — a deliberate contrast floor
  choice, not an oversight.
- `FleetThemePaletteAppearance` gains a case: Codable payloads are additive
  and backward compatible (old payloads never carry it; older app versions
  that decode an unknown raw value fall back to the default palette).
- Persisted palettes from White-adopting installs read as `.adaptiveMono`;
  `FleetAccent.matching(active:)` round-trips it via stored-triple equality
  (White's `#1C1C1E` does not collide with Black's `#2C2C2E`).
- ADR-0008's test pin for `composeFill` retires with the token; new pins
  cover the mono accent's per-appearance resolution.
- The SPEC §14 external file gains an amendment only on Tony's explicit go
  (draft text lives in
  `docs/theme-coupled-pill-and-white-accent.md`).
