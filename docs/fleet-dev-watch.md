# Hermes Fleet Dev: Apple Watch companion

Native watchOS companion for **Fleet Dev only** (`com.aiowa.hermesfleet.dev`).
There is no production Watch app in this change; production Build 97, its
bundle, Keychain, cache and signing are untouched.

## Identity and isolation

| Boundary | Fleet Dev iPhone | Fleet Dev Watch |
| --- | --- | --- |
| Bundle | `com.aiowa.hermesfleet.dev` | `com.aiowa.hermesfleet.dev.watchkitapp` |
| Companion | n/a | `WKCompanionAppBundleIdentifier = com.aiowa.hermesfleet.dev` |
| Embedded in | n/a | the Dev iPhone app only (`Watch/HermesFleetDevWatch.app`) |
| Credentials | Dev Keychain namespace | **none**; the Watch links only `FleetWatchKit` |
| Wire flavor | `dev` | `dev`; payloads of any other flavor are rejected on both ends |
| Entitlements | none | none (no app groups, no shared keychain, no push) |

WatchConnectivity pairs an iPhone app only with the Watch app embedded in it,
and every request and snapshot also carries a `dev` flavor tag. A Dev Watch
build therefore cannot read or act on production Fleet. `scripts/fleet_dev_guard.py`
fails the build if the Watch target links anything but `FleetWatchKit`, gains
capabilities or extensions, drifts from the Dev identity, or declares standalone
connectivity.

## Architecture (phone-mediated)

```
Watch app  --WatchConnectivity-->  Fleet Dev iPhone app  --existing seams-->  gateways
(no credentials)                   (Keychain, LiveOpsStore,
                                    conversation session)
```

* **State** goes phone → Watch through `updateApplicationContext` (latest wins;
  the system decides delivery timing). Snapshot = observed state only, with an
  observation time per gateway and an explicit coverage value
  (`reporting`, `limited`, `heldOver`, `unknown`).
* **Actions** go Watch → phone through interactive `sendMessage` with a reply.
  Nothing is queued by the OS for approvals; if the phone is unreachable the
  Watch says nothing was sent.
* **No standalone connectivity** and **no background delivery guarantee**. If the
  iPhone app is not running or reachable the Watch shows saved data labelled with
  its age.

Fleet's own model is reused: Gateway (machine) → Bot (a profile; `Route` =
gateway + profile) → Conversation (session; the bot's Main chat is its canonical
session). The Watch has no separate hierarchy.

## What each screen does

