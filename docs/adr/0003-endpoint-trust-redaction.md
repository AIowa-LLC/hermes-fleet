# ADR-0003 — Endpoint trust and redaction policy

- **Status:** Accepted + landed on `origin/main` @ `77379e9` (RT2 `t_2c13bdb3`).
- **Source:** Independent red-team report P1-6; reviewed @ `273c2ad`.
- **Related:** `docs/M7-gateway-registry.md`, `spec §29 Logging`.

## Context

A user-controlled gateway endpoint was treated as a full URL. Endpoint
validation checked only the scheme; ticket/password clients logged
`baseURL.absoluteString` publicly (one logged unredacted error descriptions);
the gateway row displayed `endpoint.absoluteString`; and `Redaction` protected
only a fixed set of query keys — it did not strip URL user-info/password. A
pasted `user:password@host` or secret-bearing query endpoint could therefore
be persisted, shown, or logged as-is.

## Decision

Endpoint input is treated as an **origin**, not a URL.

- `GatewayEndpoint.normalizedOrigin(from:)` (FleetCore) requires an
  `http`/`https` scheme, **rejects any user-info** (`user:pass@host`), and
  **strips query + fragment**, preserving scheme/host/port/path. Applied at the
  registry boundary on both add (`GatewayRegistryService.addGateway`) and edit
  (`updateGateway`) — before anything is stored, displayed, or logged.
- `Redaction.redactedURL(_:)` strips user-info and redacts values of
  sensitive query keys (`ticket`, `token`, `access_token`, `refresh_token`,
  `session_token`, `id_token`, `api_key`, `apikey`, `key`, `password`,
  `passwd`, `secret`, `internal`, `auth`, `authorization`) with `[REDACTED]`,
  while preserving scheme/host/path so a human can still tell which gateway
  failed.
- Logs / UI render only the sanitized origin.

## Consequences

- Credential material embedded in an endpoint (user-info or secret query
  params) can never reach the registry, Keychain, logs, or UI.
- Covered by `GatewayEndpointTests` and `GatewayRegistryServiceTests` (user-info
  and sensitive-query rejection) + `RT2RemovalAndEndpointSanitizationUITests`.
- Trade-off: endpoints with meaningful query parameters or path-bound auth are
  not representable — deliberate, documented origin model. Query/fragment are
  silently stripped rather than rejected so normal gateway URLs keep working.
