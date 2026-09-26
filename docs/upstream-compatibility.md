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
