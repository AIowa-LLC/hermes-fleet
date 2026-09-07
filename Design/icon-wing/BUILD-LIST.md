# Hermes Fleet — "Wing" App Icon (W1)

Direction B — Hermes heritage reduced to ONE bold gold wing, swept upward-right,
a sibling of the D3 splash's winged-helmet mark (same palette, same weight, same
dark teal ground). NO text, NO outlines/caduceus/serpents/face, NO pre-rounded
corners, NO baked shadows/bevels — the system masks the square and adds Liquid
Glass. Vector layers are provided for Icon Composer (the .icon). A flat 1024
composite is provided so the asset catalog can be wired immediately.

## Palette (V6 "Constellation" — locked, exact)

- Gold           #C9A227   RGB(201,162,39)
- Dark teal bg   #0A0E0D   RGB(10,14,13)
- Warm accent    #EDE7D8   RGB(237,231,216)   (specular highlight only)
- Dark-variant bg #040605 (near-black; same gold wing)

## Layer build order (bottom → top)

All layers are UNMASKED 1024x1024, vector (SVG) + transparent PNG per layer.
Paint bottom-to-top in this exact order, then the system masks/publicates.

1. 00-background  — opaque full-bleed #0A0E0D       (background layer)
2. 00-wing_trailing — deepest wing band = trailing edge, GOLD, opacity 0.82
3. 01-wing_mid       — middle band,                  GOLD, opacity 0.90
4. 02-wing_leading   — lit leading band (full gold), GOLD, opacity 1.00
5. 03-wing_highlight — specular crescent,            WARM #EDE7D8, opacity 0.34

The wing is three NESTED crescent blades sharing one leading edge and one
wingtip, so the outer silhouette is one smooth swoosh (no feather spikes) and
the three bands read as light falling from the lit leading edge across the
wing. Opacity falls toward the trailing edge for Liquid-Glass-ready depth.

## Icon Composer assembly (Icon Composer is NOT installed on this Mac — Xcode 26.6)

1. Import 00-background.svg as the BACKGROUND layer (opaque full-bleed).
2. Import the 4 wing SVGs as foreground layers in the order above.
3. Set each layer's opacity as listed (or bake it — see PNGs; the PNGs already
   carry the opacity, the SVGs use fill-opacity).
4. Annotate default / dark / tinted appearances (see below).
5. Export to HermesFleetApp.appiconset as a single .icon.

## Flat fallback (wire now; .icon can follow)

- icon-1024-default.png  — final composite (bg + 4 wing layers). Drop this into
  HermesFleetApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png to ship the
  icon immediately. (apple-dev wires this — do not touch asset catalog in W1.)

## Appearances

- DEFAULT  — #0A0E0D bg + gold wing (icon-1024-default.png).
- DARK     — near-black #040605 bg, SAME gold wing (icon-1024-dark.png). Do NOT
             swap elements; only the background goes near-black.
- TINTED   — system generates it from the icon's alpha automatically. The
             provided icon-1024-tinted.png is a single-hue warm reference
             (all layers #EDE7D8 at their listed opacities on #0A0E0D) showing
             how the layered alphas resolve to one tint.
- Keep core geometry identical across all appearances (no element swaps).

## Reviewer/legibility evidence

- icon-60pt-mock.png — 60pt on a dark home-screen grid (top-left squircle).
  Silhouette reads unambiguously as a wing; gold pops; no smudging or lost
  detail at 60pt.

## Acceptance checklist (all met)

- [x] Layered icon: opaque full-bleed background + foreground wing layers.
- [x] Unmasked square 1024, vector SVG + flat PNG fallback.
- [x] One core concept (single bold wing), readable at 60pt.
- [x] NO text.
- [x] Hard edges — no feathering, baked shadows/bevels, or pre-rounded corners.
- [x] Dark + tinted variants planned (same geometry).
- [x] Palette matches V6 hexes exactly (verified by pixel sampling: bg #0A0E0D,
      full-gold band #C9A227).
- [x] Sibling of D3 splash mark (gold-on-dark-teal, same weight family).

## Regenerate

`python3 wing-generator.py` rewrites all artifacts in this directory
(idempotent — clears its own output first). Geometry lives in the LAYERS block.