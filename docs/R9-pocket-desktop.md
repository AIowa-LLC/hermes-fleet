# R9 — "Pocket Desktop" round evidence

Goal: close the Hermes Fleet (iOS) ↔ Hermes Desktop gap over the WS
JSON-RPC surface the app already speaks — approvals, YOLO, model picker,
context meter, steer/rename/fork, cron, skills, memory graph. Delivery:
dev-signed installs to Tony's paired iPhone only (no TestFlight; batch
auth 2026-09-03). Plan: `.hermes/plans/2026-09-03_181325-r9-pocket-desktop.md`.

All wire shapes were verified against the installed hermes-agent source
(`~/.hermes/hermes-agent`, 0.21.0) with file:line citations before
coding; every task landed test-first. Local CI gate
(`scripts/c1_ci_validate.sh`) ran PASS=9 FAIL=0 on each task's final
commit.

| Task | Scope | Commit | Build |
| --- | --- | --- | --- |
| T1 | Approval banner (approval.pending/received/respond + per-session YOLO toggle) | `5603f15` (+ QA rework `255da9f`) | 13 |
| T2–T4 | Model picker (sticky, session-scoped), context meter + breakdown, steer/rename/fork | `5596900` | 14 |
| T5/T6 | Cron pane + Skills pane (`cron.manage`, `skills.manage` + `profiles.describe`/`configure`) | `c8cfd2f` (+ QA rework `66919f4`) | 15, 16 |
| T7 | **Memory Graph — read-only star map + docs sweep (this doc)** | `09bc296` (build bump `d254258`, CI PASS=9 FAIL=0) | 17 |

## T7 — Memory Graph (read-only star map)

### Wire ground truth (the plan's assumption, corrected)

The plan scoped this task as "`learning.graph` nodes+edges". **There is no
`learning.graph` method on the 0.21.0 WS registry** — exhaustive `@method`
scan of `tui_gateway/`. The learning surface over WS is:

- `learning.frames {cols, rows, frames}` — `tui_gateway/methods_tools.py:1840-1862`.
  Returns `render_frames(payload, cols, rows, frames)`
  (`agent/learning_graph_render.py:626-657`): pre-rendered TUI grid runs
  (which we never paint) PLUS structured metadata we DO render:
  - `buckets` — one row per date slice; per-node
    `{id, glyph, label, fullLabel, meta, body, style}`
    (`learning_graph_render.py:332-361`, `_bucket_rows`/`_bucket_nodes`)
  - `summary` lines (`build_summary`, :586-606)
  - `axis {start, end}` (:566-570), `legend`, `categories`, `count`
- `learning.detail {id}` — `methods_tools.py:1864-1872` →
  `agent/learning_mutations.py:86-118`: `{ok, kind: skill|memory, id,
  label, content}`; failures return `{ok: false, message}`.
- `learning.edit` / `learning.delete` exist (:1875/:1878) but are OUT OF
  SCOPE for R9 (read-only round).

The structured nodes+edges payload (`build_learning_graph`,
`agent/learning_graph.py:254-330`) is served to the DESKTOP panel via REST
`GET /api/learning/graph` (`hermes_cli/web_server.py:4412-4420`) — not
over this app's WS transport. The app therefore rides `learning.frames`
(structured buckets) + `learning.detail`, entirely over the existing
authenticated WS transport.

### Live payload measurement (plan requirement)

Measured 2026-09-04 by running the EXACT handler code path
(`build_learning_graph()` + `render_frames()`) against this Mac's profile
skills/memories:

```
nodes: 14 (4 learned skills, 10 memories)
edges: 13
raw graph JSON:            10,011 bytes
learning.frames frames=2:  10,027 bytes
learning.frames frames=48: 69,256 bytes (default; grid runs dominate)
```

Conclusion: the client asks for `frames: 2` (the server floor —
`render_frames` clamps to ≥2) because the pre-rendered grid runs are pure
dead weight for a phone that paints its own constellation. Bucket metadata
carries the data. Total wire cost ≈ 10 KB for a real profile — no cap
needed on the FETCH; the 300-node cap is a RENDER-side guard.

### Filter honesty (plan deviation, documented)

