# ADR-0012: Cached-first instant launch (the Fleet launch cache)

- **Status:** Accepted (spec approved 2026-09-19; implementation pending)
- **Deciders:** Tony (owner), apple-dev
- **Related:** `docs/instant-fleet-launch-cache.md` (implementation spec),
  ADR-0011, FOS-4/FOS-5 (truthful home, outage retention), M10
  (persistence), P0-4 (durable registry), r4 unread dots

## Context

Dogfood repeatedly reports the cold launch as the least seamless moment:
gateways appear to need "reconnecting," the Bots tab renders empty until a
roster wave settles (feels manual-refresh-dependent), and Chats shows an
updating spinner on first visit. Traced root cause: **no list-shaped state
survives process death** — `rosterSnapshot`, `cachedBotsByGateway`, and
`sessionsByRoute` are all in-memory only, so first paint blocks on a full
network wave across every gateway. A secondary finding: the roster wave and
the tracked-connection restore run two parallel connection machineries,
serialized at launch.

Research (2026-09-19): ChatGPT is local-first (local DB is the UI's source of
truth, network revalidates in background). Hermex (open source,
`uzairansaruzi/hermex`, MIT) is network-first with a SwiftData
`CachedSession` fallback: 7-day TTL, `cacheKey = server|session|id`,
cache-substitution gated to connectivity/5xx errors (never auth), and a
visible `isViewingCachedData` stale state that dims mutating controls.

## Decision

1. **Cached-first launch.** Persist the last-good roster (per-gateway bot
   lists) and per-route session lists through a new FleetPersistence store
   (`FleetLaunchCacheStore`) using dedicated Codable DTOs
   (`CachedGatewayRoster`, `CachedSessionList`, `CachedFleetBot`) — decoupled
   from the non-Codable live models, following Hermex's `CachedSession`
   precedent. `load()` hydrates the observable state from this cache BEFORE
   any network work, so the app opens showing the last fleet you saw.
2. **Write-through on success only.** Every settled successful refresh and
   session-list read updates the cache; failures preserve entries (FOS-5
   ghost semantics, persisted); a successful zero-bot result clears that
   gateway's entry (empty-is-authoritative). TTL 7 days, orphan pruning on
   write, no credentials or auth material ever stored.
3. **Honest stale state.** `isViewingCachedFleet` is observable from cache
   hydration until the first successful live settlement; it dims
   gateway-mutating actions (navigation and reading stay fully enabled) and
   drives a compact Updating indicator. Live connection badges never render
   cached connectivity (idle/disconnected until tracked connections land);
   auth failures never silently substitute cache (M11 preserved).
4. **Overlap the launch waves.** `restoreIntendedConnections()` runs
   concurrently with `refreshRoster()` at hydration — independent work, no
   serialization.
5. **Unread dots render from cache.** Hydrated `sessionsByRoute` +
   persisted r4 watermarks = dots on first paint.

## Alternatives rejected

- **True stale-while-revalidate local DB as the sole source of truth
  (full ChatGPT architecture):** the right north star, but it restructures
  every read path around the store. The launch cache delivers the same
  first-paint experience at a fraction of the blast radius; the SWR refactor
  can follow incrementally.
- **Persisting the live models directly:** `FleetBot`/`FleetRosterSnapshot`
  are not Codable and evolve with the UI; coupling the cache to them makes
  every model change a migration. DTOs are the stable wire format.
- **Hermex's network-first + fallback-only cache:** leaves the cold-start
  spinner on the happy path — the exact symptom being fixed.
- **Fixing the dual connection machinery (G3) in this pass:** real win, but
  it redesigns FleetNetworking's session lifecycle; deferred to its own ADR.

## Consequences

- Cold launch paints Bots/Chats/Fleet/Drawer from cache instantly; network
  revalidation replaces content seconds later when reachable.
- Cache may show server-deleted bots up to the 7-day TTL on an unreachable
  gateway — the same acceptability FOS-5 shipped for in-memory ghosts, now
  bounded by TTL.
- The persisted-nav decode, registry restore, and launch cache form three
  launch-time reads; ordering (registry → cache → network) is pinned in the
  spec and unit-tested.
- Data & Storage's Delete Local Cache additionally clears the launch cache.
- UI-test hygiene gains a NAV_RESET hook for the cache (leak-proof suites).
