# Hermes Fleet documentation

This directory contains the public developer documentation for Hermes Fleet.

## Source-of-truth hierarchy

Sources of truth for Hermes Fleet, in order of authority:

1. **Current source code** — implemented behavior. The code is the final
   arbiter of what the app actually does.
2. **Current public docs** (this directory) — supported surfaces and behavior
   descriptions, maintained to match the source.
3. **Accepted ADRs** ([`adr/`](adr/)) — durable architectural decisions.
4. **Historical specs and milestone files** — historical context only when
   superseded; never release truth.

The original **Product & Protocol Specification v0.1** is not stored in this
repository; it is retained outside the active repository in the maintainer's
private project authority documents. Its **foundational principles remain
normative** — iPhone as control plane, Hermes machines as compute plane,
stock-Hermes-first integration, permanent gateway provenance,
server-authoritative state, fail-closed routing, reconnect/replay safety, and
direct-to-gateway privacy/security boundaries — but its **feature scope is
superseded**: the current app implements substantially more (Bot Mode,
SOUL/profile management, approvals, cron, memory/project surfaces, Groups,
RoomLink, attachments, reactions, and other Hermes Desktop-parity work) than
the v0.1 document deferred or excluded.

## Start here

- [`architecture.md`](architecture.md) - module boundaries, runtime composition, data flow, and known architectural work
- [`features.md`](features.md) - current user-facing and management surfaces
- [`navigation.md`](navigation.md) - four-tab structure, screen ownership, and navigation restoration
- [`gateway-pairing.md`](gateway-pairing.md) - gateway setup, manual entry, and QR pairing
- [`adr/`](adr/) - architectural decision records

## Historical milestone files

Files with names such as `M*`, `U*`, `R*`, `H*`, `L*`, `F*`, `T*`, and `X*` are retained as stable historical references because source comments, old links, or external discussions may still point to those paths.

They are **not current release notes, QA dashboards, visual specifications, or distribution status**. Detailed internal execution logs have been removed from the public documentation surface. Use the current source, this documentation index, and the ADRs for present behavior.

## Documentation standard

Public documentation should:

- describe behavior that is supported by current source
- use synthetic examples instead of maintainer-specific infrastructure
- avoid credentials, private endpoints, personal device details, signing identifiers, and local filesystem paths
- distinguish implemented behavior from accepted future architecture
- avoid treating simulator fixtures as evidence of a live deployment
- keep visual direction separate from protocol and architecture truth

When behavior changes, update the relevant current document and ADR in the same change when practical.