* **Context picker**: Machine → Bot → Conversation (or "whole machine" / "bot
  only"), built only from what the iPhone app already has configured. Shown at
  the top of every screen. A removed machine/bot/conversation is reported, never
  replaced by another destination.
* **Check in**: selected machine's connection status, observation time,
  coverage, running work, items needing attention; count of items on other
  machines. Stale (>10 min) is labelled STALE; the link state is always shown.
* **Approvals**: lists approvals for the selected context, plus an "Other
  machines/bots" section so nothing is hidden. Each approval shows its original
  machine/bot/chat.
* **Messages**: explicit Send to the selected machine/bot/conversation, with
  delivery states below.

## Approval rules (unchanged from the phone, never broader)

* The Watch request carries the original gateway, session, request ID and a
  SHA-256 of the exact redacted command it displayed. It never references the
  picker selection, so switching context cannot redirect it.
* The phone re-reads pending approvals from the original gateway before acting.
  Not pending → "already resolved/expired"; digest differs → "changed" (nothing
  sent, Watch refreshes).
* **Deny** is always available for a still-pending request and needs no presence
  check (same as the phone).
* **Approve once** only (never session/always). It runs through
  `LiveOpsStore.approve`, so the **Face ID/passcode check happens on the
  iPhone**, and the full-command review rule applies. A command longer than the
  Watch preview, a request without an "once" choice, an inactive/locked phone,
  or a failed presence check all hand off to the iPhone.
* A UUID ledger and a per-approval in-flight guard prevent duplicate actions. A
  thrown gateway error re-reads state: still pending → failed; gone → "unconfirmed".
* Actions are refused when the Watch snapshot is older than 2 minutes.

## Message delivery states

`Queued on Watch` (not transmitted) → `Sent to iPhone, awaiting confirmation` →
`Delivered` (the gateway's `submitPrompt` returned) | `Not delivered` (definite
failure, safe to send again) | `Delivery unknown` (transmitted, outcome not
known). Unknown is never auto-resent; "Send again" reuses the same client message
ID and the phone dedupes by it. Uncertain gateway errors on the phone are also
reported as unknown, not failed. A relaunch turns anything in flight into unknown.

## Privacy

* While the iPhone app is locked or its privacy shield is up, it pushes a snapshot
  with no names, commands or approvals, and refuses actions.
* The Watch redacts content when the display is dimmed (always-on).
* With App Lock on, the phone does **not** blank the Watch merely because the app
  went to the background; the Watch shows the last snapshot with its age. See
  "Decisions to confirm".

## Message path, freshness and delivery (after the first device test)

* **Destinations.** The Watch distinguishes bot *Overview* (status only, never
  a destination), *Main chat* and a named *conversation*. A message freezes
  `machine › bot › chat` at compose time. Main chat must already exist in the
  iPhone's roster; the Watch send path never looks up, creates, resumes by
  guess or substitutes a chat. A bot without Main chat says "establish it on
  iPhone".
* **Staged diagnostics.** A failed send reports its stage (`validate`,
  `resume`, `submit`) plus a Swift error case name, never a token, URL or
  message text. iPhone Bot Chat resolution reports `lookup`, `unconfirmed`,
  `malformedRegistry` or `create` the same way. A failed registry lookup still
  never becomes an empty registry and never creates a chat.
* **Connectivity vs freshness.** "Watch ↔ iPhone" is shown separately from
  "iPhone → machine" (reachable / unreachable / not connected). Bots, chats and
  running work each carry their own observation time and show
  Current / Stale / Unavailable · cached / Never observed. A new snapshot never
  freshens older data. Approvals are actionable only from their own gateway
  observation time, and an approval missing from a non-reporting machine is
  "can't confirm", not "resolved".
* **Delivery.** Queued (never sent) → Handed to iPhone → Accepted by gateway
  (not a reply) | Not sent (safe to send again) | Unknown (never resent; check
  the chat on iPhone or discard). The iPhone persists admission (message ID,
  destination and payload fingerprint, no text) before dispatch, so replay or a
  phone restart cannot submit twice; an admission with no recorded outcome after
  a restart is "unknown".
* **Reply preview: not implemented.** `prompt.submit` returns only
  `{status}` and conversation events carry no turn or prompt id, so a Watch
  reply cannot be tied to the Watch's message when the iPhone or another client
  is also active in that conversation. The Watch shows "accepted" and points to
  the chat on iPhone.

## Mock data

DEBUG Watch builds can launch against a scripted mock phone
(`-fleet-watch-mock -fleet-watch-scenario normal|stale|offline|expired|uncertain|disconnect`)
and show a **MOCK DATA** banner. The simulator iPhone app also runs the scripted
fleet and labels its snapshots as mock. Mock paths are compiled out of Release.

## Tests

```sh
(cd Packages/FleetWatchKit && swift test)            # protocol, policies, Watch store
python3 scripts/fleet_dev_contract_test.py           # Dev/Watch identity guard
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetDevWatchTests \
  -destination 'platform=iOS Simulator,name=<iPhone>' -skipMacroValidation test   # phone bridge, hosted by Dev app
```

`FleetWatchKit` is not yet registered in the CI package phase
(`scripts/c1_packages.sh`); the CI integrator owns that count.

## Decisions to confirm

1. Approve from the wrist requires Face ID on the iPhone (strictest reading of
   "no easier than the phone"). Allowing Watch-side approval would be a new
   security decision.
2. Watch content while App Lock is on and the phone app is backgrounded.
3. Production Watch app and Watch push notifications are out of scope here.
