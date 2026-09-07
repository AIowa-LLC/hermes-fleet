# B1 Slice 9 — Cross-gateway Groups Protocol Spike (t_4c88b0c3)

Verdict: **PROVEN — client-driven cross-gateway room setup is safely
implementable against the current gateway contract.** Slice 10 proceeds.

Evidence base: upstream hermes-agent source copy at
`/private/tmp/hermes-bot-protocol-current` (orchestrator-provided reference,
read 2026-09-07). All file:line citations below are from that tree.

## 1. The wire contract (protocol truth)

### 1.1 Capability advertisement — `groups.capabilities`

`tui_gateway/methods_groups.py:218-247`: every gateway advertises
`protocol_version`, `driver`, `authority_gateway_id`, `room_link
{enabled, profile, catalog, endpoint}` and the full `methods` list. The
catalog (`gateway/hosted_room_peer.py:194-241 GatewayRoomCatalog`) is
digest-carrying and strict-fielded: `installation_id`,
`protocol_versions`, `link_modes` (only `"direct"` is implemented —
`hosted_room_peer.py:262-263` filters every other mode out),
`persistent_process`, `text`, `attachments`, `execution_policy`,
`catalog_digest` (HMAC-verified on decode, `hosted_room_peer.py:222-223`),
plus optional advertised `endpoint {available, url, transport_security}`.

RoomLink is honestly disabled (`room_link.enabled=false` with reason
`durable_run_storage_required` or `gateway_roomlink_secret_unavailable`)
when the gateway cannot support it (`methods_groups.py:235-238`) — an old
or misconfigured gateway never fakes support. Unknown capability must be
read as unsupported.

Endpoint transport security: HTTPS required except plaintext HTTP toward
loopback (`validate_room_link_url`, `hosted_room_peer.py:317-340`).

Execution policy: advertised per profile inside the catalog; a process in
approval-mode `off` REFUSES to advertise remote execution at all
(`catalog_mapping`, `hosted_room_peer.py:254-258`) — policy mismatch cannot
be bypassed by omitting fields.

### 1.2 Peer members in a room roster — the create-time contract

`gateway/hosted_room_discussion.py:43-44` `_TARGET_FIELDS`:
a member may carry `target: {kind: "peer", peer_id, installation_id,
profile, capability_digest}` (digest must be `[0-9a-f]{64}`,
`hosted_room_discussion.py:217-219`). Cross-gateway remote fields
(`connectionId`, `targetProfile`, … `_REMOTE_MEMBER_FIELDS`, lines 46-49)
are explicitly REJECTED on members — the peer target is the only
cross-gateway representation. `validate_roster` (lines 242-270) enforces
frozen 2-6 members, unique handles/ids/targets, and that a peer target's
profile matches the member profile.

Identifier charset for member_id/room_id/profile:
`^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,255}$` (`hosted_room_peer.py:33`).
Fleet's `room-<uuid>` setup ids and `fleet-<hex>` member ids conform.

### 1.3 Setup choreography (client = controller, gateways = relay)

1. **Create** the room on the HOME gateway: `groups.create`
   (`methods_groups.py:359-366`) with the full roster including peer
   targets. Authority (gateway id + epoch) is stamped server-side
   (`hosted_room_service.py:432-444`). Idempotent by `room_id` — a retry
   with the same id after partial failure reuses the room.
2. **Invite** on the TARGET gateway: `groups.peer.invite`
   (`methods_groups.py:250-279`) mints a target-issued scoped grant bound
   to `{room_id, home_install_id, authority_gateway_id,
   authority_epoch, member_id, target_profile, execution_policy_digest}`
   with TTL 60s-24h, and returns `{grant, target_profile, catalog,
   endpoint}`. The grant is capability-scoped, not a bearer key.
3. **Register** on the HOME gateway: `groups.peer.register`
   (`methods_groups.py:297-343`) takes `{target_url, catalog, grant,
   room_id, member_id, target_profile}`, PROBES the target over direct
   HTTP using the grant (`PeerRunsHTTPClient.probe` →
   `/v1/room-members/capabilities`, `hosted_room_peer_http.py:598-601`),
   requires protocol-version + direct-mode + full-catalog equality
   (structural, not just digest — lines 307-317), verifies the probe's
   grant scope against the home room's authority (lines 322-329), then
   pins the direct route. The transport is **gateway↔gateway** — the
   iPhone only issues the two RPCs and is never in the data path.
4. **Revoke** (cleanup on failed setup): `groups.peer.revoke`
   (`methods_groups.py:282-294`) using the exact profile scope.

Failure behavior is typed: validation refusals arrive as code 5120 with
exact messages; catalog drift between invite and register is rejected
("target capability catalog changed during setup", line 316-317);
grant-scope mismatch is rejected (line 329).

### 1.4 Authority / replication boundaries (what Fleet must NOT do)

- Authority epochs and fencing are server-owned
  (`groups.capabilities` features list, `methods_groups.py:243-246`).
- `groups.promote` requires `confirm:true` (4118 otherwise,
  `methods_groups.py:508-517`) — operator recovery action, never
  automatic from Fleet.
- Replica storage (`groups.replicate` / `groups.replica_state`) is
  gateway-owned; Fleet does not create client-side replica stores
  (spec §11.7).

## 2. What Desktop does (calibration, not authority)

`apps/desktop/src/plugins/hermes-bots/` contains no `peer.invite` /
`peer.register` calls (grep verified) — Desktop drives setup through the
same gateway RPC surface indirectly. Fleet implementing the RPC sequence
above is a first-class client of the published contract, not an
invention.

## 3. Consequences for Fleet (slice 10 shape)

- Upgrade `CreateRoomSheet` to offer remote bots whose gateway advertises
  a compatible direct catalog (check per §1.1, cached per sheet
  presentation, re-validated before submit).
- Orchestration in `AppEnvironment`: create (home) → per remote member:
  invite (target) → register (home); revoke grants on failure; the room
  remains usable same-gateway if a link fails (typed, honest failure —
  no facade per spec §11.8).
- Never persist or display the grant token (transient controller state).
- Same-gateway rooms keep the existing path unchanged.
- Parked Codex WIP (3fbb046) matches this contract in
  FleetCore/FleetNetworking; its CreateRoomSheet presentation hunk was
  broken (nested Text modifiers) and is rewritten in slice 10.
