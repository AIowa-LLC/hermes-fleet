# Instant Fleet: cached-first launch + seamlessness pass

Status: **Approved for spec 2026-09-19** — Tony: "write the spec that provides
the BEST user experience possible." Research pass complete (Fleet cold-start
trace + ChatGPT pattern + Hermex open-source study at `/tmp/hermex-study`,
commit on file). Implementation awaits a separate explicit go.

Related: ADR-0012 (this pass), SPEC §7/§10/§17 (freshness, Chats, observation
cadence), FOS-4/FOS-5 (truthful home, outage retention), M10 (persistence),
P0-4 (durable registry).

## 0. The problem, with evidence

Three dogfood symptoms, one root cause each:

1. **"When I start the app I still had to reconnect the gateways."**
   Cold launch runs `hydrateIfNeeded() → load() → refreshRoster() →
   restoreIntendedConnections()` (HermesFleetApp.swift:29-35). The registry,
   credentials, and connection INTENT persist — but `rosterSnapshot` starts
   `nil` (AppEnvironment:169), `cachedBotsByGateway` is memory-only (:290),
   and `sessionsByRoute` likewise. **No list-shaped state survives process
   death.** The Bots tab renders empty until a full network wave completes;
   the auto-refresh exists (FleetRosterView:205) but is slow enough to feel
   manual. New-build installs feel worse because the container swap also
   loses any warm ephemera; force-close/relaunch keeps warm network paths —
   matching Tony's "not AS bad" observation.
2. **"I had to hit the refresh button to get bots to show up."** Same cause:
   first paint waits on the roster wave; the button was the fastest way to
   re-arm it.
3. **"Chats shows an updating spinner for a second or two."**
   `loadingRoutes` non-empty → "Updating…" row (FleetDestinations:235) while
   session lists re-read per visit (30s TTL, memory-only).

Secondary finding (research): **dual connection machinery** — the roster wave
mints ephemeral sessions per refresh (FleetRosterService.swift:59-94) while
`restoreIntendedConnections()` separately dials tracked connections. Every
cold start pays TWO handshakes per gateway, sharing one rate-limit bucket
(the b12 lesson).

## 1. Research synthesis (what "always visible" means)

| Principle | ChatGPT | Hermex (source-verified) | Fleet today |
|---|---|---|---|
| List source of truth | local DB, stale-while-revalidate | network-first + cache FALLBACK | network only |
| Chat content | local DB | cache-first by id, 7d TTL | transcripts cached ✓ |
| Stale honesty | subtle indicator | `isViewingCachedData` dims controls to 0.45 | FOS-5 outage markers ✓ |
| Transport | persistent socket + push | HTTP + SSE per use | dual WS machinery |
| Storage hygiene | tiered LRU | TTL + eviction + 5k msg cap | watermark/replay only |

Hermex specifics adopted below: `CachedSession` SwiftData `@Model` with
`cacheKey = server|session|id`; `CacheFallbackPolicy` gating cache use to
connectivity errors + 408/502/503/504 (NEVER auth — matches our M11);
visible-not-silent stale state; maintenance pass on every cache write.

## 2. Design: the Fleet Instant Launch contract

**Principle: the app opens showing the last fleet you saw, then silently
makes it true.** Cached-first render, background revalidate, honest stale
markers — never a blocking spinner when local truth exists.

### 2.1 New persistence: `FleetLaunchCache` (FleetCore DTOs + FleetPersistence store)

Codability facts (verified): `SessionSummary` and `Route` are `Codable`;
`FleetBot`/`FleetGateway`/`FleetRosterSnapshot` are NOT. Therefore the cache
layer defines its own DTOs (the Hermex `CachedSession` precedent — a stable
wire-format decoupled from live model evolution):

```swift
// FleetCore
public struct CachedFleetBot: Codable, Sendable, Equatable {
    public let route: Route            // Codable ✓
    public let displayName: String
    public let modelSummary: String?
    public let activity: BotActivity   // Codable ✓
    public let presence: BotPresence   // Codable ✓
    public let avatarKey: String?
    public let cachedAt: Date
}
public struct CachedGatewayRoster: Codable, Sendable, Equatable {
    public let gateway: CachedGatewaySummary   // id, displayName, endpoint host (non-secret), cachedAt
    public let bots: [CachedFleetBot]
}
public struct CachedSessionList: Codable, Sendable, Equatable {
    public let route: Route
    public let sessions: [SessionSummary]      // Codable ✓ (lastActive powers unread dots)
    public let cachedAt: Date
}
```

