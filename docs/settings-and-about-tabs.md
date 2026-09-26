# Settings restructure: ChatGPT-style sub-menus, About tab, official legal hosting

Status: **Approved 2026-09-19** — Tony answered all five decisions-needed items by
number (1–5). Implementation awaits a separate explicit go; this document does
not authorize code changes. Decision record: [ADR-0011](adr/0011-settings-about-tabs-and-legal-hosting.md).

## 1. Summary

Settings today is a flat seven-section Form with zero drill-downs. This change
restructures it into the ChatGPT settings anatomy — quick value-pickers at the
top, everything else behind chevron rows that push sub-screens — adds **About
as a first-class tab** (full tab surgery, owner decision 3), moves version +
legal links into that tab, and repoints Terms of Use / Privacy Policy at an
official `hermes-fleet.aiowa.dev` subdomain (decisions 1–2) to satisfy App
Review Guideline 5.1.1(i) properly. The Appearance picker collapses to a
one-row value picker (decision 4), and SPEC §12/§14 amendment text is drafted
here (decision 5); the external SPEC file is edited only on Tony's explicit go.

## 2. Current state (inspected 2026-09-19, lane tree @ 644a499)

| Surface | File | Today |
|---|---|---|
| Settings root | `Packages/FleetUI/Sources/FleetUI/FleetSettingsView.swift` | Flat Form: Security (App Lock toggle), Local Data (Delete Local Cache), Appearance (3-row inline picker), Theme (accent Menu row — already ChatGPT-style), Agent (Set Up Another Server), Version, Help & Privacy (2 Links) |
| Hosting | `FleetTabView.swift` | Settings is a first-class tab since Build 43 (`case .settings` last) |
| Legal | same file | Privacy Policy → `github.com/AIowa-LLC/hermes-fleet/blob/main/PRIVACY.md`; Support → GitHub issues; **no Terms link exists anywhere** (grep-verified) |
| ASC record | App Store Connect app 6807148674 | `privacyPolicyUrl` **unset** at app level AND en-US localization (verified live via ASC API 2026-09-19) — external-release submission blocker under 5.1.1(i) |
| Policy content | `PRIVACY.md` | Strong on collection/retention; missing an explicit revoke-consent/request-deletion sentence 5.1.1(i) asks for |

## 3. Target structure

### 3.1 Settings tab root (`FleetSettingsView`, restructured)

```
SETTINGS
┌ Theme ─────────────────────────────────┐
│  Appearance        System         ⌄⌃  │  Menu picker, one row
│  ● Accent          Violet         ⌄⌃  │  unchanged (ADR-0009)
├ App settings ──────────────────────────┤
│  Security (Face ID)                 ›  │  push
│  Data & Storage                     ›  │  push
├ Agent ─────────────────────────────────┤
│  Set Up Another Server                 │  sheet, stays on root (C2)
└────────────────────────────────────────┘
```

- **Appearance** (decision 4): the 3-row inline picker becomes one Menu row —
  value label + `chevron.up.chevron.down`, same options System/Light/Dark,
  applied immediately through `FleetAppearanceController.shared` as today.
  Identifier `fleet.settings.appearance` is KEPT; its AX contract changes from
  three inline buttons to a menu row (test migration in §7).
- **Accent**: unchanged — already the ChatGPT pattern (swatch + value + menu,
  immediate apply). `fleet.settings.accent` and all `fleet.settings.accent.*`
  menu ids keep working with zero edits.
- **Security sub-screen**: App Lock toggle + existing footer copy move behind
  a chevron row. Toggle id `fleet.settings.app-lock.toggle` is KEPT (11 test
  occurrences across 5 files keep passing after the navigation step is added).
- **Data & Storage sub-screen**: `Delete Local Cache` + its confirmation dialog,
  alert, and footer explanation move behind a chevron row. Button id
  `fleet.settings.delete-local-cache` is KEPT.
- **Set Up Another Server**: remains a root row per the C2 always-reachable
  contract (SPEC §12: "The setup prompt remains reachable after onboarding").
