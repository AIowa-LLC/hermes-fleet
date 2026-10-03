# Upstream proposals (drafts)

Four draft proposals for the upstream Hermes Agent project, written from the
mobile-client perspective of Hermes Fleet. Each file is written as a ready-to-file
issue or RFC.

**Nothing here has been filed.** Whether, where and in what form to file each draft
is a maintainer decision. No agent or automation files upstream issues, pull
requests, comments or discussions. Hermes Fleet never blocks on upstream: every
draft has a "Fleet without this proposal" section describing what ships today.

| Draft | Fleet issue | Topic | Fleet path that ships without it | Prior upstream art found (2026-09-30) |
| --- | --- | --- | --- | --- |
| [U1](U1-native-app-scheme-redirect.md) | #150 | Operator-approved app-scheme redirect for native OAuth sign-in | Password login and pairing (#123); OAuth-only gateways stay unsupported (#61, epic #73) | hermes-agent #94733 (open) asks for the same contract: prefer supporting it over a duplicate. Also #118055 (prefix-proxy cookie path bug). |
| [U2](U2-signed-approval-decisions.md) | #151 | Gateway-verifiable, request-bound approval signatures | #129 (device key, plugin-side verifier) | hermes-agent #89853 (open, host-signed receipts, inverse direction) and #104960 (open PR, request-bound approval cards). |
| [U3](U3-signed-pairing-tokens.md) | #152 | Short-lived, single-use pairing tokens in the core gateway | #123 Phase A (client-enforced expiry, nonce, SPKI pin); Phase B via plugin if feasible | None found; #126292 (mobile apps request) mentions QR pairing. |
| [U4](U4-push-observer-hooks.md) | #154 | Push-oriented observer hooks for approvals, server requests, turn end | #88 (PR #160) using existing hooks; #95 interim local notifications | hermes-agent #92245 (closed, not planned; broader), #67798 (open; shared hook contract). |

Related Fleet work cross-checked for consistency: #61, #123, #129, #88 / PR #160
(push sender in the liveops plugin), #157 (content-blind relay), #95.

## Verification baseline

All upstream evidence was re-read in a local checkout on 2026-09-30. The upstream
commit used is `30de041b01` (`main` as last fetched locally, committed 2026-09-19).
The checkout was on a fork branch at `086cbd2464`, which adds one unrelated commit
(a `session.list` field); a diff over every file the drafts cite confirmed the
cited files are identical to `30de041b01`. Citations use the form
`hermes-agent: <path>` with the symbol name. Before filing, re-check against the
then-current upstream `main`.

Prior-art pointers come from read-only searches of the public upstream issue
tracker on the same date. They are discovery leads, not contracts, and their state
may have changed. The maintainer should repeat the duplicate search that the
upstream `CONTRIBUTING.md` asks for.

Nothing in these drafts was run against a live gateway or a device.

## Corrections found against the planning issues

Verifying the evidence in the planning issues turned up differences. They are
recorded in each draft's "Drafting notes" section and summarized here.

- **U2 / #129:** the approval transport is not CLI-only. It is selected in `tools/approval.py::_human_decision` ahead of the gateway-queue branch for the command and `execute_code` gates, and a selected transport replaces every built-in prompt surface (including the TUI and dashboard card). It never applies to plugin-escalated tool calls. #129's Phase B spike option (b) is therefore technically available with an all-or-nothing caveat. There are three answer paths (`approval.respond`, the `approval` response frame, `request.answer`), not one.
- **U4 / #154 and #88:** the approval hooks do carry the agent `session_id`, `turn_id` and `tool_call_id`; the missing pieces are `request_id` (which exists before the hook fires but is not passed), runtime session id, expiry and gate kind. `on_session_end` is already a content-free per-turn signal (how PR #160 implements "done"). `agent:end` is messaging-gateway only (answered with a source reference). `server_request_id` cannot be on the approval hooks without reordering, so it is proposed on a new observer.
- **U3 / #152:** the redemption route belongs in `_GATE_PUBLIC_PREFIXES`, not `PUBLIC_API_PATHS`; the dashboard server does not terminate TLS, so the gateway usually cannot know its SPKI; the SAS must be computed independently by each side.
- **U1 / #150:** capability discovery already exists as `auth_flows` on the public status endpoint.

## Cross-check of open Fleet work

- **PR #160 (R2, liveops push sender, head `e9ecf0dd8e`, stacked on #157):** the gaps it documents under #154 (no `request_id` in hook kwargs, no clarify observer, no content-free turn-end observer for TUI sessions, no `approval.respond` interception) are all covered: U4 sections 4.1 to 4.3 and U2. The U4 draft's "Fleet without this" table maps each sealed-payload field to its source today and after U4. Two findings are reported for the R2 lane and were not changed here: the sender does not filter `surface` (smart-mode decisions fire the approval hook with no human involved), and delegated child agents can be suppressed today through `subagent_start`.
- **PR #157 (R1, relay, head `43f543076d`):** unaffected. No proposal changes the relay contract; the relay sees only ciphertext plus a fixed title key.

## Conventions

- Public-safe and synthetic: example hostnames use `example.com`, identifiers are invented, no credentials, personal identifiers or local paths.
- Keys in vectors are throwaway; the U2 vector was generated for documentation only and its private key discarded.
- Each draft's "Fleet without this proposal" and "Drafting notes" sections are Fleet-internal context; condense or drop them when filing.
- Format, venue and naming are left to the maintainer; upstream contribution norms were not verified beyond `CONTRIBUTING.md`.

## Decision log (maintainer to update)

| Draft | Decision | Venue and link | Date |
| --- | --- | --- | --- |
| U1 | Not filed | | |
| U2 | Not filed | | |
| U3 | Not filed | | |
| U4 | Not filed | | |
