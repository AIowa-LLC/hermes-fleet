# Hermes Fleet release records

Distributed builds (internal dogfood, external TestFlight, or App Store) should
map to one source commit and one tag. The Build 90 record below retains its
source-to-archive attestation and tag limitations rather than asserting a
proven link that the retained evidence cannot establish.

## 0.2.0 (90)

- Public TestFlight availability reported by Tony on 2026-09-26.
- Recorded source snapshot: `dbb3fb9450b72a177100ac758950777649431353`,
  branch `fix/build-87-feedback`; clean build-checkout state matched the remote
  snapshot in the read-only release inspection.
- Retained archive: application version `0.2.0`, build `90`.
- Retained exported IPA SHA-256:
  `5ffe36436f1e596df0a06276ce0d2a653b24dc9b5df03fc3d498cd4ec3fb88c5`.
- Retained upload evidence reports success and valid processing. Its captured
  App Store Connect readback confirms internal distribution and predates public
  promotion; public availability is the owner's report, not a fresh API claim.
- Source-to-archive limitation: a build-time SHA attestation was not independently
  located. The clean source snapshot and archive/upload evidence are recorded
  separately; no cryptographically proven source-to-IPA claim is made.
- Source tag: not created by this reconciliation. Existing release tags and the
  distributed archive remain unchanged.
- Repository integration: PR #57 starts from the recorded Build 90 snapshot but
  carries a later inline-image scroll correction in `ConversationView.swift`,
  an associated UI-test harness repair, and CI capacity changes. These are new
  integration changes; they do not modify the distributed Build 90 archive,
  existing release tags, or TestFlight availability. Required PR and merge
  checks, including the group-history regression, determine acceptance of the
  repository candidate. Any later distributed binary needs its own build number
  and source record.

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

PR #54 did not land on 2026-09-24; it remained open with a recorded group-history
regression. On 2026-09-26 PR #56 landed the CI-only Dev Loop v3 policy on main at
`d358e3f4f7d7335fb3bbbff93a05a86f60aefdc1`. Build 90 product-source reconciliation
is a separate change, not evidence that the older PR already merged.

**Every distributed build records both its exact Git SHA and source branch/worktree.**
A build number alone never identifies a tree.
