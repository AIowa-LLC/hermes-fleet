# Public build 97 feedback follow-up

This local bug-fix batch starts at DEV12 source
`f021b0b3a0822f675305eca9919a0c90f99905af`, preserving DEV11
`66cc5871f5dc754468b55adadf99e8cc64e6fb32` and all subsequent onboarding,
branding, authentication, and host-readiness work. The reviewed public binary
was 0.2.0 (97), source `cd4e5513c6daf891bc96190719ef14159d9bfd2e`.
The historical release ledger describes its initial internal distribution;
the later read-only feedback review established public distribution.

## Acceptance matrix

| Feedback | Source trace and implementation | Required acceptance evidence |
| --- | --- | --- |
| Approval text unreadable in dark mode | Trace command review and themed controls, including long commands. The screenshot's blank white control has no established label. | Light/dark labels, long wrapped and unwrapped commands, large text; actual reporter/device acceptance pending. |
| Resume shows offline gateways and blank sessions; drafts lost | Trace scene lifecycle, recovery cancellation, manual connection intent and draft flush/restoration before changing inherited safeguards. | Repeated background/foreground and lock transitions; canceled/removed/manual-disconnect ownership; drafts preserved before debounce and after interruption/relaunch. |
| Sidebar omits sessions visible under a bot | Compare route/session identity, Recents policy, canonical chats, limits, archive and pin filters. Screenshot already shows an open populated drawer. | Cross-route ownership, duplicates, more than twelve eligible sessions, pin/archive/source filtering and refreshed list parity. |
| Composer Add actions do nothing | Trace File or PDF, Photo and prompt presentation through the composer menu. | Repeated presentation, cancel, successful selection, failed/unsupported attachment and visible failure; physical picker permission acceptance pending. |
| Copy and reactions do nothing | Trace actual rendered-message callbacks and gateway capabilities. | Exact copied message and visible confirmation; supported reaction/update/clear; unsupported or failed action explains failure. |

## Scope and evidence limits

Existing draft, authentication, reconnection, HTTP-warning and data-protection
changes must be inspected rather than presumed absent. Source inclusion in build
97 (including closed feedback issues) is not runtime acceptance. This batch does
not close the broader local-data-protection issue #82 or expand into live voice,
CarPlay or image clipboard paste. No schema/security-policy redesign is implied.

Use synthetic fixtures for automated checks. Simulator success does not prove
physical-device permission flows, post-relaunch reads from an actual server,
Mini onboarding, or a TestFlight upgrade. These checks remain separate delivery
acceptance gates. The separately repaired connector is outside this batch.

Local source commits and validation are authorized. Remote pushes, PR changes,
merges, uploads, installations on a phone and pairing credential issuance are
not authorized. Delivery requires the owner's later choice of internal
TestFlight or an available phone over WiFi.

## Related issue scope (read-only verification)

- [#55](https://github.com/AIowa-LLC/hermes-fleet/issues/55): client ownership
  refusal classification already landed through #59/#60. The stale Desktop
  lease requires a disposable live reproduction; no takeover or lease cleanup
  is part of this batch.
- [#62](https://github.com/AIowa-LLC/hermes-fleet/issues/62): HTTP warning copy
  remains an open separate usability task. Its warning predicate must remain
  intact; this batch does not change network trust.
- [#82](https://github.com/AIowa-LLC/hermes-fleet/issues/82): directory/SQLite
  sidecar, room-store and artifact-stage protection is broader than fixing draft
  retention. It remains open; this batch preserves protected draft writes.
- [#97](https://github.com/AIowa-LLC/hermes-fleet/issues/97): single transport
  coordinator migration remains open and outside this bug batch.
- [#99](https://github.com/AIowa-LLC/hermes-fleet/issues/99): explicitly records
  the missing background connection teardown. Fixing that lifecycle defect
  does not complete the issue's network-path monitor, jitter and other work.
