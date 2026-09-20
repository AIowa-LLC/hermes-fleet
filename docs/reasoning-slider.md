# Session reasoning slider (thinking level)

**Status:** Approved by Tony ("same drill… Ship directly to my phone", 2026-09-20)
— implemented this change (r8). Delivery lane: WiFi device build, NO TestFlight.
**Lane:** `dogfood/build-41-integration` (this file rides the implementation commit).
**Reference:** Gemini-style thinking slider (Tony's screenshot, 2026-09-20): large
value readout above the composer, capsule track filled edge-to-edge, circular
handle, soft glow. The reference's numeric readout ("5.6") is cosmetic — the
Hermes wire is discrete words, so Fleet's readout shows the word, never a
fabricated number.

## Problem

Fleet renders reasoning streams (`reasoning.delta` → `ReasoningDisclosure`) but
gives the user no control over how much reasoning a session does. The gateway
already owns this knob end-to-end; the app simply never wired it:

- **Read:** `config.get {key: "reasoning", session_id}` → `{value, display}`
  (`tui_gateway/methods_config.py:151–172`). Resolution order: session
  override → live agent config → global YAML default.
- **Write:** `config.set {key: "reasoning", value, scope: "session",
  session_id}` → stores `create_reasoning_override` on the session
  (`methods_config_set.py:290–329`). Session-scoped by design — the gateway's
  own comment: "a menu pick must not rewrite the global". Global scope
  (`agent.reasoning_effort` in config.yaml) is the owner's, not the app's.
- **Accepted values — verified live 2026-09-20** against
  `hermes_constants.parse_reasoning_effort`: `none | minimal | low | medium |
  high` (and `false → none`). Anything else — including numerics like `"5.6" —
  returns None and the setter errors 4002.
- `session.create` also accepts `reasoning_effort` (`methods_session.py:310`)
  — noted, not used in V1 (see Out of scope).

Architecture precedent is the R9-T3 YOLO toggle: a session-scoped runtime
control with its own small FleetCore seam, FleetNetworking client, FleetUI
view model, FleetSimulator scripted fixture, and UI tests. This feature is
that shape again, minus the confirm-on-enable (a reasoning level is benign
and instantly reversible).

## Design

**Eight stops, one axis.** `none | minimal | low | medium | high | xhigh | max | ultra`, ordered
least→most (the gateway's full `VALID_REASONING_EFFORTS` ladder, re-verified
live r8.4 — Tony's gateway runs at `max`). The control is a drag-anywhere capsule slider presented as an
overlay directly above the composer — not a sheet, not a menu — so the
keyboard and composer state are untouched and no presentation animation can
drop taps (verified lane trap: menu-item taps drop while presenting).

**Chip → overlay.** A compact chip in the conversation tooling sub-row (beside
the model chip, `ConversationView.swift` ~line 224) shows the session's
current level word. Tapping it opens the overlay. The chip is hidden when the
session has no reasoning seam (same fail-closed gating as the YOLO toggle).

**Apply on release.** Dragging moves the handle continuously with stop-snap;
releasing applies that stop via session-scoped `config.set`. No confirm step.
Tap-outside (or Esc) dismisses without changing anything if no drag occurred.

**Theme, not paint.** Every color comes from `.fleetTheme` — per Tony: the
reference's lavender is *its* app's highlight, so Fleet's fill is
`theme.highlight`, full stop. No hardcoded color survives review.

| Element | Token |
| --- | --- |
| Track fill (left of handle) | `theme.highlight` |
| Track unfilled | `theme.surfaceElevated` with `theme.border` stroke |
| Handle (circle) | `theme.onHighlight` (max-contrast ink vs the fill — stays visible on every curated accent, incl. White-in-dark where highlight is white) |
| Glow behind handle | `theme.highlight.opacity(0.35)` shadow |
| Readout word | `theme.textPrimary`, title weight |
| Caption ("Thinking level") | `theme.textSecondary` |
| Stop ticks | `theme.onHighlight` when ≤ current, else `theme.border` |
| Scrim behind overlay | `theme.background.opacity(0.6)` + `ultraThinMaterial` |

**Chip icon:** `brain` (SF Symbol existence verified on this host's symbol DB
2026-09-20; also verified: `lightbulb.max`, `slider.horizontal.3`. NOT
verified/ruled out: `brain.filled.headbrain`, `chevrons.up.chevron.down`).
Chip word renders in `theme.highlight` when it differs from the session
default, `theme.textSecondary` otherwise (mirrors the model chip's
sticky-pick coloring).

## Work items

### W1 — FleetCore: the level model + seam

**File (new):** `Packages/FleetCore/Sources/FleetCore/ConversationReasoning.swift`

- `public enum FleetReasoningLevel: String, CaseIterable, Codable, Sendable` —
  `none, minimal, low, medium, high, xhigh, max, ultra`; `var isSuccessor: Bool` (`none` is not a
  thinking level but IS a legal wire value and slider stop); `index`,
  `label` ("None/Minimal/Low/Medium/High/Extra High/Max/Ultra"), `init?(wireValue:)` strict.
- `public struct ReasoningState: Equatable, Sendable` — `{level: FleetReasoningLevel?, rawValue: String, display: String?}` (level nil ⇒ unknown/custom readback; the chip then shows `rawValue` and the slider marks no stop).
- `public protocol ReasoningControl: Sendable` —
  `func reasoning(sessionID: String) async throws -> ReasoningState`;
  `func setReasoning(_ level: FleetReasoningLevel, sessionID: String) async throws -> FleetReasoningLevel`.
  Throws `ConversationError`-shaped failures; no `config.set` for any other
  key lives behind this protocol (single-purpose seam, YOLO precedent).

### W2 — FleetNetworking: `GatewayReasoningClient`

**File (new):** `Packages/FleetNetworking/Sources/FleetNetworking/GatewayReasoningClient.swift`

- `reasoning(sessionID:)` → `config.get` params `{key: "reasoning",
  session_id}`; maps result `{value, display}` → `ReasoningState`
  (`parse` via `FleetReasoningLevel(wireValue:)`; unknown string ⇒ level nil).
- `setReasoning(_:sessionID:)` → `config.set` params `{key: "reasoning",
  value: level.rawValue, scope: "session", session_id}` — exactly the
  param shape `GatewayApprovalClient.setSessionYolo` uses
  (GatewayApprovalClient.swift:73–78); returns the gateway's reported value,
  fail-closed on mismatch.
- Both carry the M9 guards verbatim (RoutingGuard session-key check before
  the connected-state check).

### W3 — FleetUI: view model + overlay + chip

**Files (new):** `Packages/FleetUI/Sources/FleetUI/ReasoningSliderOverlay.swift`
(one file: `ReasoningViewModel`, the overlay, and the chip).

- `ReasoningViewModel` (`@Observable`): loads via `reasoning(sessionID:)` when
  the session becomes ready; `apply(_:)` calls `setReasoning` and surfaces a
  failure string for the composer banner (never silent — house rule); holds
  `isBusy` to disable the handle mid-flight.
- Overlay: mounted in `ConversationView` as `.overlay(alignment: .bottom)`
  above `composerBar` (NOT a sheet). ZStack: scrim → capsule track → handle →
  readout stack. `DragGesture` on the whole capsule (drag-anywhere, Gemini
  behavior): continuous position, snap to nearest stop on `.onEnded`, apply
  once. `.sensoryFeedback(.selection, trigger: level)` for stop crossings.
- VoiceOver: the capsule is one adjustable element —
  `.accessibilityElement(children: .ignore)` +
  `.accessibilityValue(level.label)` +
  `.accessibilityAdjustableAction` (± one stop, wraps at ends, applies each
  step). RT4 hygiene: the readout word is NOT duplicated into AX (the slider's
  own value carries it).
- AX identifiers: `fleet.conversation.reasoning.chip` (button),
  `fleet.conversation.reasoning.overlay`,
  `fleet.conversation.reasoning.slider`,
  `fleet.conversation.reasoning.value` (the readout staticText).
- Chip mount: inside the existing `if model.toolingViewModel != nil`
  sub-row HStack (~ConversationView.swift:225–249), directly after the model
  chip, gated `if model.reasoningViewModel != nil`.
- Wiring: `ConversationViewModel` gains `reasoningViewModel:
  ReasoningViewModel?` constructed where `approvalViewModel` is, from the same
  transport (app target composition; FleetUI never imports FleetNetworking).
- i18n: visible strings through the app's existing localization seam like
  every composer label.

### W4 — FleetSimulator: scripted reasoning seam

**File:** `HermesFleetApp/FleetSimulator.swift` (the approvals seam,
~lines 1170/1819–1842, is the pattern)

- Simulator serves `config.get reasoning` → current scripted value (default
  `medium`, overridable at launch via existing simulator-fixture argument
  pattern for tests that need a non-default start).
- Records `config.set reasoning` calls (level + scope assertion material,
  thread-safe like `_yoloStates`) and mutates the served value, so the chip
  reflects the applied stop without a real gateway.
- Simulator must NEVER accept `scope != "session"` writes through this seam
  (the fixture models the app's contract, not the gateway's full surface).

### W5 — Tests

| Test asset | Coverage |
| --- | --- |
| `Packages/FleetCore/Tests/FleetCoreTests/ConversationReasoningTests.swift` (new) | level ordering + raw values match wire words exactly; `wireValue:` strict round-trip; unknown string ⇒ nil level; `ReasoningState` mapping incl. display passthrough |
| `Packages/FleetNetworking/Tests/FleetNetworkingTests/GatewayReasoningClientTests.swift` (new) | scripted transport (GatewayApprovalClientTests:209 precedent): correct `config.get`/`config.set` param dicts incl. `scope:"session"`; result mapping; unknown readback ⇒ level nil; error propagation (4002, transport) |
| `HermesFleetAppUITests/ReasoningSliderUITests.swift` (new class → **`scripts/c1_ui_matrix.sh` `UI_CLASSES` row in this same change**) | 1) chip exists on ready conversation, shows gateway default; 2) tap chip → overlay visible, drag to `high` → readout "High", overlay dismisses, chip shows "High", simulator recorded `setReasoning(high, scope session)`; 3) drag back to `none` → readout "None", chip "None"; 4) VoiceOver adjustable action cycles a stop and applies; 5) scripted `config.set` failure → composer banner appears (never silent) |

Drag mechanics in UI tests: use `slider.adjust(toNormalizedSliderPosition:)`
on the AX-exposed adjustable element (works for custom sliders that implement
the adjustable pattern), NOT coordinate swipes (flaky across devices). If the
custom capsule proves non-hittable for `XCUIElement.slider` queries, fall back
to `accessibilityAdjustableAction`-driven `increment()`/`decrement()` and pin
that choice here.

### W6 — Docs

- This spec's Status flips to implemented, riding the implementation commit.
- `docs/features.md`: conversation section gains one line (session-scoped
  thinking level, eight stops, session-scoped only).
- No ADR: nothing decided here reverses a prior ADR (ADR-0009 untouched; no
  new token enters FleetTheme).

## Test impact

**AX identifier retirements: none** (all identifiers in this spec are new).

| Asset | Effect |
| --- | --- |
| `scripts/c1_ui_matrix.sh` | +1 `UI_CLASSES` row (`ReasoningSliderUITests`) — same change as the new class (drift gate) |
| Existing composer/UI tests | untouched — the chip is additive in the tooling sub-row; no identifier moves |
| `HermesFleetApp.xcodeproj` | regenerated (`~/.local/bin/xcodegen generate`) — 3 new source files + 2 test files; pbxproj diff rides the same commit |

## Validation plan

1. Orient: `git branch --show-current` ⇒ `dogfood/build-41-integration`, HEAD
   ≥ `fleet-dogfood-baseline-61`. `pgrep xcodebuild` before any run.
2. Fresh dedicated simulator `QAREASON` (`iPhone 18 Pro`), own
   `-derivedDataPath`, deleted after — never shared across xcodebuilds.
3. Targeted packages: `swift test` filtered to
   `ConversationReasoningTests` + `GatewayReasoningClientTests`
   (FleetNetworking's full-suite TLS hang is known — filtered runs only).
4. Targeted UI: `-only-testing:HermesFleetAppUITests/ReasoningSliderUITests`
   (full class name incl. suffix); verdict = the `Executed N tests` line.
5. Full unit gate: `HermesFleetAppUnitTests` scheme with
   `-skipMacroValidation`, fresh DerivedData.
6. Screenshot evidence: overlay open at each of the eight stops (light +
   default palette), plus one dark-appearance shot — sample the fill pixel =
   active highlight, handle = onHighlight (programmatic sample, ±3/channel,
   `scripts/measure_drawer_screenshot.py` pattern). One accent-switched shot
   (e.g. Green) proves no hardcoded lavender survives.
7. Commit: explicit paths only, `git commit -F /tmp/msg.txt`,
   `~/.local/bin/gitleaks protect --staged` first, author
   Tony Simons <tony@aiowa.dev>. No push, no PR, no TestFlight without
   word-for-word instruction.

## Out of scope

- **Global reasoning scope** (`scope:"global"` / `agent.reasoning_effort` in
  config.yaml) — the owner's knob; the app writes session-scoped only, ever.
- **`session.create {reasoning_effort}`** (sticky pick that seeds new
  sessions, model-picker style) — natural follow-up; V1 reads back whatever
  the session has.
- **Reasoning visibility axis** (`display: show|hide|full|clamp` rides the
  same `config.get` result) — separate control, separate round.
- **Continuous/numeric levels** — the wire rejects them; a fake number in the
  readout would be a lie about the model's actual control.
- **Room Chat / Bot Chat surfaces** — V1 is the gateway conversation canvas
  only; rooms get it if/when their sessions expose the seam.
- Commit/push/PR/TestFlight — this spec and its implementation land as lane
  commits on Tony's go; nothing leaves the Mac.
