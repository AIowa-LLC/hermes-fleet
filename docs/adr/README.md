# Architectural decision records

ADRs document durable architectural choices and important constraints. They are not release notes or QA logs.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-per-gateway-session-ownership.md) | One runtime session/transport owner per gateway | Accepted, implementation pending |
| [0002](0002-replay-validation-idempotence.md) | Fail-closed replay validation and atomic replay hold/snapshot | Accepted, implementation pending |
| [0003](0003-endpoint-trust-redaction.md) | Treat gateway endpoints as origins and redact sensitive URL material | Accepted |
| [0004](0004-transcript-retention.md) | Separate authoritative transcript history from the bounded display window | Accepted |
| [0005](0005-credential-failure-semantics.md) | Make Keychain writes failure-safe and deletion failures visible | Accepted |
| [0006](0006-ats-cleartext-raw-ip-hosts.md) | Do not ship maintainer-specific ATS host exceptions | Superseded decision, current policy documented |
| [0007](0007-last-event-id-resume.md) | Track applied event IDs and recover stream gaps explicitly | Accepted |
| [0008](0008-drawer-parity-selection-pill-dismissal.md) | Drawer neutral selection, fixed compose pill, swipe dismissal (round-3 Codex parity) | Decision 2 superseded by ADR-0009 |
| [0009](0009-compose-pill-theme-coupling-and-white-accent.md) | Compose pill theme coupling and the White (mono) accent | Accepted, implementation pending |
| [0010](0010-groups-tab.md) | Groups as a first-class destination (separated from Chats) | Implemented in current source |
| [0011](0011-settings-about-tabs-and-legal-hosting.md) | Settings restructure, About tab, and official legal hosting at hermes-fleet.aiowa.dev | UI implemented; external publication/ASC evidence remains |
| [0012](0012-cached-first-instant-launch.md) | Cached-first instant launch (the Fleet launch cache) | Implemented in current source |

## Numbering rules

- **One file per ADR number.** `docs/adr/` never contains two files that start
  with the same `NNNN-` prefix.
- **ADR numbers are never reused.** A withdrawn, superseded, or renamed ADR keeps
  its number; do not hand the number to a different decision.
- **Stubs get their own number.** If a redirect or compatibility stub is ever
  needed, name it `NNNN-<slug>.md` with a unique number of its own rather than
  copying the number of the record it points to. Prefer marking the old ADR
  `Superseded` over creating a stub.
- **Claim the next free number in the same change that adds the ADR.** Before
  choosing a number, check this table and the reserved list below. To hold a number
  for planned work, add it to the reserved list in a small docs-only change first, so
  two lanes cannot claim the same number.

History: the collision that used to exist at `0003` was a redirect stub for the
Last-Event-ID decision that duplicated the endpoint-trust ADR's number. The stub
had no inbound links and was removed; that decision is
[0007](0007-last-event-id-resume.md).

### Reserved numbers

Next free number after the reserved block: **0016**. Replace a row with a real
table entry above when the ADR lands.

| Reserved | Planned decision | Tracking issue |
|---|---|---|
| 0013 | Tasteful Liquid Glass (supersedes the hit-testing part of ADR-0008) | #112 |
| 0014 | Pairing v2: short-lived, certificate-bound pairing code | #123 |
| 0015 | Local append-only hash-chained audit log | #136 |

## ADR status language

- **Accepted** means the decision is part of the intended architecture.
- **Accepted, implementation pending** means the decision is approved but current source does not fully implement it yet.
- **Superseded** means the historical decision was replaced by a newer policy and should not guide new work.

Accepted decisions describe architecture, not distribution or device evidence.
Implemented in current source means the behavior exists on the integration
line; consult `RELEASES.md` for a particular distributed build. External legal
publication, App Store Connect, physical-device, and live-gateway evidence must
be verified independently. Superseded decisions remain historical context.
