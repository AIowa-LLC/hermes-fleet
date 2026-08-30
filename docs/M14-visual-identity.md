# Hermes Fleet iOS — M14 Visual Identity Integration (Black / White / Signal Red)

Prepared by `apple-design` · board `hermes-fleet-ios` · task `t_d467daec` · 2026-08-29
**Re-keyed visual identity.** This document CORRECTS the `t_87a31080` design-lane handoff, whose
brand palette used indigo/teal tokens. The final planning synthesis (§7.7, §16, §23) re-keys the
identity to a **Black / White / Signal Red foundation** with optional **Hot Magenta / Cold Electric
Blue** accents. This is the authoritative, implementable brief for M14.

Scope guard: **GPT Images supplies supporting assets only** (app icon, empty-state illustration,
Live Activity glyph). **SwiftUI renders all functional screens** — generated imagery is never passed
off as real UI, and no functional/status/navigation glyph is generated (SF Symbols only).

---

## 1. Theme foundation

| Role | Dark | Light | Use |
|---|---|---|---|
| background | `#0A0A0B` | `#FFFFFF` | app background |
| surface | `#161618` | `#F2F2F7` | cards, grouped rows |
| surfaceElevated | `#1F1F22` | `#FFFFFF` | sheets, popovers, detail |
| textPrimary | `#F5F5F7` | `#17171A` | primary text |
| textSecondary | `#9C9CA4` | `#3C3C43` | secondary/caption text |
| separator | `#2C2C30` | `#C6C6CC` | hairline dividers |

## 2. Accent tokens

| Token | Dark | Light | Use |
|---|---|---|---|
| **accent (Signal Red)** | `#FF453A` | `#C8102E` | brand accent, primary interactive, attention/alarm |
| accentMagenta (Hot Magenta, opt) | `#FF2D55` | `#B4003C` | optional categorical accent (UI/icon only) |
| accentColdBlue (Cold Electric Blue, opt) | `#0A84FF` | `#0064C8` | optional categorical accent (UI/icon only) |

Signal Red is **text-capable** in both appearances (contrast ≥ 4.5:1 — see §5). The optional
magenta/blue accents are for **icon/UI reinforcement only**, never small text.

## 3. Semantic status (icon + text; color is reinforcement only)

The identity is a "signal" system: **Signal Red = needs your attention/alarm**; **monochrome =
calm/all-clear**. Green is deliberately absent from the identity (the "all clear" signal is calm
monochrome, not green) — this honors the Black/White/Signal-Red foundation and stays
color-blind-safe because every state carries a distinct SF Symbol + text label.

| State | SF Symbol | Reinforcement color | VoiceOver value |
|---|---|---|---|
| ok / running / reachable | `checkmark.circle.fill` | neutral (textSecondary) | "Reachable" / "Running" |
| idle | `circle` | neutral (textSecondary) | "Idle" |
| offline / unreachable | `wifi.slash` | neutral (textSecondary) | "Unreachable" / "Offline" |
| attention / awaiting approval | `exclamationmark.circle.fill` | Signal Red | "Awaiting your approval" |
| danger / errored / auth-failed | `xmark.octagon.fill` | Signal Red | "Errored: <reason>" |

`differentiateWithoutColor` must remain readable from icon + label alone.

## 4. SF Symbols — functional/status map (SF Symbols only, never generated)

| Purpose | Symbol |
|---|---|
| Fleet tab | `point.3.connected.trianglepath.dotted` |
| Activity tab | `text.alignleft` |
| Inbox (approvals, badged) | `tray` |
| Settings tab | `gearshape` |
| Empty state / gateway row (M14 in use) | `server.rack` |
| Steer | `paperplane.fill` |
| Thin chat | `text.bubble` |
| Add node | `plus` |
| Test connection | `bolt.horizontal` |
| Retry | `arrow.clockwise` |
| Copy | `doc.on.doc` |
| Show / hide secret | `eye` / `eye.slash` |
| Revoke grant | `xmark.circle` |
| Sign out | `rectangle.portrait.and.arrow.right` |
| Forget device | `trash` |

## 5. Contrast acceptance gate

All pairs verified programmatically (`scripts/m14_contrast_gate.sh`):

| Pair (dark / light) | Ratio |
|---|---|
| textPrimary / background | 18.18 : 1 / 17.89 : 1 |
| textSecondary / background | 7.26 : 1 / 10.94 : 1 |
| accent (Signal Red) / background | 5.81 : 1 / 5.88 : 1 |
| accent / surface | 5.30 : 1 / 5.27 : 1 |
| accent / surfaceElevated | 4.83 : 1 / 5.88 : 1 |
| accentMagenta / surface (UI) | 4.96 : 1 / 6.26 : 1 |
| accentColdBlue / surface (UI) | 4.95 : 1 / 5.15 : 1 |

Gate: text ≥ 4.5:1, UI/icon ≥ 3.0:1. **PASS** (all 24 pairs). Any future token change must re-run
the gate; a failure is a `MAJOR` finding.

## 6. Typography & spacing (unchanged from t_87a31080 §4.2/§4.3)

- System text styles end-to-end, never hard-coded points. `.largeTitle` (screen), `.headline`
  (section), `.body` semibold (primary), `.subheadline`/`.footnote` (secondary), `.caption2`
  (timestamps). Terminal/console → `.caption`/`.footnote` in `.monospaced`.
- Labels wrap, never truncate, from `.body` through AX5.
- 8pt spacing scale (4/8/12/16/24/32); margins 16pt compact / 20pt regular; radius 12pt cards,
  16pt sheets, 8pt controls; min interactive target 44×44pt.

## 7. GPT Images supporting assets (re-keyed art direction)

Art direction: **"Signal beacon"** — a small constellation of nodes joined by hairline links on a
pure-black ground, with **Signal Red (`#FF453A`)** as the single glow accent (one red "attention"
node; remaining nodes neutral white/gray). No teal, no indigo, no amber. Flat, high-contrast,
technical.

| Asset | Size | Notes |
|---|---|---|
| App icon | 1024×1024 opaque, no alpha, no text | beacon constellation; legible at 16pt |
| Empty state — no gateways | 1024×1024, dark + light variants | sparse constellation, one unlit node |
| Live Activity glyph (P1) | 1024×1024, monochrome-friendly | node + signal line, tinted at runtime |

Rules (carried from t_87a31080 §1/§7): no text baked in; no third-party/Apple/Hermes marks; imagery
decorative only (VoiceOver meaning carried by title + body + action); empty state degrades to
title + text + action; provenance recorded in `assets/manifest.json` (prompt, model, date).

## 8. M14 acceptance

1. **Theme tokens applied** — a `FleetTheme` (light/dark adaptive) is the single source of truth and
   every view reads from it (no hard-coded colors in views); `AccentColor` = Signal Red.
2. **Contrast gate** — `scripts/m14_contrast_gate.sh` exits 0 (§5).
3. **No generated-UI** — the app screen is rendered by SwiftUI and captured via `xcrun simctl io
   screenshot`; GPT imagery is restricted to icon / empty-state / Live Activity glyph, all recorded
   in `assets/manifest.json`.

## 9. Traceability

- Synthesis §7.7 → §1/§2 (indigo/teal corrected to Black/White/Signal Red).
- Synthesis §16 → §7 (imagery for icon/empty/LA only; SF Symbols for functional; never fake UI).
- Synthesis §23 / Phase 6 → §8 (Black/White/Signal-Red theme + contrast gate + Dynamic Type/VO).

— End of M14 visual identity brief. No implementation of fleet/transport/auth/persistence logic;
theme-token application only. —
