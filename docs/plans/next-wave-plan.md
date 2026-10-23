# Hermes Fleet — Next Wave Plan ("Pocket Command")

> **Status: PROPOSED.** This is a planning document, not a description of
> implemented behavior or release status. Current behavior is defined by source,
> [`../features.md`](../features.md), and accepted ADRs. Items move out of this
> plan into ADRs/feature docs as they are approved and land.

Prepared 2026-09-30 from six parallel audits of the current `main` (481dd41):
upstream Hermes capability gaps, security, visual design/UI, UX/IA, iOS platform
integration, and architecture/reliability. Claims marked **✔ verified** were
re-checked in source by the orchestrator; the rest are audit findings to confirm
at the start of the relevant work item.

---

## North star

> **Your agents can reach you, and you can act in under five seconds — safely,
> from anywhere — without anyone but you and your gateways seeing the content.**

Fleet already has the hardest-to-copy things: honest coverage semantics,
source-qualified multi-gateway identity, fail-closed routing, replay, Bot Mode,
Groups/RoomLink, Live Ops. What it lacks is **reach** (nothing happens when the
app is in your pocket), **native feel** (hand-rolled shell, no Liquid Glass),
and **depth on the controls a phone user actually needs** (undo, cost, search,
diffs). This wave fixes those, on top of a foundation that stops fighting us.

### Success metrics

| Metric | Today | Target |
|---|---|---|
| Approval: event → decision, phone locked in pocket | ∞ (foreground only) | < 10 s median |
| Approval: in-app, from any screen | 3–5 taps (open the right chat) | 1 swipe + Face ID |
| Fire off a task to your usual bot | 4–6 taps | 2 taps / 1 Siri phrase |
| Authenticated WebSockets per gateway | up to 12 (**✔ verified**: 12 `GatewayWebSocketTransport(` sites) | 1 |
| Cold launch → cached content painted | unmeasured | measured, < 400 ms p50 |
| First-run → first message (no Hermes yet) | dead end | < 60 s via demo fleet |
| FleetUI logic tests runnable with `swift test` | 0 | majority of VM tests |

---

## Phase 0 — Compatibility & trust hotfix (start immediately, ~1 week)

### P0.1 Server→client JSON-RPC requests (**release blocker**) ✔ verified

Upstream `hermes-agent` commit `9f7f2f28c0` (on `upstream/main`, 2026-09-14,
**not yet in a tagged release** — latest tag `v2026.9.11`) replaced the
`approval.request` / `*.respond` event pairs with **server→client JSON-RPC
requests**. The gateway only sends them to WebSocket clients that advertised
`client.capabilities {server_requests: true}`; when the only attached client
never advertised, it **withdraws the approval** ("update the Hermes app")
(`tui_gateway/server.py` `_emit_approval_request`,
`tui_gateway/session_transports.py` `_session_client_answers_requests`).

Fleet never sends `client.capabilities` and drops inbound requests
(`GatewayWebSocketTransport.swift` — `case .request: break`). Against a gateway
built from current upstream main, **in-conversation approvals will silently
stop working** and `clarify`, `sudo`, `secret` prompts were never handled.

Scope:
- Advertise `client.capabilities {server_requests: true}` after auth on the
  conversation transport (and the coordinator, once P1.3 lands).
- Route inbound `.request` frames: `approval`, `clarify`, `sudo`, `secret`;
  respond with result or JSON-RPC error; honor `request.cancel` (withdrawal ≠
  deny — dismiss UI, never record as a denial).
- Read `open_requests` from `session.resume` / `session.events.since` so a
  reconnect re-surfaces pending prompts.
- Keep the legacy `approval.request` event path for older gateways; select by
  observed behavior/version, never both at once.
- `secret`/`sudo` answers: Face ID gated, never cached, never logged, never in
  transcript cache; field uses `.privacySensitive()` and a secure text entry.
- Synthetic fixtures derived from the upstream OpenRPC contract
  (`apps/shared/src/gateway-contract.openrpc.json`); add a compatibility-matrix
  row per [`../upstream-compatibility.md`](../upstream-compatibility.md).

### P0.2 Approval integrity (security High) ✔ verified

