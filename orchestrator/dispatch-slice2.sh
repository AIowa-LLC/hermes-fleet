#!/bin/bash
# Dispatch True Bots Mode slice 2 (dev) + foundation design acceptance (design)
set -euo pipefail
export PATH="$HOME/bin:$HOME/.hermes/bin:$PATH"
B=hermes-fleet-true-bots

echo "=== gateway ==="
hermes gateway status | head -3

echo "=== lane check (must be empty) ==="
ps aux | grep -E "hermes -p (apple-dev|apple-design|apple-qa)" | grep -v grep || echo "no live workers"

DEV_ID=$(hermes kanban --board "$B" create "True Bots Mode slice 2 — native roster UI + bot management (D02 UI, D05-D12)" \
  --assignee apple-dev \
  --body "Mission continues: read /Users/tonysimons/.hermes/artifacts/true-bots-mode/mission.md, groups-addendum.md, foundation-checkpoint.md, foundation-checkpoint-report.md, qa-checkpoint-c074836.md and design.md — ALL in that artifacts dir — before coding. Foundation slices 1-6 are independently QA-PASSED at c0748368d04723ced8ba141c5dd14a62ca00ab84 on branch feature/true-bots-mode in /tmp/hermes-fleet-true-bots (tree clean there). Build ON TOP of c074836; never rewrite history; coherent local commits; no push.

SCOPE of this slice (single-writer, you own the repo tree):
1. Native Bot roster UI (D02 UI): latest preview/time, activity ordering, Active Now, worker presence, search, hidden reveal, unread/attention, source/gateway grouping and filtering, source-offline ghosts retaining identity, duplicate-name disambiguation labels, user sections rows, group rows (from the landed FleetRoomUnion provider).
2. Sections (D10): create/rename/reorder/delete/move/remove/unassigned via authoritative ui_meta + per-key CAS (typed conflict UI: show conflict/reload, never silent overwrite; retain unknown fields). Delete section never deletes Bots.
3. Create Bot (D05/D06): quick name/title/description + target gateway WITHOUT switching app active gateway; advanced: fresh/target-machine clone/empty-no-skills, SOUL, model/provider, credential inheritance/shared auth semantics, skills/toolsets/MCP, appearance; target-specific capability catalogs; honest unsupported states.
4. Edit (D07): profiles.describe/configure/set_asset/get_asset surfaces for title/description/SOUL/model/provider/skills/toolsets/MCP/avatar/metadata/hidden/groups/sections. Honor model-policy/expensive-model confirmation handshakes and ui_meta_expected_revisions CAS. QA-tracked residual P3: surface per-key partial-success (applied vs failed keys) in the edit UI — this slice owns closing it.
5. Avatars (D08): backend-authoritative identity — deterministic geometric/blob identity + uploaded image with proper asset sync; same Bot recognizable across clients; no iPhone-only avatar authority.
6. Duplicate (D11): via supported profile clone — inherit config/SOUL/skills/memory/look but new profile + own canonical chat + new creation metadata; NEVER copy canonical pointer.
7. Safe delete (D12): only supported authenticated lifecycle-aware surface after explicit user confirmation; default cannot delete; capability-gate honestly when transport cannot safely use it. No cli.exec, no shell interpolation, no filesystem deletion.

Preserve: module boundary (FleetUI never imports FleetNetworking), white wing icon + Fleet visual language (see design.md; NOT generic grouped Forms), existing Sessions/management surfaces regression-green, security guards. Real capability gates; no simulator facade. TDD where practical: domain/networking/view-model tests for every behavior above; keep suites deterministic and synthetic. No secrets/private hosts/signing IDs in tracked files. No TestFlight, no push, no gateway mutations with real data.

DONE = implement + test + local commits; publish final SHA, exact test counts (separate skipped/blocked), and evidence file path under /Users/tonysimons/.hermes/artifacts/true-bots-mode/ (dev-slice2-report.md) as a card comment; then kanban_request_review and STOP. Routines (D13), groups UX screens, RoomLink UI, mentions, relay, live-gateway validation and docs are LATER slices — do not start them." 2>&1 | grep -oE 't_[a-f0-9]+' | head -1)
echo "DEV_ID=$DEV_ID"
[ -n "$DEV_ID" ] || { echo "FATAL: no dev card id"; exit 1; }

DES_ID=$(hermes kanban --board "$B" create "Foundation UX screenshot acceptance — canonical Bot tap + fail-closed states @ c074836" \
  --assignee apple-design \
  --body "READ-ONLY design acceptance of the QA-PASSED foundation candidate c0748368d04723ced8ba141c5dd14a62ca00ab84 (branch feature/true-bots-mode).apple-dev is concurrently implementing slice 2 in /tmp/hermes-fleet-true-bots — NEVER touch that tree or its simulator lane.

Work in YOUR OWN pinned worktree: cd /tmp/hermes-fleet-true-bots && git worktree add /tmp/hermes-design-c074836 c0748368d04723ced8ba141c5dd14a62ca00ab84 (worktree already exists = reuse it). Use your OWN DerivedData path and a DIFFERENT simulator device than any busy one (xcrun simctl list to pick; boot a dedicated one) to avoid build collisions with the dev worker.

Acceptance targets (from foundation-checkpoint.md + your design.md): (1) canonical Bot Chat tap opens the exact-title Bot Chat directly, native Fleet visual language, no fork/second chat; (2) fail-closed lookup state renders as an honest unconfirmed/blocked state (HERMES_FLEET_BOT_CHAT_FAIL knob exists in FleetSimulator/ScriptedBotModeChatSeam for scripting failure states — use simulator fixtures, no real gateway); (3) offline-ghost/source-qualified identity presentation if reachable in current UI.

Deliver: screenshots of each state, verdict PASS or HOLD per state with specific visual findings (hierarchy, spacing, safe areas, dark mode if feasible), written to /Users/tonysimons/.hermes/artifacts/true-bots-mode/design-foundation-acceptance.md, card comment summarizing verdict. Read-only on the repo: zero commits, zero file edits outside your evidence file and worktree build artifacts. Clean up: shut down your simulator device when finished." 2>&1 | grep -oE 't_[a-f0-9]+' | head -1)
echo "DES_ID=$DES_ID"
[ -n "$DES_ID" ] || { echo "FATAL: no design card id"; exit 1; }

echo "=== verify ==="
hermes kanban --board "$B" list
