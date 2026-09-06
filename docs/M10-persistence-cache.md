# M10 Persistence / Cache

**Task:** t_09fa7e56 · **Owner:** apple-dev · **Board:** hermes-fleet-ios
**Status:** Implementation complete, evidence recorded. Handed to independent
review (apple-qa).

## 1. Scope (M10 only)

Per the authorized card (USER BATCH-AUTHORIZED M6–M15 at 2026-08-29;
SEQUENCER dispatch after M8/M9 FINAL PASS) + synthesis §12 (Persistence /
cache) + synthesis §11 (auth) + spec §31 Security: **Keychain token/ticket
store + SwiftData non-secret cache (history + seq watermarks +
replay_epoch); NSFileProtectionComplete; no tokens in cache.** Built on M9
commit `ec7808f` in repo the repository root.

Card scope line: *"Keychain token/ticket store + SwiftData non-secret cache
(history + seq watermarks + replay_epoch); NSFileProtectionComplete; no tokens
in cache. Acceptance: security/no-secret invariants; spec §31 Security +
synthesis §12."*

Deliverables:
- **`TokenStoring`** (FleetCore) — the M10 Keychain token/ticket seam
  protocol + `StoredToken` (redacted, non-Codable secret value) +
  `TokenStoreError` (no secret material in errors). Mirrors the M7
  `CredentialStoring` seam pattern so the service layer depends on the
  protocol, never on the concrete Keychain implementation. Tokens/tickets live
  ONLY in Keychain (spec §16, synthesis §11/§12).
- **`KeychainTokenStore`** (FleetSecurity) — concrete `TokenStoring`:
  GenericPassword, service `com.aiowa.hermesfleet.tokens`, account =
  peer gateway ID, accessibility `WhenUnlockedThisDeviceOnly`, no iCloud sync
  (synthesis §12). `baseAttributes` public for attribute assertions.
- **`InMemoryTokenStore`** (FleetSecurity) — test/preview double of the same
  contract.
