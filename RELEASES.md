# Hermes Fleet release records

Every distributed build (internal dogfood, external TestFlight, or App Store)
maps to exactly one commit and one tag. A record is added or updated in the
same change that creates the tag, and the tag always points at the commit that
produced the uploaded build.

## 0.2.0 (86)

- First external TestFlight candidate
- Submitted: 2026-09-23
- Git SHA: bd94272552bf1751b464535f1b6043b90e36d059
- Tag: testflight-0.2.0-build86
- External group: Beta Crew
- Status at time of documentation: Waiting for Review

## Build numbering and provenance

**Build numbers are counters, not lineage.**

Before 2026-09-24 the project ran two independent lines that shared one App Store
Connect build-number counter:

- **`main` — the stable line.** Build 86 was archived, exported, and uploaded from this
  line, from the repository-root worktree at commit `bd94272…` (tag
  `testflight-0.2.0-build86`). Provenance: `build/release-preflight/bd94272…/export/`
  holds the exact shipped IPA (14,711,724 bytes, sha256
  `3db1d4abd9beaca5691580a3c74489718087bd178cab0782a56a383c59b9122b`; ASC Delivery UUID
  `99e13de9…`), and its archive dSYMs compile from the repository root with none of the
  dogfood-only sources. The dogfood UI work was never on this line, so the first external
  beta shipped the stable surface by explicit choice (2026-09-23: "get the current main
  onto the External TF since the existing features are confirmed working").
- **`dogfood/build-41-integration` — the internal dogfood line** (builds 41–85), forked
  from `d0f607b` (2026-09-15) and developed in parallel. Its build 85 was uploaded first
  and occupied that number, which is why the stable line's external submission was
  bumped 85 → 86.

The main-branch baseline arrived via a squash merge, so it is a distinct commit from the
shipped one; the exact shipped commit remains `bd94272…` (tag `testflight-0.2.0-build86`).

On 2026-09-24 the dogfood line was integrated into `main` (PR #54). From here on builds
continue from `main`.

**Every distributed build records both its exact Git SHA and source branch/worktree.**
A build number alone never identifies a tree.