Mapping functions `FleetBot → CachedFleetBot` and back (display fields only;
the live model stays the runtime source of truth). Ghost rendering works from
the DTO exactly as it does from `cachedBotsByGateway` today.

**Store** (FleetPersistence, alongside SwiftDataCacheStore): three APIs —

| API | Writes | Reads |
|---|---|---|
| `saveRosterCache(_:[CachedGatewayRoster])` | after every settled `refreshRoster` (success per gateway) | at `load()` |
| `saveSessionLists(_:[CachedSessionList])` | after every successful per-route session read | at `load()` |
| `clearLaunchCache()` | cache-clear flow (Data & Storage) + gateway removal | — |

**TTL: 7 days** (Hermex parity), enforced at read (`cachedAt` check) — expired
entries are discarded, so a week-old fleet never ghosts in. Maintenance on
write prunes entries for gateways no longer in the registry (no orphans).

Secrets boundary (non-negotiable): the cache stores NO credentials, tokens,
or auth material — display fields, Route identity, and session summaries
only. Existing `SwiftDataCacheStore` backup-exclusion posture carries over.

### 2.2 Launch sequence (AppEnvironment)

```
load() today:  registry restore → seed check → reloadGateways → pins → settle
load() new:    registry restore → seed check → reloadGateways
                 → read launch cache → hydrate observables:
                     rosterSnapshot = cached(roster)         [renders INSTANTLY]
                     cachedBotsByGateway = cached(bots)
                     sessionsByRoute = cached(lists)          [dots light instantly]
                     isViewingCachedFleet = true
                 → pins → settle
then (unchanged, now background-relative to painted UI):
             refreshRoster() → on success REPLACES observables + writes cache
                               isViewingCachedFleet = false
```

Key semantics:

- **`isViewingCachedFleet`** (new observable, name per Hermex's
  `isViewingCachedData`): true from cache-hydration until the first
  successful live refresh settles. The existing FOS-5 outage markers keep
  their meaning; this flag is the *temporal* stale signal (launch freshness),
  not an outage signal.
- **Write-through only on success**: a gateway that fails its live refresh
  KEEPS its cached bots (FOS-5 ghost semantics — same as today's memory
  cache); a gateway that succeeds updates its cache entry. A successful
  refresh reporting zero bots clears that gateway's entry (empty-is-
  authoritative, the existing rule).
- **Unread dots light from cache**: `sessionsByRoute` hydrated from
  `CachedSessionList` means r4's dots render on first paint. Watermarks
  persist already (r4), so a session unread at last use stays dotted.

### 2.3 UI changes (minimal, honest)