The approval banner truncates the command to 4 lines with **middle** truncation
(`ApprovalBanner.swift:44-45`) and shows no gateway, bot, or cwd. A long
injected command can hide `curl … | sh` in the elided middle.

- Approval card header: **gateway label · bot · cwd · session**.
- Commands over N lines → mandatory "Review full command" sheet (scrollable,
  selectable, monospaced, wrap toggle); Approve is disabled until reviewed.
- Gateway-supplied `detail` rendered as clearly-labelled untrusted text.
- Biometric gate: fall back to device passcode (`.deviceOwnerAuthentication`)
  when biometrics are unavailable/locked out (today approval becomes impossible).
- Require Face ID for **YOLO**, **Always**, and **turning App Lock off**.

### P0.3 Data-at-rest & privacy fixes ✔ partially verified

- **Privacy shield on `.inactive`** so the app-switcher snapshot never captures
  a transcript (`AppLockController.handleScenePhase` locks on `.background`
  only — ✔ verified).
- **Purge cached transcripts on gateway removal** (`removeGateway` prunes
  launch cache/continue/artifacts but not `CachedMessageRow` — ✔ verified);
  aligns behavior with `PRIVACY.md`.
- File protection on SQLite `-wal`/`-shm` sidecars and the store directory;
  protection + backup exclusion for `BridgedRooms` and artifact tmp files.
- First-launch Keychain purge (items survive app deletion; `PRIVACY.md` implies
  otherwise).
- Ignore `HERMES_FLEET_APP_LOCK` env override in Release builds.
- OSLog: gateway hostnames `privacy: .private`.

### P0.4 Small UX hotfixes

- **Persist 1:1 composer drafts** per session (✔ verified: `@State composerText`;
  Groups already has `RoomDraftStore`).
- SwiftData `SchemaV1` snapshot + migration plan; replace the
  `try! makeInMemory()` fallback (`FleetServiceGraph.swift:834`, ✔ verified)
  with delete-and-rebuild + diagnostics record.
- Issue #62: correct tunnel/CGNAT/ULA warning copy (no safety claim from
  address range alone).

---

## Phase 1 — Foundation (2–4 weeks, parallel lanes)

Nothing in Phases 2–4 is cheap until these land. Sequence: F0 → F1 → F2 → F3,
velocity items in parallel from day one.