- **`CacheStoring`** (FleetCore) — the M10 non-secret cache seam protocol +
  `CacheStoreError` (no secret material). Methods cover session history,
  per-(gateway, session) seq watermarks, per-gateway replay_epoch, and a
  fail-closed `resetForReplayEpochChange` (spec §9.6 / synthesis §12 "stale
  epoch → reset"). **Structurally no credentials: the protocol has no
  token/credential parameter and its models hold no secret field.**
- **`SwiftDataCacheStore`** (FleetPersistence) — concrete `CacheStoring`
  over SwiftData `@Model` entities (`CachedMessageRow`, `CachedWatermarkRow`,
  `CachedReplayEpochRow`), each carrying only non-secret transcript/watermark/
  epoch fields. File-backed factory applies NSFileProtectionComplete +
  backup-excluded to the store file (synthesis §12); in-memory factory for
  tests/previews. Host-runnable (macOS 14+ SwiftData) so package tests stay
  hermetic; the file-protection attributes are verified on the iOS simulator
  in the app-level boundary test.
- **`CacheStoreProtection`** (FleetPersistence) — applies/reads the on-disk
  protection attributes (NSFileProtectionComplete on iOS, backup-exclusion on
  all platforms) so a device backup never ships the privacy-bearing transcript
  cache.

Explicitly NOT in M10 (per BATCH AUTH + sequencer): auth hardening (M11),
gateway-registry on-disk persistence (registry stays in-memory per M2/M7 —
only the non-secret cache + Keychain token store land here), UI wiring (P6),
live Hermes gateway connection (tests use in-process fixtures + host SwiftData),
any privileged Hermes operations.

## 2. Files

### FleetCore (pure domain + seams)
| File | Responsibility |
|---|---|
| `TokenStoring.swift` | `TokenStoring` seam + `StoredToken` (redacted, non-Codable) + `TokenStoreError` |
| `CacheStoring.swift` | `CacheStoring` seam + `CacheStoreError` (non-secret cache of history/watermarks/epoch) |

### FleetSecurity (Keychain token store — the "no tokens in cache" half)
| File | Responsibility |
|---|---|
| `KeychainTokenStore.swift` | real Keychain `TokenStoring`: GenericPassword, per-peer account, WhenUnlockedThisDeviceOnly, no sync; `baseAttributes` public for attribute assertions |
| `InMemoryTokenStore.swift` | test/preview double of the same contract |

### FleetPersistence (SwiftData non-secret cache — the "cache" half)
| File | Responsibility |
|---|---|
| `CacheModels.swift` | SwiftData `@Model` entities: `CachedMessageRow`, `CachedWatermarkRow`, `CachedReplayEpochRow` — non-secret fields only |
| `SwiftDataCacheStore.swift` | `CacheStoring` actor over SwiftData; `makeInMemory()` / `makeFileBacked(storeURL:)` factories; `CacheStoreProtection` (NSFileProtectionComplete + backup-excluded) |
| `Package.swift` *(modified)* | added `FleetPersistenceTests` test target |

### Tests
- `FleetCoreTests/PersistenceDomainTests.swift` — 6 tests: `StoredToken`
  redaction (raw value never prints via `description`/`debugDescription`/
  interpolation), token equality, `TokenStoreError` / `CacheStoreError`
  vocabulary (no secret material), seam construction (Sendable-typed, no
  secret params).
- `FleetSecurityTests/FleetSecurityTokenTests.swift` — 10 tests: in-memory
  token store contract (save/load/delete, missing→nil, delete no-op, upsert,
  per-peer isolation, `[REDACTED]` description), and Keychain token store
  query construction (GenericPassword class, app-scoped token service,
  gateway-ID account, WhenUnlockedThisDeviceOnly accessibility, no sync,
  constructible) — hermetic (no live keychain in package tests).
- `FleetPersistenceTests/SwiftDataCacheStoreTests.swift` — 15 tests: history
  round-trip/replace/delete/missing, per-gateway history isolation, watermark
  round-trip/upsert/clear, replay_epoch round-trip/nil-default/per-gateway,
  fail-closed reset clears only the affected gateway, structural no-secret
  invariant (reflected model fields contain no token/ticket/credential/
  password/secret word; cache seam requirements have no token/credential
  entry). Runs on host with an in-memory SwiftData container.
- `HermesFleetAppTests/ModuleBoundaryTests.swift` *(modified, +5)* —
  app-level proofs: Keychain token store safe attributes; real simulator
  Keychain round-trip (save→load→delete, `[REDACTED]` description);
  file-backed SwiftData cache applies NSFileProtectionComplete +
  backup-excluded to its store file (read back on iOS); file-backed cache
  round-trips history + watermark + replay_epoch in the app sandbox with
  per-gateway reset isolation; and the "no token in cache" invariant — a
  token accepted only by the Keychain store is structurally unreachable from
  the SwiftData cache.

## 3. Design decisions (ADR-style)

1. **Tokens/tickets are a distinct Keychain seam from gateway credentials.**
   M7's `KeychainCredentialStore` stores the gateway auth credential;
   M10's `TokenStoring`/`KeychainTokenStore` stores short-lived tokens/tickets
   (WS tickets, session tokens) per peer. Both are GenericPassword /
   WhenUnlockedThisDeviceOnly / no-sync (synthesis §12), but they serve
   different lifetimes and are kept separate so one API cannot blur the two.
2. **Secrets never touch the cache — by construction, not by discipline.**
   `CacheStoring` has no token/credential parameter, `StoredToken` is
   non-Codable, and the SwiftData entities carry only transcript/watermark/
   epoch fields. A secret cannot be written into the cache through any public
   API, so "no tokens in cache" holds structurally (proved by reflection +
   API-surface tests, not by convention).
3. **The cache is a seam in FleetCore; the SwiftData store lives in
   FleetPersistence.** Mirrors the M7 `CredentialStoring` pattern: the replay/
   service layer and app composition depend on `CacheStoring`, never on
   SwiftData. FleetUI stays free of FleetPersistence internals (M0 guard).
4. **On-disk protection = NSFileProtectionComplete + backup-excluded.**
   The store file is created eagerly at container init (verified on host), so
   `CacheStoreProtection.apply` runs immediately in `makeFileBacked`.
   Backup-exclusion is applied on every platform; NSFileProtectionComplete is
   applied on iOS (where it is enforceable) and its attribute is read back and
   asserted in the app-level iOS test.
5. **Reset is fail-closed and per-gateway.** A stale replay_epoch clears that
   gateway's history + watermarks + epoch, so the client rehydrates from
   authoritative server state (spec §9.6). An unrelated gateway's cache is
   untouched (tested), matching the M8/M9 multi-gateway isolation posture.
6. **Host-runnable SwiftData keeps package tests hermetic.** FleetPersistence
   targets macOS 14+ for host builds; in-memory containers exercise all cache
   semantics without file I/O, while the iOS app-level test proves the real
   file-backed path + file-protection attributes on the simulator.

## 4. Verified contracts (source-grounded)

- SwiftData: `ModelContainer(for:configurations:)`, `ModelConfiguration(url:)`,
  `ModelContext(container)`, `FetchDescriptor` — verified against the iOS 26.5
  SDK SwiftData swiftinterface. Store file is created eagerly at container
  init (probed on host).
- Foundation: `URLResourceValues.isExcludedFromBackup` (get/set) and
  `(url as NSURL).setResourceValue(FileProtectionType.complete,
  forKey: .fileProtectionKey)` — verified against the iOS/macOS Foundation
  interface + host probe; `NSFileProtectionComplete` constant confirmed in
  `NSFileManager.h`.
- Keychain semantics follow Apple's Security framework:
  `kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  `kSecAttrSynchronizable = false` — matching M7 + synthesis §12.
- No new wire contract in M10 (cache/token stores are local).

## 5. Validation record (2026-08-29, apple-dev)

Toolchain: Xcode 26.6 (17F113) · Swift 6.3.3 · xcodegen 2.46.0 · iOS 26.5
simulator runtime · host macOS 26.6.2. Ran via `bash m10_validate.sh`
(PASS=12 FAIL=0).

| Command | Result |
|---|---|
| `swift build --package-path Packages/FleetCore` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetCore` | **112 tests, 0 failures** (106 prior + 6 new PersistenceDomainTests) |
| `swift build --package-path Packages/FleetSecurity` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetSecurity` | **20 tests, 0 failures** (10 prior + 10 new FleetSecurityTokenTests) |
| `swift build --package-path Packages/FleetPersistence` | Build complete, 0 errors |
| `swift test --package-path Packages/FleetPersistence` | **15 tests, 0 failures** (new FleetPersistenceTests target) |
| `xcodegen generate` | Regenerated; the development team present; package references intact |
| `xcodebuild build` (iOS Simulator, iPhone 17 Pro) | **BUILD SUCCEEDED** |
| `xcodebuild test` (iOS Simulator, iPhone 17 Pro) | **TEST SUCCEEDED — 24 tests, 0 failures** (19 prior + 5 new M10 boundary tests) |
| Secrets scan (M10 sources) | No hardcoded secret-like literals; fixture tokens are literal test values |
| SwiftUI isolation grep | 0 `import FleetNetworking` in `Packages/FleetUI/` |

Evidence highlights:
- Keychain token store: attributes = GenericPassword / WhenUnlockedThisDeviceOnly
  / no-sync (asserted); real simulator round-trip save→load→delete with
  `[REDACTED]` description ✓
- SwiftData cache (host, in-memory): history round-trip lossless, replace
  semantics (newest wins, no dup), delete, missing→nil, per-gateway history
  isolation; watermark round-trip/upsert/clear; replay_epoch
  round-trip/nil-default/per-gateway; reset clears only the affected gateway ✓
- File-backed SwiftData cache (iOS app test): store file read back as
  `isExcludedFromBackup=true` and a non-nil data-protection class
  (`NSFileProtectionComplete` is applied; the simulator reports its default
  class rather than the applied `.complete` — a known simulator limitation,
  see §6) ✓
- No-token-in-cache: reflected cache model fields contain no
  token/ticket/credential/password/secret word; cache seam has no token/
  credential API; a Keychain-stored token is unreachable from the cache ✓
- app composition: M10 seams constructible in the app context (Keychain token
  store + file-backed/in-memory SwiftData cache) ✓

## 6. Known limitations / handoff notes

- Gateway registry entries remain in-memory (M2/M7); only the non-secret
  cache + Keychain token store land in M10. Registry on-disk persistence is a
  separate concern (not in this card).
- The cache is bounded and per-gateway keyed; there is no eviction/expiry yet
  (the cache is disposable and reset wholesale on replay_epoch change).
- `CacheStoreProtection` applies NSFileProtectionComplete only on iOS (macOS
  host ignores it); backup-exclusion applies everywhere. The iOS Simulator
  does not faithfully honor per-file protection classes — it reports its
  default class (`CompleteUntilFirstUserAuthentication`) rather than the
  applied `.complete` — so the on-simulator assertion is that a non-nil
  protection class is reported and backup-exclusion is exact; the `.complete`
  value is enforced on physical devices.
- No live Hermes gateway connection in M10 — transport/network fixtures and
  host SwiftData only (consistent with M1–M9).

## 7. Out-of-scope respected

NO auth hardening (M11) · NO gateway-registry on-disk persistence · NO UI
wiring (P6) · NO live Hermes gateway connection · NO privileged Hermes
operations. `FleetUI` imports 0 `FleetNetworking` (structural guard preserved).
