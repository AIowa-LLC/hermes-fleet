# Hermes Fleet documentation

This directory contains the public developer documentation for Hermes Fleet.

## Start here

- [`architecture.md`](architecture.md) - module boundaries, runtime composition, data flow, and known architectural work
- [`features.md`](features.md) - current user-facing and management surfaces
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
