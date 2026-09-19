# TestFlight beta metadata — external review draft

Status: **draft only**. This file is not a release announcement and does not
claim that a build has been uploaded, approved, or made available. No release
date, TestFlight invitation URL, final build number, or final RC SHA is known
yet. The source snapshot used for wording review is `d0f607b` on 2026-09-18;
reconfirm the feature and minimum-OS statements against the synchronized RC in
Issue #50 before pasting anything into App Store Connect.

Do not place demo credentials, QR payloads, private endpoints, access tokens,
or a private phone number in this repository. Apple requires a monitored
review contact and phone number in App Store Connect; the remaining owner-only
fields below stay explicit until Tony supplies real release-specific values.

## Beta App Description

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent gateways. Connect a gateway you control, see its available profiles and bots, open a conversation, and send prompts while the gateway performs the agent work. Fleet stores gateway credentials in the iOS Keychain and connects directly to the gateway selected by the user; it does not require an AIowa-hosted relay or shared operator account.

The beta supports gateway health and roster visibility, streaming chat, bot/profile inspection, approvals and session controls where the connected gateway advertises them, and additional gateway-owned surfaces such as skills. Available capabilities depend on the connected Hermes gateway version and its permissions. Unsupported or restricted capabilities remain unavailable rather than presenting fabricated state.

## Feedback Email

`hello@aiowa.dev`

This is the intended TestFlight feedback address. Confirm it is monitored for
the entire beta before enabling external testers.

## Support, marketing, and privacy-policy destinations

- Support/marketing destination supplied for Hermes Fleet: `https://fleet.aiowa.dev`
- Verification status on 2026-09-18: **not verified**. Public DNS did not
  resolve this host from the release-preparation environment, so do not enter
  it as a functional App Store Connect support or marketing URL until Tony
  confirms that it is live and provides the intended path.
- Privacy-policy candidate checked separately: `https://aiowa.dev/privacy`
  returned HTTPS 200, but its visible policy text describes the AIowa website.
  Tony must confirm that it is an appropriate app privacy-policy destination
  before entering it in App Store Connect; this repository does not treat that
  check as approval.

## What to Test — RC focus

Please test using the private reviewer-safe endpoint and access instructions supplied in App Store Connect:

1. Launch Fleet and open Gateways.
2. Add the supplied gateway by entering its endpoint and scoped credentials, or scan the supplied private pairing QR code.
3. Confirm the gateway reaches a healthy connected state and its demo roster appears.
4. Open a supplied bot/profile session, or create a session if none is provided.
5. Send a harmless prompt and confirm the reply streams into the conversation and completes normally.
6. Open bot/profile inspection and review the displayed identity and available capabilities.
7. If the demo gateway advertises it, invoke the supplied safe read-only demo skill. Do not expect production, privileged, destructive, billing, or personal-data capabilities.

The reviewer environment is synthetic and isolated. Some surfaces may be unavailable when the demo gateway does not advertise them; this is intentional least-privilege configuration. If the supplied environment cannot be reached, please use the private contact below rather than adding a personal gateway.

## Beta App Review contact

- First name: Anthony
- Last name: Simons
- Phone: [TONY: ENTER A MONITORED INTERNATIONAL-FORMAT REVIEW PHONE IN APP STORE CONNECT]
- Email: `tony@aiowa.dev`

## Review notes

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent gateways. The app is not a standalone offline chat client: reviewers should connect to the supplied isolated demo environment.

Install the submitted build, open Gateways, and use the reviewer-safe endpoint and scoped credentials (or private QR pairing artifact) entered in App Store Connect's demo-access fields. Authenticate if prompted, wait for gateway and roster health, open or create a demo profile session, and send a harmless prompt such as "Reply with READY and a short sentence describing this demo environment." The response should stream into the conversation. Then inspect the bot/profile details and, if available, run the supplied read-only demo skill.

The demo environment contains synthetic data only. Production gateways, personal/business data, privileged shell or file operations, destructive administration, billing, and account-management actions are intentionally disabled. Capabilities vary with the gateway's advertised methods. The app stores credentials in the iOS Keychain and does not require a Fleet account. If the reviewer-safe environment is unavailable, please use the private review contact rather than substituting a personal gateway.

## Reviewer onboarding instructions

The reviewer receives the endpoint and temporary access material privately in
App Store Connect. Do not place those values in this file. The clean-install
walkthrough is:

1. Install the submitted build and open **Gateways**.
2. Add the supplied gateway manually or scan the private pairing QR.
3. Confirm the endpoint and username, save, and authenticate if prompted.
4. Wait for connected gateway health and the synthetic roster to settle.
5. Open a supplied profile/session or create a new session.
6. Send a harmless prompt and verify that the response streams and completes.
7. Inspect the profile and, only if advertised, invoke the supplied read-only
   demo skill.

The reviewer environment is least-privilege and may intentionally omit
attachments, voice, RoomLink, scheduling, or other gateway-dependent surfaces.
Those restrictions should be described honestly in the private review notes.

## Known limitations relevant to review

- Fleet requires a user-owned Hermes gateway; it does not ship a gateway of
  its own or provide an AIowa-hosted relay.
- Capabilities vary with gateway version and advertised permissions.
- Cross-gateway `@Bot` delivery is not guaranteed by Fleet.
- Cross-gateway RoomLink is text-only and is not couriered by the iPhone in
  the background.
- Fleet Home coverage is limited to items observed by this phone; it is not a
  complete fleet-wide pending-action inbox.
- The final supported iOS/device floor and exact release feature surface must
  be confirmed against the synchronized RC.

## Demo access fields — private only

[TONY: IN APP STORE CONNECT, PROVIDE THE CURRENT REVIEWER-SAFE ENDPOINT AND TEMPORARY SCOPED CREDENTIAL OR QR SETUP ARTIFACT USING THE PRIVATE REVIEW-ACCESS FIELDS. NEVER COMMIT THEM HERE.]

Before submitting, verify the exact endpoint and access material from a clean install and from an off-network location. Rotate/revoke the credential after the review window or if it is exposed. The reviewer environment must remain operational for the full review period.

## Privacy answers dependency

Issue #13 owns the privacy manifest and required-reason audit; the repository-side manifest (`HermesFleetApp/PrivacyInfo.xcprivacy`) has landed on `main`, and the remaining #13 acceptance items are App Store Connect reconciliation against the shipping RC. Do not infer App Store Connect privacy answers from this draft. After the #13 audit of the shipping RC and dependencies, reconcile the final answers with actual collection/transmission, required-reason APIs, the privacy policy URL, and the exact build submitted for review.

## Export compliance confirmation

The repository snapshot declares `ITSAppUsesNonExemptEncryption = false` in
`HermesFleetApp/Info.plist`. [TONY: CONFIRM THIS IS TRUE FOR THE FINAL RC AND COMPLETE APP STORE CONNECT EXPORT-COMPLIANCE QUESTIONS; DO NOT RELY ON THIS DRAFT WITHOUT HUMAN REVIEW.]

## Pre-submission checklist

- [ ] All `[TONY: ...]` placeholders are resolved in App Store Connect.
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
