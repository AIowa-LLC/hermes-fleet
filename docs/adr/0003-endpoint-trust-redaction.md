# ADR-0003: Endpoint trust and redaction

**Status:** Accepted

## Context

A gateway endpoint is user-controlled input. Treating it as an unrestricted URL risks persisting, displaying, or logging embedded credentials or secret-bearing query parameters.

## Decision

Gateway endpoints are treated as origins, not credential containers.

- accept supported HTTP/HTTPS endpoint shapes
- reject URL user-info such as `user:password@host`
- strip query and fragment material at the registry boundary
- redact sensitive query keys before a URL is logged or displayed
- persist and render only the sanitized endpoint representation

Sensitive query names include common token, password, key, authorization, and secret forms.

## Consequences

Credential material embedded in user-info or secret-bearing query parameters does not become normal registry state, UI text, or diagnostic output.

The trade-off is intentional: gateways that require authentication embedded in arbitrary URL query parameters are outside the supported endpoint model and should use an explicit authentication strategy instead.
