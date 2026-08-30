# X1 — Launch screen (splash) from Tony's artwork

Prepared by `apple-design` · board `hermes-fleet-ios` · task `t_ec09a7d1` · 2026-08-30
Design handoff + findings. Wiring + build are deferred to `apple-dev` (see §7 and the
child card this brief ships with), because an `apple-dev` T2 worker (`t_f54b722e`) held the
repo mid-`xcodebuild` with an uncommitted `project.pbxproj` edit at the time of this work —
regenerating the project here would have clobbered it.

---

## 1. Objective

Replace the current empty generated launch screen with a launch screen built from Tony's
supplied artwork (`upload_20260830_120802_1.png`, 941×1672, RGB no-alpha), "matching the app
theme", with a deliberate fade into `FleetRootView`.

## 2. Evidence gathered

Artwork edge/background sampling (script: workspace `x1_sample.sh`, via `sips`→BMP→stdlib
parse, 24bpp uncompressed):

| Sample | RGB |
|---|---|
| top-left / center / bottom-right / right-mid | `(0,0,0)` pure black |
| top-right | `(2,24,39)` dark blue tint (near neon) |
| left-mid | `(4,16,34)` dark blue tint |
| border average | `(7,8,13)` → `#07080D` |
| border dominant cluster | `#000000` (1338 of 1458 samples) |

So the artwork ground is effectively pure near-black with a faint cyan/navy bloom only where
neon sits. `#07080D` vs the app's `FleetTheme.background` dark `#0A0A0B` is visually identical
— a seamless cross-fade is achievable with a `#0A0A0B` launch background.

Vision review (self + `vision_analyze`): the artwork is a 9:16 poster — winged-Hermes figure
with gold helmet/caduceus, vehicles with neon underglow, "HERMES" in distressed gold,
"FLEET" in hot-pink brush, tagline "EVERY BOT. EVERY MACHINE. ONE POCKET." **Palette =
Black / Metallic Gold / Hot Magenta / Electric Cyan / neon purple** — NOT the M14
Black/White/Signal-Red identity (see §6, finding F1).

## 3. Design decision (recommended)

**Full-bleed artwork launch screen via a launch storyboard**, `scaleAspectFill`, on a
`#0A0A0B` background. Rationale: Tony supplied the artwork explicitly for the splash; it is
already 9:16 and fits a portrait phone edge-to-edge without cropping the subject or the
wordmark; the storyboard (not the `UILaunchScreen` dict) is required because the dict renders
its `UIImageName` *centered at intrinsic size* rather than filling the frame.

Crop/letterbox strategy (all handled by `scaleAspectFill` + centered):
- **Portrait iPhone (≈9:16)** — fills nearly 1:1, no letterbox; only the extreme wing/truck
  tips near the rounded corners are mildly clipped (acceptable, art is full-bleed by design).
- **Landscape / iPad** — `scaleAspectFill` zooms to fill width and crops top/bottom; the
  `#0A0A0B` background shows only if aspect ratios ever letterbox, blending toward the app bg.
- **Notched / Dynamic Island** — image is pinned to the *view* edges (not the safe area), so
  the art runs under the notch/status bar (launch screen has no UI, so no safe-area content
  to protect).
- **Dynamic Type** — irrelevant at launch; no text is laid out by the storyboard.

## 4. Fade into FleetRootView (definition)

iOS performs the launch-screen → first-frame transition automatically (a cross-fade); no
custom animation is authored and none is needed. Seamlessness comes from color continuity:

- Launch background `#0A0A0B` == `FleetTheme.background` dark `#0A0A0B` (which
  `GatewaysView` / `BotDetailView` / `FleetRosterView` / `ConversationView` all apply via
  `.background(FleetTheme.background.ignoresSafeArea())`).
- Result: in **dark** appearance the poster (near-black) fades imperceptibly into the app.
- **Light** appearance is the gap — see F3. No custom Swift is required in this card; if Tony
  wants an animated/curated reveal later, that belongs in the app layer, not the launch screen.

## 5. Asset inventory (created, all NEW files — no conflict with the in-flight T2 worker)

