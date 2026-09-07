# ADR-0005: Credential failure semantics

**Status:** Accepted

## Context

Credential replacement and deletion are security-sensitive state transitions. Delete-then-add replacement can destroy a working credential if the add fails, while suppressed deletion errors can make the UI claim a secret is gone when it is still present.

## Decision

Keychain writes are failure-safe and failures remain visible.

- update an existing item atomically when possible
- add only when the item does not already exist
- treat not-found deletion as a no-op, but propagate other deletion failures
- mutate registry state only after required credential cleanup succeeds
- require explicit confirmation for destructive gateway removal
- surface cleanup failures rather than silently swallowing them

## Consequences

A failed replacement should not destroy the previous working credential. A failed clear or removal leaves application state consistent with the possibility that secret material still exists.

The trade-off is deliberate: gateway removal may be refused when secure credential cleanup cannot be completed.
