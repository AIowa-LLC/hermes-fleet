#!/bin/bash
# Slice-5 card create + arm reroute guard + verify. set -u guards typos.
set -u
export PATH="$HOME/bin:$HOME/.hermes/bin:$PATH"
B="hermes-fleet-true-bots"
OUT=$(hermes kanban --board "$B" create "True Bots Mode slice 5 — RoomLink UI (D19) + mentions (D20) + typed attention (D22)" \
  --assignee apple-dev \
  --body "Implement slice 5 of True Bots Mode on base feature/true-bots-mode @ c8ee224 (already QA-accepted F1 fix merged; do NOT rebase or revert).

WORKSPACE: /tmp/hermes-fleet-true-bots, branch feature/true-bots-mode. Local commits only, never push.

SCOPE (three criteria):
D19 RoomLink UI: feature negotiation + installation identity + authority gateway/epoch + execution policy + grants + route registration/revoke + replication/replay + promotion prerequisites + explicit confirmations. HONEST unsupported state when the gateway does not support RoomLink — never fake cross-machine support. Ground every wire shape in upstream source at /Users/tonysimons/.hermes/hermes-agent (methods_groups.py @ 08b140d), not docs.
D20 Mentions UI: autocomplete live fleet @profile / friendly title / renamed tags / source-qualified handles, duplicate disambiguation, unknown strings pass unchanged, email addresses NOT treated as tags. Use the actual teammate workflow; never use user mention text as fabricated Bot delivery.
D22 Typed attention UI: typed failure/attention surfaces using the ACTUAL wire spelling (provider_auth/access/quota/rate_limit/server/context_overflow/missing_config/model_unavailable/runtime_offline/queued_expiry/delivery_timeout/target_busy/unknown) with meaningful recovery actions per type — never generic-only failure.

QUALITY BAR: TDD where practical. FleetUI must NEVER import FleetNetworking. Preserve existing features and safety guards. No credentials, private hostnames, local paths, or signing IDs in tracked data. Substantial VM + UI tests (scripted simulator fixtures). Keep baselines GREEN: FleetCore 312/0, FleetNetworking 356/0, hosted units 347/0, all existing UI suites, public_safety_guard PASS, gitleaks clean.

ON COMPLETION: write dev evidence to /Users/tonysimons/.hermes/artifacts/true-bots-mode/dev-slice5-report.md, commit locally, then kanban_request_review and STOP — no self-review; the card is rerouted to apple-qa automatically. Unattended -q mode: write scan/grep logic to script files, no inline one-liners/execute_code. If provider HTTP 429 hits, wait and retry per card guidance.")
ID=$(echo "$OUT" | grep -oE 't_[a-f0-9]+' | head -1)
echo "CREATED: $ID"
if [ -z "$ID" ]; then echo "FATAL: no card id captured"; exit 1; fi
sleep 5
hermes kanban --board "$B" comment "$ID" "ORCHESTRATOR BATCH AUTH: slice-5 scope per mission.md items 13/14/16 (D19/D20/D22). Single-flight: you are the only worker in /tmp/hermes-fleet-true-bots. Known QA-R1 non-blocking follow-up exists (scripts/f1_guards.sh gitleaks PIPESTATUS bug) — out of scope here, do not fix in this card." --author default
echo "COMMENTED"
hermes cron create --name "truebots slice-5 review reroute" --schedule "*/2 * * * *" --script truebots_slice5_review_reroute.sh --no-agent --deliver local
echo "GUARD ARMED"
