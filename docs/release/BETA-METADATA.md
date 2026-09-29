# TestFlight beta metadata — external review draft

Status: **working draft for a future reviewed candidate**. This is not a
readback of App Store Connect. `RELEASES.md` records the owner's reported
public Build 90 availability and its provenance limitations. Current main
includes later integrated source. Verify this copy against the exact submitted
build and current private ASC fields before use.

All previous Build 86 navigation instructions and owner placeholders are
retired. Required private values belong in ASC, not in this public draft.
Record public-safe completion evidence under #18; this file cannot establish
that the reviewer environment or metadata is ready. Never commit demo
credentials, QR payloads, private endpoints, tokens, or private contact details.

## Beta App Description

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent gateways. Connect a gateway you control, see its available profiles and bots, open a conversation, and send prompts while the gateway performs the agent work. Fleet stores gateway credentials in the iOS Keychain and connects directly to the gateway selected by the user; it does not require an AIowa-hosted relay or shared operator account.

Current integration source includes gateway health and roster visibility,
streaming conversations, bot/profile management, canonical Bot Chat, Bot
Routines, hosted Groups and RoomLink, and gateway-owned surfaces such as
approvals, session controls, skills, Projects, capability-gated Kanban editing, and memory
browsing. Capabilities depend on the connected Hermes gateway's advertised
methods and permissions. Unsupported or restricted capabilities remain
unavailable rather than presenting fabricated state.

## Feedback Email

`hello@aiowa.dev`

This is the intended TestFlight feedback address. Confirm it is monitored for
the entire beta before enabling external testers.

## Support, marketing, and privacy-policy destinations

No support, marketing, or app privacy-policy destination is verified by this
draft. The release owner must confirm the intended URLs, reachability, and
app-specific policy content before entering them in App Store Connect. No
current App Store Connect value is inferred here.

## What to Test — RC focus

If an owner-provisioned reviewer environment and access instructions are
available in App Store Connect, please test using that private endpoint. This
draft does not establish that such an environment is provisioned or verified:

1. Launch the exact candidate, complete onboarding, and open **Fleet → Manage Gateways** (also available from Settings).
2. Add the supplied gateway by entering its endpoint and scoped credentials, or scan the supplied private pairing QR code.
3. Confirm the gateway reaches a healthy connected state and its demo roster appears.
4. Open **Bots** and inspect the supplied bot/profile. Open its canonical Bot
   Chat if provided; use **Chats** for an ordinary conversation session.
5. Send a harmless prompt and confirm the reply streams into the conversation
   and completes normally.
6. If the gateway advertises the required methods, inspect hosted Groups and
   their available actions from the Groups destination.
7. If the demo gateway advertises it, invoke the supplied safe read-only demo
   skill. Do not expect production, privileged, destructive, billing, or
   personal-data capabilities.

The repository does not verify whether a reviewer environment is provisioned,
synthetic, isolated, or reachable. Before relying on one, the release owner
must verify its isolation, least-privilege configuration, endpoint, and
availability for the review window. Do not substitute a personal gateway or
represent an unverified environment as ready. Once verified, describe any
gateway-dependent surfaces that are intentionally unavailable and provide a
private support contact for access problems.

## Beta App Review contact

- First name: Anthony
- Last name: Simons
- Phone: required privately in ASC; completion unverified.
- Email: `tony@aiowa.dev`

## Review notes

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent gateways. The app is not a standalone offline chat client. Use a reviewer environment only after the release owner has verified its isolation and access path; this repository does not establish that readiness.

For a candidate matching current navigation, install it and open **Fleet → Manage Gateways**
to add the supplied endpoint or scan the private QR. After the roster settles,
open **Bots** to inspect the demo bot and its canonical Bot Chat, or open
**Chats** for an ordinary session. Send a harmless prompt such as "Reply with
READY and a short sentence describing this demo environment." The response
should stream into the conversation. If the gateway advertises the capability,
inspect Groups; run the supplied read-only demo skill only when available.