The plan's All/Used/Learned filter is NOT derivable from the WS payload:
bucket node rows carry no `useCount`/`createdBy`
(`learning_graph_render.py:344-357`), and `build_learning_graph` already
excludes base/unlearned skills (`learning_graph.py:266-270` — only
agent-created or used skills survive). The honest filter set is
**All / Skills / Memories** (derived from the `style`/id-prefix kind).

### What shipped

- `FleetCore/LearningGraph.swift` — models (`LearningGraphNode`, buckets,
  summary, detail), `GatewayLearningProviding` seam,
  `LearningGraphSnapshotStoring` persistence seam,
  `UnsupportedGatewayLearning` fail-closed default,
  `GatewayLearningError` typed errors.
- `FleetNetworking/GatewayLearningClient.swift` — `learning.frames`
  {cols:60, rows:20, frames:2} + `learning.detail` over the shared
  transport; idempotent cold-connect; `{ok:false}` → `.nodeNotFound`.
- `FleetPersistence/LearningGraphSnapshot.swift` — SwiftData
  `LearningGraphSnapshotRow` (one per gateway, replace semantics,
  Codable payload round-trip; same no-secret invariant as every cache
  model) + store methods; container schema extended in BOTH factories.
- `FleetUI/MemoryGraphViewModel.swift` — `MemoryStarLayout`: deterministic
  (stable FNV-1a-id-keyed spiral angle; bucket-index sort — same fixture
  → same positions, insertion-order independent), 300-node render cap
  MOST-RECENT-FIRST with honest "showing N of M", desktop-ported
  recency-ink gradient (AGE_OLD/MID/NEW constants from
  `learning_graph_render.py:23-31`), timeline reveal cuts buckets
  chronologically. VM: offline snapshot prefill → live fetch (failure
  surfaces honestly, never hides), save-on-success.
- `FleetUI/MemoryGraphView.swift` — SwiftUI Canvas constellation
  (● skills muted, ◆ memories pale-cyan = the drillable ink, matching the
  desktop palette roles), drag pan + anchored pinch zoom (1–4×), tap
  hit-test → `learning.detail` drill-in sheet (mono SKILL.md / memory
  chunk, read-only), filter chips, scrubber, offline banner, empty state,
  a11y ids throughout (`memorygraph.canvas/.filter/.scrubber/.summary/…`).
- Wiring: `AppEnvironment` `learningSeamFactory` + snapshot store +
  `makeLearningSeam` (fail closed); `FleetScreen.memoryGraph` route;
  dashboard Management section entry ("Memory Graph"); composition root
  `GatewayLearningClient` per gateway (production) /
  `ScriptedLearningSeam` fixture journey (DEBUG simulator).
- READ-ONLY: no edit/delete affordances (R10).

### Tests (TDD; RED observed before each implementation pass)

- `FleetNetworkingTests/GatewayLearningClientTests` — 8 wire tests
  (frames ask shape incl. frames=2 floor, bucket/summary/axis decode,
  profile scope forward, empty-graph-is-valid, malformed → typed error,
  detail decode + ok:false mapping, RPC error mapping, cold-transport
  connect).
- `FleetPersistenceTests/LearningGraphSnapshotTests` — 5 tests (round-trip
  equality, replace semantics, nil-without-snapshot, per-gateway scoping,
  delete isolation).
- `HermesFleetAppTests/MemoryGraphTests` — 12 tests (layout determinism ×2
  incl. bucket-order independence, cap at 300 most-recent + capLabel +
  under-cap no label, filter ×2, scrub reveal 24→12→0, VM load+snapshot
  save, error surfacing without fabricated graph, offline prefill +
  honest error + `.offlineSnapshot` source, detail load).
- `HermesFleetAppUITests/R9MemoryGraphUITests` — deterministic scripted
  walkthrough: dashboard entry → summary → canvas 14 nodes → memories
  filter 4 nodes → back to 14 → scrub 1 node → pan gesture stable.

### Simulator screenshots (iPhone 17 Pro, scripted fleet)

- `docs/screenshots-r9/r9-memorygraph-star-map.png` — full fixture map
- `docs/screenshots-r9/r9-memorygraph-memories-only.png` — memories filter
- `docs/screenshots-r9/r9-memorygraph-scrubbed-early.png` — timeline
  scrubbed to the first bucket

Pixel-verified: the canvas region contains rendered constellation marks
(2,317 lit pixels sampled in the star-map shot; not a blank canvas).
