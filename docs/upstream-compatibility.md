# Upstream feature compatibility

The goal is quick, small integrations of verified upstream capabilities, not
unqualified claims of parity or blindly copying desktop behavior into iOS.
This document defines intake; it does not claim that an upstream audit has been
completed or install a monitoring service.

## Intake record for each feature

Use the upstream-feature issue template. Record the authoritative upstream
repository, release/commit, feature description, relevant protocol implementation,
and the gateway version or advertised capability that enables it. A social post
is discovery evidence, not an API contract.

Separate these states: discovered, contract verified, planned, implemented,
validated internally, and distributed. Link the Fleet PR and release record as
the work advances. Do not mark a feature compatible simply because code exists.

## Smallest safe vertical slice

Before implementation, identify the request/response or event contract, streaming
and cancellation behavior, authentication/approval requirements, persistence
impact, and behavior against an older gateway that lacks the capability.

Implement protocol/model coverage with synthetic fixtures before the UI. Keep
unsupported behavior explicit and actionable; hide or disable a feature when its
capability is absent rather than making a misleading request. Preserve older
supported gateways unless a deliberate minimum-version change is approved.

Prefer one coherent feature PR over batching several unrelated features. Avoid
unrelated visual or architecture refactors. New UI tests must join the canonical
inventory and relevant changed-area mapping.

## Evidence by stage

| Stage | Required evidence |
| --- | --- |
| Contract verified | Upstream source/release reference, schema or sanitized wire evidence, capability/version behavior. |
| Implemented | Focused diff, fixtures and regression tests, documented unsupported/error path. |
| Merge accepted | Required checks on the exact PR and combined merge candidate. |
| Internal validation | Exact Fleet build/source and relevant real-gateway/device checks. |
| Distributed | Release record identifying the actual TestFlight build and audience. |

Shared transport, persistence, authentication, or compatibility changes deserve
broader validation. A narrow UI affordance can use focused tests without running
unrelated UI journeys. See [dev-loop.md](dev-loop.md).

## Maintenance

When an upstream change is discovered, update its intake record and reproduce
its contract before changing Fleet. Keep a supported-gateway compatibility matrix
with evidence as versions are actually tested; do not invent version support.
Use explicit known-issue entries for gaps and release notes for newly distributed
support. Monitoring cadence and automatic issue creation require a separate,
explicitly configured workflow.

## Compatibility notes

Entries record what was verified and how; they do not extend support to
versions that were not tested.

### Server-to-client JSON-RPC requests (`approval`, `clarify`, `sudo`, `secret`)

| Field | Record |
| --- | --- |
| State | Contract verified; implemented; validated internally against synthetic fixtures. Not yet validated against a live gateway build. |
| Upstream | `hermes-agent` commit `9f7f2f28c0` (on `main`, not in tag `v2026.9.11`) replaced the `approval.request` / `*.respond` event pairs with server-to-client JSON-RPC requests. |
| Contract evidence | `tui_gateway/server_requests.py` (ids `srq-<12 hex>`, `request.cancel`, `open_requests`, capability gate), `tui_gateway/session_transports.py` (`_session_client_answers_requests`), and the generated OpenRPC contract `apps/shared/src/gateway-contract.openrpc.json` (`x-server-requests`, `x-notifications` `request.cancel`, `OpenRequestEntry`, `ClientCapabilitiesParams`). |
| Enabling capability | The client sends `client.capabilities {server_requests: true}` once per connection after `gateway.ready`. A WebSocket client that never does is treated as an older build and the gateway withdraws the request (an approval is withdrawn, not denied). Fleet sends it only on the conversation transport, and re-sends it after every reconnect. |
| Wire behavior | The gateway sends a request frame with a string id; Fleet answers with a JSON-RPC response carrying the same id: approval `{choice, all?}`, single clarify `{answer}` (`''` skips), batch clarify through `clarify.lock {request_id, question_id, answer}` (a result with no `answers` is cancel-all), sudo and secret `{value}` (`''` declines). Unknown or unsupported methods get `-32601`; supported methods with unusable params get `-32602`. |
| Cancellation | `request.cancel {id, method, reason}` dismisses the matching prompt only. Fleet sends no response and records no denial; an id it does not know is ignored. |
| Reconnect | `session.resume`, `session.activate`, and `session.events.since` return `open_requests`; Fleet re-surfaces each entry under its original id and de-duplicates against prompts already shown. The transport drops its copy on disconnect because the gateway keeps the request open. |
| Older gateways | A gateway that predates the protocol keeps the legacy path: the `approval.request` event is answered with `approval.respond`. The same `request_id` de-duplicates the two paths, so one approval never renders twice. If `client.capabilities` returns an error, no request-based prompt is promised. |
| Out of scope | Vault, preview, terminal, window, and tour requests (answered `-32601`); a minimum-gateway-version decision; the approval card redesign. |
| Remaining evidence | One check against a disposable gateway built from `9f7f2f28c0` or newer (environmental; record only the commit and the outcome, never a hostname or credential). |
