# Group Chats 2.0: room identity and reconciliation

## Authority and source records

Fleet treats the gateway-hosted `FleetRoom` record as the only interactive
source of truth. A Desktop projection is an observational, bounded history
record. `FleetRoomID` retains provenance, gateway, and source key for every
record; reconciliation never rewrites those records and never concatenates
hosted and Desktop transcripts.

`FleetRoomReconciler` produces a `FleetRoomReconciliationSnapshot` with:

- `primaryRooms`: hosted rows suitable for the normal Groups list.
- `legacyArchiveRooms`: every live Desktop projection, including projections
  related to a hosted room, for historical recovery.
- `relationships`: verified associations whose hosted identity is primary.

## Relationship rules

A legacy projection can anchor a hosted relationship only when its durable
`id:<roomID>` key resolves to the hosted room ID **and** it arrived from the
same gateway. This uses the existing continuation contract; a display name or
bare room ID alone is never sufficient. A projection from another gateway is
accepted only as a compatible mirror of that anchor (same stable name, member
identity set, and matching revision or overlapping durable event IDs).

Same-name rooms, same bare IDs without a same-gateway anchor, conflicting
hosted authorities, and name-keyed Desktop records remain separate. Refresh
order is normalized by stable identity ordering. Hosted tombstones are retained
as negative knowledge so stale Desktop records cannot resurrect a disbanded
room.

## UI behavior

The Groups list consumes `AppEnvironment.allRooms`, which is the reconciled
hosted-primary list. Desktop projections are accessible only in the **Desktop
history archive** section and are labeled read-only. Hosted rows show the
actual gateway roster and capability-driven controls; internal authority
installation identifiers are not presented in normal row or VoiceOver text.

Hosted history remains gateway-authoritative. `groups.log` pages are drained by
cursor, merged by durable event ID, and never synthesized locally. Sends reuse
a client event ID after an indeterminate transport failure. Unsent composer
drafts are stored locally by source room identity and are cleared only after a
successful gateway response.

## Desktop interoperability status

The inspected Fleet boundary consumes Desktop projections through the existing
profile metadata path, while hosted rooms use `groups.list`, `groups.state`,
`groups.log`, and the supported `groups.*` command seams. No supported upstream
Hermes Desktop hosted-room consumer was present in the authorized Fleet
worktree, and this change does not modify Hermes Desktop, Hermes Agent, or
wire protocols. Full cross-client hosted-room round-trip remains a separately
authorized release dependency; Fleet does not copy hosted rooms into Desktop
metadata or claim Desktop compatibility without an actual round trip.