- Sub-screens push on the Settings tab's own stack via a LOCAL route enum
  (e.g. `SettingsSection`) with its own `navigationDestination` — NOT new
  `FleetScreen` cases. No persisted-nav decode migration results (§6).

### 3.2 About tab (new, decision 3 — full tab surgery)

```
ABOUT
┌ Hermes Fleet ──────────────────────────┐
│  [app icon]  Hermes Fleet              │
│  A pocket operations console for your  │
│  agents.                               │
├ Version ───────────────────────────────┤
│  Version            1.x.y (nn)         │
├ Legal ─────────────────────────────────┤
│  Terms of Use                          │  Link → https://hermes-fleet.aiowa.dev/terms
│  Privacy Policy                        │  Link → https://hermes-fleet.aiowa.dev/privacy
│  Support                               │  Link → GitHub issues (unchanged target)
└────────────────────────────────────────┘
```

- New view `FleetAboutView.swift`; new `FleetTab` case `about`, ordered last
  (after `settings`). Icon `info.circle` (grep-verified unused by tabs today).
- `isPrimary` excludes `about` alongside `settings` — the drawer renders it as
  a dedicated row after Settings. Primary count stays 6, so iPad
  `sidebarAdaptable` pagination behavior is UNCHANGED from today's 7-tab state.