| Path | Role |
|---|---|
| `assets/x1-splash/hermes-fleet-splash-source.png` | untracked source copy (941×1672, opaque) |
| `HermesFleetApp/Assets.xcassets/LaunchArtwork.imageset/launch-artwork.png` + `Contents.json` | launch image (universal) |
| `HermesFleetApp/LaunchScreen.storyboard` | full-bleed `scaleAspectFill` launch screen, `#0A0A0B` bg |
| `scripts/x1_wire_launch_screen.sh` | `apple-dev` wiring script (guard + config edits + regenerate + verify) |

`xcodegen` auto-detects `.storyboard` files and `Assets.xcassets` under the
`HermesFleetApp` sources dir, so the new image/storyboard enter the app target on the next
`xcodegen generate` with **no hand-edited `project.pbxproj`**.

## 6. Findings

**F1 — MAJOR — palette diverges from the locked M14 identity.** The artwork is
Black/Gold/Hot-Magenta/Electric-Cyan/neon-purple. The locked identity (M14 doc §1–§2,
`FleetTheme`) is Black/White/Signal-Red (`#FF453A` dark / `#C8102E` light) with optional Hot
Magenta / Cold Electric Blue *accents only*, and §7 forbids baked-in text and gold. The launch
screen is the brand's first frame, so the divergence is front-loaded. Delivered as Tony's
explicit art direction; recommended resolution (defer to Tony): re-theme via image-to-image —
gold→white/silver, hot-pink "FLEET"→Signal Red `#FF453A`, cyan→Cold Electric Blue `#0A84FF`,
drop neon purple; or reserve the poster for in-app onboarding / App Store marketing and use a
minimal M14 mark on the launch screen.

**F2 — MINOR — HIG "launch screen ≈ first screen".** A full marketing poster (figure +
vehicles + wordmark + tagline) conflicts with the HIG guidance that the launch screen should
look like the first screen (fast, not a marketing splash). Acceptable for a deliberate brand
moment; noted for the record.

**F3 — MINOR — light-appearance pop.** The artwork is dark-only; the app is light-adaptive
(`FleetTheme.background` light = `#FFFFFF`). In light appearance the launch will be near-black
then pop to white. Acceptance criterion "light/dark unchanged" is satisfied *for the launch
screen itself* (it is appearance-independent), but the hand-off into a light app is not
seamless. Options (product decision, out of this card's scope): (a) app-wide dark —
`FleetDashboardView` already uses `.preferredColorScheme(.dark)`, promote to the root; (b)
appearance-adaptive launch (dark poster in dark, light treatment in light).

**F4 — POLISH — asset weight.** `launch-artwork.png` is 2.9 MB (941×1672). Launch screens
should be light; 2.9 MB adds decode time to cold launch. Optional: re-encode with `pngcrush`
or downscale to ~1170×2532 (covers @3x iPhone) before release. Not a blocker.

**F5 — POLISH — sub-@3x upscale.** 941×1672 is ~1.4× below iPhone 16 Pro Max @3x
(1320×2868), so `scaleAspectFill` upscales on 3x devices (mild softening for a <1 s splash).

## 7. Wiring spec for `apple-dev` (the deferred step)

Run `scripts/x1_wire_launch_screen.sh` (it guards on a clean tracked tree), or apply by hand:

1. `project.yml` — remove the line `INFOPLIST_KEY_UILaunchScreen_Generation: YES` (otherwise
   the generated empty `UILaunchScreen` dict overrides the storyboard).
2. `HermesFleetApp/Info.plist` — add inside the top-level `<dict>`:
   `UILaunchStoryboardName` = `LaunchScreen`.
3. `xcodegen generate`.
4. Verify the generated `project.pbxproj` references `LaunchScreen.storyboard` (Resources
   build phase) and `LaunchArtwork.imageset`; then build + cold-launch on a notched simulator.

## 8. Acceptance (for `apple-qa`)

Cold launch on a notched iPhone simulator shows the artwork full-bleed with no clipping of the
wordmark and no stretching; light/dark launch unchanged; app icon untouched; full test suite
green; module boundary untouched (no `FleetCore`/`FleetNetworking`/`FleetSecurity`/
`FleetPersistence` edits).

— End of X1 design brief. No production Swift authored; asset prep + design spec only. —
