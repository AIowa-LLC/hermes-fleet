# r9 — The Toolbelt: chips under the composer

Status: implemented (dogfood r9, riding the implementation commit).
Lane: `dogfood/build-41-integration` (build-41 worktree).
Owner: Tony (dogfood feedback: "make this thing worth existing").

## Problem

The conversation chip row (model · folder · profile · context) docked at
the TOP of the screen spent prime real estate on near-dead controls:

- model chip — real control (picker) ✅
- folder chip — popover that only showed (and copied) the path ❌
- profile chip — display-only label, not even a Button ❌
- context meter — real (breakdown sheet) ✅

## Design

**Move + activate.** The row docks UNDER the composer (between input and
keyboard); the transcript reclaims the top of the screen. Every chip is
now actionable:

1. **Folder chip → working-folder SWITCHER** (`session.cwd.set` — verified
   wire: `cwd` param; 4009 busy, 4017 invalid path). Sheet: current path
   (monospace, scrollable), path field, parent/home quick picks, inline
   errors. Copy-path moves to long-press. THE killer feature: change the
   workspace from the phone.
2. **Profile chip → session DOSSIER** (rename via `session.title`, branch
   via `session.branch` — wires that already existed in the tooling seam).
   Identity card: profile, gateway, session id (copyable), rename, branch.
3. Model chip + context meter unchanged (already earned their place).

Order: **model · folder · context · profile** (actions left → identity
right). AX ids unchanged (`fleet.conversation.header.*`) — zero
identifier retirements; the zone keeps `fleet.conversation.header.chipzone`.

## Architecture (mirrors the YOLO/reasoning seams)

- FleetCore: `ConversationToolingProviding.setCWD` + `SessionCWDInfo`
  readback struct (`_cwd_info`: cwd/branch/project).
- FleetNetworking: `GatewayConversationToolingClient.setCWD` — same guards
  as rename (session-key, non-empty, connected) + cwd-echo shape guard.
- FleetUI: `ConversationToolingViewModel.changeWorkingFolder(to:)` (notice
  + error surfaces, fail-soft like steer/rename), `WorkingFolderSheet` +
  `SessionDossierSheet` (ConversationToolbeltSheets.swift),
  `ConversationViewModel.refreshCWD(_:)`.
- Simulator: `ScriptedToolingBox.setCWD` records + flips `_servedCWD`; the
  session-info fixture now serves `toolingBox.servedCWD` (consistent).

## Testing

- R9ConversationToolingUITests +3: toolbelt renders under composer (frame
  pin), folder switch applies end-to-end (chip value flips), dossier opens
  with rename + branch.
- ConversationCompactChromeUITests: popover assertions → sheet flow.
- Drift gates: no new UITests class (extended R9) → no matrix change;
  xcodegen regenerated for the new sheet file (pbxproj in the same commit).

## Out of scope (deliberate)

- "+"-style tool menu (the composer already has +).
- New chips. Three of four controls becoming real is the value.
- Gateway-side changes (all wires already existed).