| Surface | Today | New |
|---|---|---|
| Bots (roster) | empty → spinner-equivalent until wave settles | cached rows instantly; small "Updating…" pill while `isRefreshing && isViewingCachedFleet`; per-gateway outage markers unchanged |
| Chats | "Updating…" row while routes load | cached rows instantly (TTL'd); same subtle updating affordance; NEVER a bare spinner over existing content |
| Fleet dashboard | cards wait on roster | cached summary cards + updating pill |
| Drawer recents | `sessionsByRoute`-driven (empty cold) | populated from cache on cold open |

The "Updating…" treatment follows the existing Chats background-refresh row
(FleetDestinations:243-253) — a compact inline indicator, not blocking chrome.

### 2.4 Connection seamlessness (bounded scope this pass)

1. **Overlap the launch waves** (G4): in `hydrateIfNeeded()`, run
   `restoreIntendedConnections()` CONCURRENTLY with `refreshRoster()` (they
   are independent — registry gates both, not each other). Removes serial
   latency from the cold path.
2. **Post-connect roster sync already exists**
   (`scheduleRosterSyncAfterConnectionRepair`) — keep as-is.
3. **G3 (single connection machinery) is EXPLICITLY OUT OF SCOPE** this pass
   — it redesigns FleetNetworking's session lifecycle and deserves its own
   ADR. The dual-dial cost remains but is paid in parallel (item 1) and
   behind painted UI (2.2), so it no longer blocks first paint.

### 2.5 Honesty rules (carried from FOS-4/5 + Hermex policy)

- Cached render NEVER fabricates connectivity: connection badges read live
  `connectionStates` (idle/disconnected until tracked connections land).
- `isViewingCachedFleet` dims destructive/mutating actions the way Hermex
  dims at 0.45 (we will NOT disable navigation — reading cached content must
  stay fully usable; only gateway-mutating actions like bot edits dim).
- Auth failures never substitute cache silently — the existing
  `.authenticationRequired` surfaces win (M11 contract preserved).

## 3. Work items

| # | Item | Files (primary) | Acceptance |
|---|---|---|---|
| W1 | `CachedFleetBot`/`CachedGatewayRoster`/`CachedSessionList` DTOs + mapping | FleetCore (new `FleetLaunchCacheModels.swift`) | unit: round-trip FleetBot↔DTO; FleetCore tests |
| W2 | Store APIs + TTL + maintenance | FleetPersistence (`FleetLaunchCacheStore.swift`) | unit: write/read/expiry/prune-orphans |
| W3 | `load()` hydrates observables from cache; `isViewingCachedFleet` | AppEnvironment | unit: load-with-cache sets snapshot+flag; nil-cache unchanged |
| W4 | Write-through on settled refresh + session reads | AppEnvironment (refreshRoster settlement, session-list read path) | unit: success writes; failure preserves; zero-bots clears |
| W5 | Bots/Chats/Fleet/Drawer cached-first render + Updating pill | FleetRosterView, FleetDestinations, FleetDashboardView, FleetNavigationDrawer | UI: cached rows render pre-network (deterministic: seeded cache fixture, airplane-ish blocked scripted gateway) |
| W6 | Launch-wave overlap | HermesFleetApp / AppEnvironment `hydrateIfNeeded` | unit: restore + refresh interleave (both complete; order-independent) |
| W7 | Cache-clear integration | FleetSettingsDataView flow + `clearLaunchCache` | unit: clear empties store; UI: Data & Storage clears and re-renders empty |
| W8 | Tests: new `FleetLaunchCacheUITests` (cold-launch cached render, updating pill, dot-from-cache, clear) + hosted units | HermesFleetAppUITests (c1 row), HermesFleetAppTests | suites green; `c1_ui_matrix.sh` row in same change |
| W8b | NAV_RESET hygiene: launch cache reset hook (hermetic suites) | AppEnvironment/FleetTabView reset block | two consecutive runs green on one sim (leak-proof) |
| W9 | ADR-0012 + README index + this spec linked | docs/adr | filed, indexed |

## 4. Test strategy

Hosted units (W1-W4, W6-W8b): pure seam tests against scripted stores — no
network. UI (W5, W8): deterministic scripted fleet + a NEW simulator knob
`HERMES_FLEET_LAUNCH_CACHE_FIXTURE` (DEBUG-only) that pre-seeds the launch
cache with known rows, plus the existing unreachable-`arch` scripted gateway
to prove the cached/failed hybrid render. Regression suites: FOS3/FOS4
(truthful home reads roster), FOS5 (outage retention — the ghost path now has
a persisted twin), FleetUnreadBadge (dots from cache), Chats suites, H1.
Full units + the full net per the standard loop.

## 5. Out of scope

- G3 single-connection-machinery redesign (own ADR; partially mitigated by W6)
- Push notifications for session updates
- Ranking/list-order changes (startedAt ordering stays; lastActive ranking is
  a separate product decision)
- The purple refresh/dots sighting on build 59 (needs its own investigation —
  possibly Menu-label ink failing differently than button ink; separate pass)

## 6. Risks

| Risk | Mitigation |
|---|---|
| Stale cache shows bots deleted server-side up to 7d | Same acceptability as today's in-memory ghosts (FOS-5 shipped this); TTL bounds it; refresh replaces within seconds of connectivity |
| Cache/db schema drift across app updates | DTOs are versioned wire-format; unknown fields decode-fail → discard cache (fail-open to today's behavior) |
| Unread dots light for sessions "unread" vs long-dead activity | Watermarks already persist (r4); dot = lastActive > watermark — a session stale for days still shows dot until opened once, matching ChatGPT semantics |
| Dual-write contention (refresh settles during cache hydrate) | Generation fence already exists (`rosterGeneration`); cache read happens strictly before first refresh arms |
| Bigger SwiftData store | Session lists are tiny (summaries, not transcripts); roster DTOs likewise; maintenance prunes |
