# ADR-0005 — Credential failure semantics (Keychain)

- **Status:** Accepted + landed on `origin/main` @ `77379e9` (RT2 `t_2c13bdb3`).
- **Source:** Independent red-team report P1-8, P2-4; reviewed @ `273c2ad`.
- **Related:** `docs/M10-persistence-cache.md`, `docs/M11-authentication-hardening.md`,
  `spec §16 Secrets`.

## Context

Two Keychain failure-mode defects. **(P2-4)** The credential/token stores did
delete-then-add on save: a failed replacement could lose a working credential,
and `clear`/`remove` suppressed deletion errors while still changing registry
state — a failed delete could leave a secret behind while the UI reported it
absent. **(P1-8)** Gateway removal was a destructive swipe with `try?`
`removeGateway` (no confirmation), and credential cleanup failure was silently
swallowed.

## Decision

Keychain writes are failure-safe and failure-visible.

- **Atomic upsert:** save uses `SecItemUpdate` when the item exists and
  `SecItemAdd` only on `errSecItemNotFound` — never delete-then-add. A failed
  replacement keeps the working credential.
- **Deletion errors propagate:** `deleteCredential` throws on any status other
  than success / not-found (missing item is a no-op). `KeychainSession`
  abstracts `SecItem*` so injected failures are testable hermetically.
- **Registry only mutates on success:** `removeGateway` deletes the credential
  first and only removes the gateway when the delete succeeds (a failure
  leaves the gateway registered — no "removed" UI while a secret may exist).
  `clearCredential` only marks un-configured after a successful delete.
- **Removal is confirmed + reversible at the UI:** the destructive swipe now
  requires a named confirmation; failed cleanup is surfaced; the session is
  retired atomically (see ADR-0001).

## Consequences

- A failed Keychain replacement never loses a working credential; a failed
  clear/remove is visible and leaves state consistent.
- Covered by `FleetSecurityFailureSafetyTests` (254 lines: injected add/update/
  delete failures) + `RT2RemovalAndEndpointSanitizationUITests` (confirm/undo).
- Trade-off: gateway removal can be refused when Keychain deletion fails —
  surfaced to the user rather than silently cleaned up; deliberate.
