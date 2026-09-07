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

## ADR status language

- **Accepted** means the decision is part of the intended architecture.
- **Accepted, implementation pending** means the decision is approved but current source does not fully implement it yet.
- **Superseded** means the historical decision was replaced by a newer policy and should not guide new work.