For a reviewer environment, require synthetic data and least-privilege access;
the current repository does not prove that those conditions have been met.
The gateway's advertised methods determine which capabilities are available.
The app stores credentials in the iOS Keychain and does not require a Fleet
account. Verify any access instructions and support contact before submitting
or relying on them; never substitute a personal gateway.

## Reviewer onboarding instructions

The reviewer receives the endpoint and temporary access material privately in
App Store Connect. Do not place those values in this file. The clean-install
walkthrough is:

1. Install the submitted build, complete onboarding, and open **Fleet → Manage Gateways**.
2. Add the supplied gateway manually or scan the private pairing QR.
3. Confirm the endpoint and username, save, and authenticate if prompted.
4. Wait for connected gateway health and the review roster to settle.
5. Open a supplied profile/session or create a new session.
6. Send a harmless prompt and verify that the response streams and completes.
7. Inspect the profile and, only if advertised, invoke the supplied read-only
   demo skill.

If an owner-provisioned reviewer environment exists, record the capabilities
it actually exposes. It may omit attachments, voice, RoomLink, scheduling, or
other gateway-dependent surfaces; describe confirmed restrictions honestly in
private review notes rather than assuming them from this draft.

## Known limitations relevant to review

- Fleet requires a user-owned Hermes gateway; it does not ship a gateway of
  its own or provide an AIowa-hosted relay.
- Capabilities vary with gateway version and advertised permissions.
- Cross-gateway `@Bot` delivery is not guaranteed by Fleet.
- Cross-gateway RoomLink is text-only and is not couriered by the iPhone in
  the background.
- Fleet Home coverage is limited to items observed by this phone; it is not a
  complete fleet-wide pending-action inbox.
- The exact feature surface and device support for any later candidate must
  be confirmed against that owner-approved build.

## Demo access fields — private only

Required privately in ASC: reviewer-safe endpoint and temporary scoped credentials or QR setup artifact. Provisioning and verification remain unverified under #18.

Before submitting, verify the exact endpoint and access material from a clean install and from an off-network location. Rotate/revoke the credential after the review window or if it is exposed. The reviewer environment must remain operational for the full review period.

## Privacy answers dependency

Issue #13 owns the privacy manifest and required-reason audit. The manifest
and source-level validator are present in the recorded repository snapshot,
but the issue still requires evidence from the exact shipping archive,
resolved dependencies, and App Store Connect reconciliation. Do not infer
App Store Connect privacy answers from this draft. Reconcile the final answers
with actual collection/transmission, required-reason APIs, the privacy policy
URL, and the exact build submitted for review.

## Export compliance confirmation

The repository snapshot declares `ITSAppUsesNonExemptEncryption = false` in
`HermesFleetApp/Info.plist`. Confirm this against the final RC and complete the private ASC export-compliance fields; completion remains unverified under #18.

## Pre-submission checklist

- [ ] Required private review fields are complete in App Store Connect and public-safe evidence is linked in #18.
- [ ] `hello@aiowa.dev` and the App Review contact are monitored for the review window.
- [ ] A valid international-format App Review phone number is entered privately.
- [ ] Privacy answers match the issue #13 audit and final RC.
- [ ] An app-appropriate privacy-policy URL is configured and reachable.
- [ ] The intended support/marketing URL is verified and reachable.
- [ ] Demo access is entered privately and tested from a clean install/off-network.
- [ ] No secret or private infrastructure detail was added to this repository.
- [ ] Export-compliance posture is human-confirmed for the final RC.

## Apple field references

The current Apple workflow requires a Beta App Description and Feedback Email
for external testing. App Review information includes a contact name, email,
phone number, and notes; login credentials are required only when the app
requires a login. Export-compliance information must also be supplied for the
uploaded beta build, even when the app declares encryption exempt/non-exempt
status in its bundle metadata.

- [Apple: Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [Apple: App Review information properties](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Apple: Provide export compliance information for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds)
