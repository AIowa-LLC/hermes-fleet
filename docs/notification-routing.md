# Notification tap routing (R3 seam, #89)

Status: domain seam only. Nothing here registers for APNs, opens HPKE
payloads, or touches the UI; those depend on unmerged PRs (see below).

`Packages/FleetCore/Sources/FleetCore/NotificationRouting.swift` consumes the
v1 payload produced by the push sender (`push_payload.py`, PR #160) **after**
it has been opened, and decides:

| Question | Type |
| --- | --- |
| What may a banner show (App Lock, locked device, hide previews, open failure, expiry)? | `NotificationPresentation` |
| New delivery, replayed nonce, reconnect re-push of the same request, or expired? | `NotificationReplayLedger` |
| Which gateway/session/request does a tap target? | `NotificationTapTarget` |
| What truthful screen does the tap open? | `NotificationTapResolver` |

Invariants (tested): tapping is navigation only (no `ApprovalChoice` anywhere);
`response_token` and `command_digest` are never decoded or retained; high-risk
previews never show command text; a gateway display label resolves a gateway
only when exactly one matches (a registered id wins); notification expiry never
overrides an authoritative `approval.pending` answer; resolved, expired,
disconnected and removed-gateway states each get a safe destination.

## Integration dependencies (not done here)

- HPKE open + shared push key: #157, #160 (vectors), #169 (shared keychain/App Group). #169 currently conflicts with main.
- Persisting the ledger and `NotificationTapTarget` in `userInfo` (App Group): needs #169.
- Wiring `UNUserNotificationCenterDelegate` tap -> `NotificationTapResolver` -> navigation: touches `HermesFleetApp.swift`/`AppEnvironment` (shared; coordinate with the integrator and #168).
- Mapping `requestStatus` from `approval.pending` after App Lock unlock.
- Action buttons (#91) are intentionally absent.
