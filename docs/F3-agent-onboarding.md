# F3 — Agent-Assisted Onboarding (copyable bootstrap prompt)

Brand-new users with no gateway configured bootstrap their first connection
through their own Hermes agent: one tap copies a curated mission prompt, the
user pastes it into their Hermes chat (Telegram etc.), the agent executes the
mission, and the user enters the returned URL / username / password into the
existing Add-Gateway flow.

## Scope

- Empty-state CTA "Set up with your agent" on the Gateways tab when the
  registry is empty (`GatewaysView.emptyState`).
- `GatewayOnboardingView` — onboarding sheet: big copy button with visible
  bounded confirmation, collapsible full-prompt preview (selectable text),
  how-it-works steps, docs link (cyan link token), and an Add-Gateway
  hand-off that routes into the SAME sheet the toolbar plus presents.
- `OnboardingPrompt` (FleetUI) — the versioned prompt artifact.

Out of scope: QR-scan credential entry (F2 — referenced in step text only),
any gateway- or agent-side change (the prompt drives the user's existing
agent).

## The prompt (versioned WITH the app)

`OnboardingPrompt.version = 1`; the text lives in
`Packages/FleetUI/Sources/FleetUI/OnboardingPrompt.swift` and is pinned by
`OnboardingPromptTests` (shape, not prose). Bump the version whenever the
mission changes — e.g. TestFlight → App Store install path (today the prompt
names TestFlight + app id 6807148674), or QR pairing becoming preferred over
manual entry.

The mission covers the full first-run install (scope expansion, card
comment 2026-08-31):

1. APP INSTALL — confirm TestFlight tester enrollment (app 6807148674),
   send the invite link if missing.
2. NETWORK PATH — Tailscale preferred (tailnet + phone on it + endpoint
   answers), LAN fallback (same Wi-Fi, gateway bound to LAN IP) with the
   cleartext warning when plain http is the path.
3. GATEWAY SURFACE — endpoint reachable from the phone (bound correctly).
4. CREDENTIALS — scoped app credential, zero-print hygiene: values only in
   a 0600 file or the reply, never logs.
5. REPLY — exactly URL, username, password, plus a one-line install
   instruction.
6. VERIFY — the agent confirms the endpoint answers an auth request from
   the network path the phone will use.

### Safety properties (test-enforced)

- No secrets or endpoints embedded — `OnboardingPromptTests` fails the
  build on `http://`/`https://`, tailnet (100.100.x), RFC1918/loopback
  literals, `password:`/`token:` shapes, and per-user identifiers.
- Parameterized ("my phone", "the tailnet") — works for a user whose agent
  runs on ANY Hermes box, not just one specific setup.
- Concise: ≤ 200 words (currently ~160; `wordCount` asserted).

## UI-test reachability

`HERMES_FLEET_ZERO_GATEWAYS=1` (DEBUG simulator, `FleetServiceGraph`
zeroGatewaysEnabled) suppresses the scripted seed fleet so cold launch has
an EMPTY registry — the brand-new-user state is deterministic.

## Evidence

- `HermesFleetAppTests/OnboardingPromptTests` — 11 hosted tests: every
  mission leg, Tailscale-before-LAN ordering, hygiene, conciseness,
  versioning, view-init, docs URL.
- `HermesFleetAppUITests/F3OnboardingUITests` — 2 deterministic UI tests
  (CI-safe): CTA → copy → confirmation → prompt preview → docs link; and
  hand-off → real Add-Gateway form with paste affordances.
- `scripts/c1_ci_validate.sh` — F3 suite added to the deterministic UI
  selectors; full gate run per card rules.

## Open item

Prompt wording drafted by apple-dev per the card's mission spec; the review
with the `apple` profile could not run in the kanban worker session (no
usable deepseek credentials in this environment — `hermes chat` as apple
exits with "No usable credentials"). The review is routed as a follow-up
card; wording fixes are copy-only and covered by the shape tests.