- Tagline reuses the existing Settings footer copy ("Hermes Fleet — a pocket
  operations console for your agents.") — no new marketing copy invented.

### 3.3 AX identifier ledger

| Id | Fate |
|---|---|
| `fleet.settings` (surface) | keep |
| `fleet.settings.accent`, `fleet.settings.accent.*` | keep (root) |
| `fleet.settings.appearance` | keep id, contract changes to menu row |
| `fleet.settings.app-lock.toggle` | keep id, now inside Security sub-screen |
| `fleet.settings.delete-local-cache` | keep id, now inside Data & Storage |
| `fleet.settings.setup-prompt` | keep (root row) |
| `fleet.settings.version` | RETIRE → `fleet.about.version` (2 occurrences: U7 assert + source) |
| `fleet.settings.privacy-policy` | RETIRE → `fleet.about.privacy-policy` (1 UITest site) |
| `fleet.settings.support` | RETIRE → `fleet.about.support` (1 UITest site) |
| — new | `fleet.about` (surface), `fleet.about.terms`, `fleet.settings.security`, `fleet.settings.data` |

Retirements get source-guard pins (contains-assertions on the new file) per
the drawer/ADR-0010 precedent, after grep proves zero live callers.

## 4. Legal hosting & App Store compliance (decisions 1–2)

- **URLs**: `https://hermes-fleet.aiowa.dev/privacy` and
  `https://hermes-fleet.aiowa.dev/terms`. Single `FleetLegal` constant block
  (or statics on `FleetAboutView`) holds the base URL — one edit point if the
  domain changes.
- **Terms of Use**: new `TERMS.md` at repo root (symmetry with `PRIVACY.md`).
  Lightweight B2C terms: license grant, acceptable use, user-responsibility
  for gateways they connect (AIowa is not party to data sent to user-operated
  gateways), disclaimer of warranties, limitation of liability, termination,
  governing law, changes. Apple **Standard EULA** remains the license backbone
  (no custom EULA uploaded to ASC — decision 2); the in-app Terms doc governs
  service behavior, not app licensing.
- **PRIVACY.md updates**: add a "Your choices" paragraph stating how to revoke
  consent / request deletion (delete app data via Data & Storage, remove
  gateways, contact channel); update the third-party-visit note to cover
  `hermes-fleet.aiowa.dev` (the domain operator sees request IPs, as the note
  already says for GitHub); refresh Last-updated date.
- **ASC metadata**: set `privacyPolicyUrl` on app 6807148674 (en-US) to the
  privacy URL — closes the verified 5.1.1(i) gap. Release-time action on
  Tony's explicit go, listed in the release checklist.
- **Publishing the site** (out of app-repo scope): static hosting for the two
  documents at the subdomain, content rendered from the repo files so review
  happens in-repo. DNS/hosting bring-up is coordinated separately with Tony.

## 5. Work items

| # | Item | Old → New | Acceptance metric |
|---|---|---|---|
| W1 | Settings root restructure | flat 7 sections → Theme (2 rows) + App settings (2 chevron rows) + Agent | App builds; `fleet.settings` renders; accent ids untouched |
| W2 | Appearance row collapse | 3 inline buttons → 1 Menu value row | U7 updated test opens menu, all 3 options assertable, apply works |
| W3 | Security sub-screen | inline section → pushed screen | `fleet.settings.app-lock.toggle` reachable after 1 push; H1 suite green |
| W4 | Data & Storage sub-screen | inline section → pushed screen | cache-clear flow (confirm dialog + failure alert) intact; U7 green |
| W5 | `TERMS.md` authored | absent → root file | legal review by Tony; renders at /terms content-staged |
| W6 | `PRIVACY.md` edits | no consent/deletion paragraph → "Your choices" + domain note | paragraph present; mentions revoke + deletion paths |
| W7 | About tab surgery | 7 tabs → 8 (`about` last) | full checklist §6 applied; AppComposition label array green |
| W8 | `FleetAboutView` | absent → identity/version/legal rows | new UITest class green (see §7 matrix row) |
| W9 | Legal URL constants + link rows | GitHub blob URLs → aiowa.dev URLs | unit test asserts exact URLs; UITest asserts rows exist |
| W10 | Retirement guards | old ids live → retired + source-guarded | grep zero live callers; guard tests fail on reintroduction |
| W11 | SPEC §12/§14 amendment drafts | external SPEC stale → drafts staged here (§8) | links resolve; external edit only on explicit go |
| W12 | ADR-0011 + index | absent → filed, Accepted | README index row present |

## 6. Tab-surgery checklist (skill `root-shell-tab-surgery`, applied)

1. `FleetTab` enum: add `about` LAST (after `settings`); `label` "About";
   `systemImage` `info.circle`. `isPrimary` excludes both `settings` and
   `about`.
2. `FleetScreen.owner`: **no changes** — About owns no `FleetScreen`
   destinations; Settings sub-routes are a local enum.
3. Persisted nav-state decode: **no migration needed** — no destination
   changes owner; a missing `about` key in `fleet.navigation.v1` decodes to an
   empty path (unknown-key tolerance already proven by the Gateways retirement).
4. `FleetTabView.root(_:)`: `case .about: FleetAboutView()`.
5. AUTO_NAV: add `"about"` to `legacyTab(_:)` and the auto-nav raw list;
   UITests may launch with `HERMES_FLEET_AUTO_NAV=about`.
6. iPad pagination: primaries stay 6 — behavior unchanged from today.
7. Tab pins, same change:
   - Hosted: `AppCompositionTests.testAppTabModelCoversFiveOwningDomains`
     label array 7 → 8 (rename test to drop the stale "Five"), update the
     nearby comment.
   - UITests: drawer PRIMARY raw arrays (`["bots","chats",…]`, 4 occurrences
     across FOS3/U3/B43) do NOT change (about is non-primary) — verify by
     grep, don't edit. Tab-bar label equalities / tab-count asserts /
     `tabControl` lists DO change: add "About"/`about` (UITabNavigation label
     maps at 3 sites + any per-class list asserts, enumerated by grep at
     implementation).
8. AX ids move with the surface (§3.3 ledger) + retirement guards (W10).
9. Drawer: add the About dedicated row after Settings (same section as the
   current settings row; grep `isPrimary` in `FleetNavigationDrawer.swift`).
10. Command Center: add About alongside Settings in the static destination
    list if the launcher enumerates tabs (verify at implementation; SPEC §13
    lists Settings today).

## 7. Test impact

| Suite/file | Change | Reason |
|---|---|---|
| `AppCompositionTests` (hosted) | label array +1, test rename | tab set 7→8 |
| `UITabNavigation.swift` | 3 label→raw maps + `openAbout` helper | new tab navigation seam |
| `U7GatewayQrLockSettingsUITests` | appearance contract (open menu first); version assert → About tab | W2, id move |
| `H1AppLockUITests` | navigate into Security sub-screen before toggle asserts (2 sites) | W3 |
| `C2SetupPromptUITests` | none expected (row stays on root) — verify | C2 contract preserved |
| `FleetSettingsAccentUITests` | none (8 tests stay green unedited) | accent untouched |
| `FOS3FourRootShellUITests`, `B43NavigationEditingUITests`, `U3TabNavigationUITests` | tab-set/label asserts +About; drawer arrays verified unchanged | W7 |
| NEW `FleetAboutUITests` | About renders, version row, 3 legal rows, URLs via AX, retirement guards | W8/W9/W10 — **needs a `c1_ui_matrix.sh` `UI_CLASSES` row in the same change** |
| FleetUI unit tests | new: legal URL constants, `FleetTab.about` label/icon, `isPrimary == false` | W7/W9 |

## 8. SPEC amendment drafts (decision 5 — staged; external SPEC.md edits only on explicit go)

**§12 Settings and administration** — replace the opening sentence and table
with:

> Settings is a first-class tab (Build 43; formerly the Fleet root sheet).
> Its root carries quick value-pickers and chevron rows only: Theme
> (Appearance value-picker; curated accent picker per ADR-0009) and App
> settings (Security, Data & Storage) push sub-screens on the Settings tab's
> own stack. The agent setup prompt row remains always reachable on the root
> (C2). Version, legal, and support surfaces live in the About tab (ADR-0011),
> which also links the official Terms of Use and Privacy Policy hosted at
> hermes-fleet.aiowa.dev.

**§14 Visual system / identity decision** — amend the accent paragraph:

> The general accent picker retirement is superseded by ADR-0009/ADR-0011:
> Settings retains a curated ChatGPT-style accent picker (fixed curated set;
> arbitrary palette editing remains retired). Curated accents are validated
> against the invisible-pair guard in both appearances; the mono White accent
> resolves per-appearance.

## 9. Validation plan

1. Focused: new `FleetAboutUITests` + updated U7/H1 on a fresh dedicated sim
   (`QASettingsAbout`, iPhone 17/18 Pro per availability), own derived data,
   `-skipMacroValidation`, full class names with `UITests` suffix.
2. Regression suites touching the shell: FOS3, B43, U3, C2, accent suite.
3. Full `HermesFleetAppUnitTests` bundle + FleetUI/FleetCore package tests
   (net scripted per the QA-net pattern; per-suite `Executed N` receipts).
4. Link receipts: every relative link in this doc + ADR resolves; `gitleaks
   protect --staged` clean at commit; `git status` shows exactly the intended
   file set.
5. Manual dogfood evidence: Settings root + both sub-screens + About tab
   screenshots in both appearances (dark rendered first, then light).

## 10. Out of scope

- Custom EULA upload to ASC (Apple Standard EULA applies — decision 2).
- Notifications/Voice/etc. settings rows (SPEC §12 forbids uninvented
  switches; none implemented).
- Publishing/hosting bring-up for `hermes-fleet.aiowa.dev` (coordinated
  separately; content staged in-repo here).
- ASC `privacyPolicyUrl` write (release-time, explicit go).
- Pushing the lane, PR, or any TestFlight build (word-for-word instruction
  only, per standing rules).

## 11. Open content fill-ins (needed before SITE PUBLISH, not before implementation)

1. Governing law / venue line for `TERMS.md` (AIowa LLC's state of formation —
   Tony to confirm; draft leaves a marked placeholder).
2. Public contact email for legal/privacy requests (draft uses the support
   issue tracker as today; an email can be added when the domain has mail).
3. Effective dates on both documents (set at publish time).
