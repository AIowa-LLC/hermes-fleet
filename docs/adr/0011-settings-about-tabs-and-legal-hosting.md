# ADR-0011: Settings restructure, About tab, and official legal hosting

- **Status:** Accepted (approved 2026-09-19; implementation pending)
- **Deciders:** Tony (owner; all five decisions answered by number), apple-dev
- **Related:** ADR-0009 (curated accent picker + White mono accent), ADR-0010
  (Groups tab — tab-surgery precedent), SPEC §12 (Settings), SPEC §14 (visual
  identity), `docs/settings-and-about-tabs.md` (implementation spec)

## Context

Fleet's Settings is a flat seven-section Form: every control sits on one
surface, version and legal links are mixed with functional settings, and the
legal surfaces are unready for external App Store distribution:

1. The in-app Privacy Policy links a GitHub blob URL
   (`github.com/AIowa-LLC/hermes-fleet/blob/main/PRIVACY.md`); no Terms of
   Use link exists anywhere in the app.
2. The App Store Connect record for `com.aiowa.hermesfleet` (app 6807148674)
   has **no `privacyPolicyUrl` set** (verified live via the ASC API
   2026-09-19) — App Review Guideline 5.1.1(i) requires the privacy policy
   link in ASC metadata AND in-app in an easily accessible manner.
3. The owner wants the ChatGPT settings anatomy: quick value-pickers at the
   top, everything else behind chevron rows pushing dedicated sub-screens,
   with version/legal/about content in its own place.

## Decision

1. **Legal hosting** — Terms of Use and Privacy Policy are published at the
   official subdomain `hermes-fleet.aiowa.dev` (`/terms`, `/privacy`). The
   GitHub blob URLs are retired from the UI. `PRIVACY.md`/`TERMS.md` in the
   repo remain the source of truth for content.
2. **Terms of Use** — a lightweight in-app Terms document is added; Apple's
   Standard EULA remains the app license (NO custom EULA uploaded to ASC —
   custom EULAs add review surface without benefit here).
3. **About is a first-class tab** — full tab surgery (`FleetTab.about`, last).
   It carries app identity, version/build, Terms of Use, Privacy Policy, and
   Support. The `fleet.settings.version` + legal link rows move there.
4. **Settings restructure** — root becomes quick Theme rows (Appearance
   collapsed to a one-row value picker; curated accent picker unchanged per
   ADR-0009) + "App settings" chevron rows (Security, Data & Storage) that
   push sub-screens on the Settings tab's own local route enum. The C2
   always-reachable setup-prompt row stays on the Settings root.
5. **SPEC amendments** — §12 is amended to describe the tab + sub-screen
   structure and the About tab; §14's "retire the general accent picker" is
   superseded by the ADR-0009 curated picker. Draft amendment text lives in
   `docs/settings-and-about-tabs.md` §8; the external SPEC file is edited only
   on the owner's explicit go.

## Alternatives rejected

- **Legal content in-app only (ASC `privacyPolicyText` + rendered view):**
  satisfies review but leaves no canonical public URL for the ASC metadata
  field and fragments the source of truth; the owner already operates a dev
  domain.
- **GitHub Pages URL on the existing repo:** would work, but the owner chose
  the official subdomain for brand credibility.
- **About as a sub-screen inside Settings (ChatGPT's exact anatomy):** owner
  explicitly chose full tab surgery.
- **Custom ASC EULA:** rejected — Apple's Standard EULA governs by default and
  a custom one adds review surface for no gain.
- **Inline pickers everywhere (status quo):** rejected — the flat form is the
  "sloppy" surface the owner flagged.

## Consequences

- Tab set grows 7 → 8 (6 primaries + Settings + About); drawer primary arrays
  are unaffected (`about` is non-primary), hosted label-array equality and
  tab-bar label asserts change in the same commit (spec §7).
- `fleet.settings.version` / `privacy-policy` / `support` ids retire to
  `fleet.about.*`; retirement is pinned with source-guard tests.
- Appearance's AX contract changes (inline buttons → menu row); affected
  suites migrate in the same change.
- The external SPEC file and the ASC `privacyPolicyUrl` field remain untouched
  until separate explicit go signals.
- Site publishing (DNS/hosting for `hermes-fleet.aiowa.dev`) is coordinated
  outside the app repo; content is staged in-repo now.