| # | Item | Why |
|---|---|---|
| F0 | `OSSignposter` intervals (launch→paint, connect, replay, open transcript), MetricKit, redacted diagnostics export | Stop guessing; "instant launch" is currently unmeasured |
| F1 | **Land ADR 0002**: hold+watermark snapshot in one actor turn; strict `ReplayBatch.validate(sessionID:)` (session match, unique monotonic seq, coherent `latest_seq`/`count`); collapse duplicate decode path | Replay today silently drops malformed events (`compactMap`) |
| F2 | **Land ADR 0001**: `GatewaySessionCoordinator` actor — one transport per gateway, multiplexed RPC + event fan-out, typed facets; `GatewayCoordinatorRegistry`; migrate seam-by-seam behind a flag | 12 sockets → 1: battery, rate limits, one client identity (unblocks #55 analysis), one place to advertise capabilities |
| F2b | `NWPathMonitor` + jittered backoff + scenePhase-aware ping suspension, owned by the coordinator | Wi-Fi↔cellular recovery waits for a 30 s poll today |
| F3 | **Extension kit**: `FleetClientKit` (extension-safe one-shot HTTPS/RPC, no UIKit/AppEnvironment), App Group container, shared Keychain access group (push key only — **never** move gateway tokens), entitlements file in `project.yml`, extension snapshot store (`CompleteUntilFirstUserAuthentication`) | Prerequisite for NSE, widgets, Live Activity, Share, Controls |
| F4 | Split `AppEnvironment` (2,983 lines) → `GatewayLifecycle`, `RosterStore`, `ConversationSessionStore`, `NavigationStore`; split `ConversationViewModel` (3,114) → transcript store / stream reducer / composer / voice | Main merge-conflict hotspot; required for multi-window iPad |

**Engineering velocity (parallel):**
- Move view models to a host-buildable `FleetUIModel` target → `swift test`
  instead of simulator builds (FleetUI has 0 package tests today).
- Pin CI runner + Xcode; cache SPM/DerivedData (Xcode drift broke a release in #67).
- Archive ~110 one-off milestone scripts and root `m10/m11_validate.sh`; move
  historical milestone docs to `docs/archive/`; fix ADR number collisions
  (two `0003-*`, duplicate last-event-id ADRs).
- Per-worktree named simulators in `dev-check` so parallel lanes stop colliding.
- Concurrency budget: replace lock boxes with `Synchronization.Mutex`; CI grep
  budget for `@unchecked Sendable` (46) and `nonisolated(unsafe)` (20); explicit
  `swiftSettings` per package.

---

## Phase 2 — Reach: your agents can find you (3–5 weeks)

### Push architecture (decided: AIowa free relay + self-host — see Maintainer decisions #1)

Upstream has **no APNs/FCM/Web Push**. APNs for an App Store bundle ID requires
the developer's `.p8` key, so "each gateway talks to APNs with its own key" is
impossible for App Store builds. Recommended hybrid:

1. **Blind push relay** (open source, self-hostable; AIowa-hosted default). It
   holds only the APNs key and forwards opaque ciphertext. Stores no content,
   no gateway credentials. Users can point app + gateway at their own relay.
2. **Gateway sender** ships as a module of the existing `hermes-liveops`
   plugin (same signed-bundle + scanner installer pattern). Hooks `approval`,
   `clarify`, `agent:end`, cron completion.
3. **Registration**: per-gateway, per-device X25519 key (push key in the shared
   Keychain group, `AfterFirstUnlockThisDeviceOnly`), device token + relay URL +
   public key registered with the gateway plugin.
4. **Payload**: generic visible alert ("Approval needed"), `mutable-content`,
   HPKE-sealed `{gateway, session, request_id, redacted preview, expiry,
   single-use response token}`. The **Notification Service Extension** decrypts
   and rewrites the body. Relay compromise leaks timing/metadata only and
   cannot forge approvals.
5. **Fallbacks**: foreground WebSocket (always authoritative on open),
   ntfy delivery via existing upstream platform for self-hosters, BG refresh
   as best-effort only. A notification is never treated as authoritative state.

### Surfaces

| Surface | UX | Notes |
|---|---|---|
| **Actionable approval notification** | "researcher · mac-studio needs approval" → long-press shows redacted command → **Approve once** (`.authenticationRequired` + Face ID) / **Deny** / Open | High-risk classes (network+exec, destructive) force "Open" instead of inline approve |
| **Live Activity + Dynamic Island** | Bot avatar + live tool step ("terminal · pytest · 42 s"), approvals-waiting chip with `LiveActivityIntent` buttons | Content-state is small non-sensitive enums; names resolved from App Group. Push-to-start/update tokens via relay |
| **Widgets** (Home + Lock Screen) | "3 running · 1 needs you · all online"; per-bot heartbeat rings | Redacted when App Lock is on |
| **Controls** (Control Center / Action button) | Open Inbox, Dictate to default bot, Pause all (if gateway supports) | Auth-required intents |
| **Interim (Phase 1 exit)** | Local notifications from the foreground stream + background task grace window | Ships value before the relay exists |

New targets (`project.yml`): `HermesFleetNSE`, `HermesFleetWidgets`
(widgets + Live Activity + controls), later `HermesFleetShare`; shared
`FleetIntents` module. Extensions link FleetCore + FleetSecurity +
FleetClientKit only; extend `ModuleBoundaryTests` to enforce it.

---

## Phase 3 — Native feel: Design Language 2.0 "Quiet instrument, alive"

**Principle:** content stays calm and opaque; chrome floats as glass; every
motion reports a *real* wire state (consistent with the capability-honesty
rule — nothing indeterminate pretends to be determinate).

### 3.1 Information architecture (decided: keep the drawer — see Maintainer decisions #2)

> The tab-bar proposal below is **rejected** and retained only for context. The
> accepted direction: keep the drawer; add an Inbox destination, a global New
> action, reachability improvements, and the live strip as a floating glass
> element rather than a tab-bar accessory.

On iPhone, compact width today has **no tab bar**: a hand-rolled ZStack of
`NavigationStack`s behind a hamburger with eight peer destinations.

Proposed iOS 26 native `TabView`:

```
[ Inbox ]  [ Chats ]  [ Fleet ]  [ Bots ]            (🔍 Search role)
 Needs You  1:1 + Groups  Active/Live Ops  Roster      Command Center:
 approvals  (segmented)   Continue         Bot detail  bots, chats (server
 clarify    Pinned        Gateways         Routines    search), resources,
 auth fails Recents       Scheduled·Kanban             and actions
 replies                  Artifacts
                          ⚙︎ Settings/About → profile button on each root
```

- `.tabBarMinimizeBehavior(.onScrollDown)`; **`.tabViewBottomAccessory` "live
  strip"** — running agents across all tabs (avatar stack, count, elapsed);
  tap morphs into Live Ops.
- Inbox tab badge = pending approvals + clarifies; swipe-to-approve/deny inline.
- Global **New** (compose sheet with last-used bot preselected).
- Navigation-state migration uses the ADR-0010 decode-time precedent.
- iPad: `sidebarAdaptable` with `TabSection`s; `NavigationSplitView` for Chats
  and Bots with an inspector column; readable max width (~720 pt) for transcripts.

### 3.2 Liquid Glass adoption

Zero uses of `glassEffect` / `GlassEffectContainer` today; ADR-0008 rejected
glass because it broke XCUITest hit-testing. **Re-measure on the current
toolchain first**; if it persists, use `accessibilityRepresentation` or a
test-only fallback rather than dropping glass. Targets: composer pill, toolbelt
chips (one container, `glassEffectID` morphs), "Latest" button, approval card,
bottom accessory. Supersede ADR-0008 with a new ADR.

### 3.3 Conversation craft

- **Typed tool rows**: terminal / file / web / memory / code / delegate glyphs
  and tints; `symbolEffect` while in flight; one-line result summary.
- **Code blocks**: language label, Copy (+ success haptic), horizontal scroll
  with fade edges; verify light/dark syntax theme parity.
- **Diff view**: unified diff with gutters and collapsed hunks — reused by
  checkpoints (4.2) and file review (4.5).
- **Inspect output**: search, wrap toggle, line numbers.
- **Streaming presence**: replace `WorkingDots` (ignores Reduce Motion) with a
  reduce-motion-aware presence glyph, soft caret, first-token haptic, settle on
  turn end. Thinking placeholder before first token.
- **Zoom transitions**: avatar → Bot Detail → Conversation
  (`matchedTransitionSource` + `.navigationTransition(.zoom)`).

### 3.4 System hygiene

- Replace 30 fixed `.font(.system(size:))` calls with text styles; add
  `@ScaledMetric` for glyph frames; lint script fails on new occurrences.
- `FleetSurface` variants (`.flat/.inset/.glass`) absorbing ad-hoc cards and the
  two duplicate tool-row chromes; radius tokens for the literal 10/12/14/15/32.
- `FleetHaptics` vocabulary: approval (warning), tool success/failure,
  connection change, refresh complete, slider detents.
- `FleetSkeleton` loading rows (static under Reduce Motion) instead of bare
  `ProgressView`.
- `FleetNoticeBar` severity hierarchy + inline recovery action.
- Remove stale "flat #16161A, no glass" / "magenta" doc comments; replace stale
  screenshots with a current, synthetic-fixture screenshot set.

### 3.5 Signature moment: Fleet Pulse

Fleet Home hero: one glass instrument per gateway, one node per bot. Working
bots breathe at a rate tied to real activity; attention nodes pull amber to the
edge; tap zooms into the bot. `TimelineView` + `Canvas` (reusing memory-graph
skills). Static labelled list under Reduce Motion / VoiceOver with a custom
rotor. Headline sentence first: "2 need you · 1 running · all online";
coverage caveats move behind an info button.

---

## Phase 4 — Depth: the controls a phone user needs (upstream capabilities)

Each item follows the upstream intake process (contract verified → fixtures →
UI; hide when capability absent).

| # | Feature | Upstream surface | Mobile UX |
|---|---|---|---|
| 4.1 | **Cost & quota** | `session.usage` (`cost_usd`, cache %, tokens/s, `account_lines`), `usage.bars`, `insights.get`, analytics | Cost chip in chat header; fleet spend & plan-limit bars on Fleet; 429 usage-limit card |
| 4.2 | **Checkpoints & undo** | `rollback.list/diff/restore`, `session.undo` | "Undo agent's last changes" with diff preview + Face ID |
| 4.3 | **Server session search** + delete/hide | `/api/sessions/search`, `session.delete`, `session.set_hidden` | Search tab finds any past chat; swipe delete/hide |
| 4.4 | **OAuth sign-in (#61)** | native RFC 8252 flow (`/auth/native/*`, PKCE, rotating refresh) | Blocked by loopback-only `redirect_uri`; propose upstream app-scheme redirect (Maintainer decisions #4 — non-blocking); bearer + `ws-ticket` path to verify |
| 4.5 | **File / diff / git review** (read-only first) | `/api/fs/*`, `/api/git/status/diff/review` | Review what the agent changed; commit/PR actions later behind Face ID |
| 4.6 | **Process tail & kill** | `agent.terminal.output`, `process.list/kill` | Live tail of a long build; kill a runaway job. No PTY |
| 4.7 | **Gateway health & doctor** | `/api/status`, `/api/logs`, `/api/system/stats`, `/api/ops/doctor` | "Why is my gateway sick" screen in Gateway Detail |
| 4.8 | **Provider & model management** | `/api/providers/oauth/*` (device-code), `model.save_key`, MCP servers | Re-auth an expired provider login without a computer |
| 4.9 | **Quick asks** | `prompt.btw`, `prompt.background`, `handoff.request` | "Side question" without derailing the turn; "Continue on Telegram" |
| 4.10 | **Subagent live events** | `subagent.*`, `spawn_tree.*`, `todo.updated` | Stream instead of poll in Operation Detail; agent todo list |

---

## Security program (runs across all phases)

Beyond the Phase 0 fixes:

1. **Pairing v2** — QR today carries a long-lived password with no expiry,
   nonce, or fingerprint (`PairingPayload.swift`, ✔ verified). Replace with a
   one-time, 2-minute, gateway-signed pairing code that includes the SPKI
   fingerprint, plus a 6-digit SAS confirmed on both screens. Requires upstream
   or liveops-plugin support.
2. **Fingerprint UX** — show full SPKI fingerprint at first pin and old-vs-new
   on mismatch; Face ID to re-pin; optional intermediate/CA pin mode with
   rotation overlap (leaf-only pinning breaks on Let's Encrypt key rotation and
   trains click-through); bind pin to hostname and still run system validation
   for expiry/host.
3. **Secure Enclave device key** — non-exportable per-device key; pair by
   challenge-signature; sign `{requestID, choice, nonce}` so the gateway can
   verify user presence on approvals (upstream proposal).
4. **Approval policy engine** — per gateway/bot rules: risk classifier chips
   (network, destructive, credential-touching, `tool.output_risk`), blocklist
   patterns, time-boxed "approve similar for 10 min" instead of persisted
   Always, provenance line ("requested after reading <url>").
5. **Local audit log** — append-only, hash-chained, file-protected record of
   approvals, YOLO, pin changes, removals; exportable.
6. **Panic switch** — one tap / Shortcut: disconnect all, wipe cache + tmp
   artifacts + cookies, optionally revoke tokens.
7. **Lock policy** — configurable auto-lock grace; optional strong mode wrapping
   Keychain items in `SecAccessControl(.biometryCurrentSet)`; hide-content in
   notifications/Shortcuts/widgets.
8. **Per-gateway posture score** — transport, auth type, credential age, pin age
   → shown in Gateway Detail; gates high-risk actions.
9. **Clipboard hygiene** — `expirationDate` + `localOnly` for copied IDs/cwd/
   reports; `PasteButton` for credential paste.
10. **Transport truth (#62)** — "encrypted tunnel" badge only when it can be
    established, never from address range; `?token=` loopback strategy reviewed.

---

## Phase 5 — Delight & ecosystem

- **App Intents**: "Ask <bot> …" (background, returns snippet), "What's
  running?", "Approve latest" (auth-required); `BotEntity` alongside the existing
  conversation entity.
- **Share extension** "Send to agent" (URL, text, image, file → bot picker).
- **Demo fleet** — clearly-labelled, local-only synthetic gateway built from
  existing fixtures: fixes first-run dead end, App Review, and screenshots.
- **Command Center as a command line** — ⌘K, actions ("New chat with…",
  "Approve", "Connect gateway"), `@bot do X` and `/approve` from anywhere.
- **Hardware keyboard map** — ⌘K, ⌘N, ⌘1–4, ⌘↵ send, ⌘. stop, ⌘F find in chat.
- **Spotlight + Handoff** (titles only, never when App Lock is on).
- **Apple Watch** approvals via mirrored actionable notifications (free once
  Phase 2 lands); native watch app later.
- **Offline outbox** — queue prompts while disconnected; "Queued · sends on
  reconnect", retry/cancel.
- **On-device Foundation Models** — summarize long agent output / draft a reply
  without data leaving the phone (Apple Intelligence hardware only).
- **Focus filter** — mute a bot's notifications in a Focus.

---

## Parallel lanes & ownership

Per [`../DEVELOPMENT.md`](../DEVELOPMENT.md#parallel-agent-lanes): each lane is a
fresh worktree from `origin/main`; one CI/release integrator owns `project.yml`,
package counts, UI test registration, and CI topology.

| Lane | Phase 0 | Phase 1 | Phase 2+ |
|---|---|---|---|
| **A · Protocol** | P0.1 server requests | F1 replay, F2 coordinator, F2b NWPath | 4.1–4.10 contracts & fixtures |
| **B · Security** | P0.2, P0.3 | Keychain access group design (F3) | Push crypto, pairing v2, policy engine, audit log |
| **C · Design/UI** | P0.4 drafts | 3.4 hygiene, glass re-measure (ADR) | 3.1 IA, 3.2 glass, 3.3 craft, 3.5 Pulse |
| **D · Platform** | — | F3 extension kit, entitlements | NSE, widgets, Live Activity, intents |
| **E · Velocity/CI (integrator)** | schema V1 | F0 signposts, host-testable UI, CI pin, pruning | New targets in CI, iPad coverage |
| **F · Server-side** | — | Relay prototype | liveops push sender, upstream proposals |

Shared-file hot spots (`AppEnvironment.swift`, `FleetServiceGraph.swift`,
`ConversationView.swift`, `project.yml`) are serialized through the integrator
until F4 splits them.

---

## Maintainer decisions (2026-09-30)

1. **Push relay — AIowa free relay + self-host.** APNs for the App Store bundle
   ID requires AIowa's team key, so App Store users need an AIowa-operated
   relay. It is built content-blind and deployable on a free tier (e.g.
   Cloudflare Workers); a self-host path serves self-built copies. Deployment,
   Apple keys, and accounts are maintainer-only steps. `PRIVACY.md` must state
   the relay's role plainly.
2. **Navigation — keep the drawer.** The hamburger drawer stays the primary
   iPhone navigation. Section 3.1 is re-scoped: no tab-bar migration; instead
   improve drawer reachability, add an Inbox (Needs You) destination with a
   badge, a global New action, and a live running-agents strip.
3. **Liquid Glass — yes, tastefully.** Glass only for floating chrome where it
   aids hierarchy (composer, toolbelt chips, approval card, live strip,
   drawer chrome). Content surfaces stay opaque. A new ADR supersedes the
   relevant part of ADR-0008 once hit-testing is re-measured.
4. **Upstream contributions — yes, never blocking.** Upstream proposals are
   filed in parallel, but every Fleet item must ship value without them
   (e.g. liveops-plugin implementations, client-side fallbacks).
5. **Minimum gateway version** — keep the legacy `approval.request` path until
   a deliberate floor is chosen (not yet decided).
6. **Demo fleet** — not yet decided; keep as a proposal.

## Recommended first two weeks

1. **P0.1 server-request support** — highest priority; verify first against a
   gateway built from current upstream `main`, then implement with contract
   fixtures.
2. P0.2 + P0.3 security fixes (small, independent PRs).
3. P0.4 drafts + SchemaV1.
4. F0 signposts/MetricKit and CI pinning (integrator lane).
5. Decisions 1–3 above, so Phase 2/3 design can start while F1/F2 land.
