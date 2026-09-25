# Development workflow

One stable line, one integration line, short-lived work branches. This is the
branch model that keeps `main` boring: it always means "stable, releasable
baseline".

## Branches

| Branch | Meaning |
| --- | --- |
| `main` | Stable, releasable, protected baseline. The only source of release candidates. Changes land exclusively through a pull request and the merge queue; nothing is pushed to it directly. |
| `dogfood-next` | Integration branch for upcoming internal builds. New feature and fix work lands here first. |
| `feature/*` | Focused feature/fix branches cut from `dogfood-next` and merged back into it. |
| `hotfix/*` | Urgent fixes cut from `main`, merged into `main` through the standard pull request and merge queue, then immediately propagated into `dogfood-next`. |

Do not place new feature work directly on `main`.

## Rules

- Every production or beta bug fix adds a regression test whenever technically
  practical.
- Every TestFlight build maps to an exact commit and tag (see
  [`../RELEASES.md`](../RELEASES.md)); release-candidate commits are never
  ambiguous.
- Validate work with the local loop (`make dev-check`) before pushing; the
  merge queue runs changed-area UI checks and the critical journey smoke. The
  complete UI matrix remains available for nightly and manual deep validation
  (see [`dev-loop.md`](dev-loop.md)).
- Release candidates are produced only from a green `main` via the repository
  release procedure (see [`release-preflight.md`](release-preflight.md)).
