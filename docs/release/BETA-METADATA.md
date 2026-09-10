# TestFlight beta metadata — external review draft

This file is a ready-to-paste draft for the Hermes Fleet app record. Replace every `[TONY: ...]` item in App Store Connect before submission. Do not place demo credentials, QR payloads, private endpoints, or access tokens in this document.

## Beta App Description

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent gateways. Connect a gateway you control, see its available profiles and bots, open a conversation, and send prompts while the gateway performs the agent work. Fleet keeps gateway credentials in the iOS Keychain and connects directly to the gateway selected by the user; it does not require an AIowa-hosted relay or shared operator account.

The app supports gateway health and roster visibility, streaming chat, bot/profile inspection, approvals and session controls where the connected gateway advertises them, and additional gateway-owned surfaces such as skills. Available capabilities depend on the connected Hermes gateway version and its permissions. Unsupported or restricted capabilities remain unavailable rather than presenting fabricated state.

## Feedback Email

[TONY: ENTER THE MONITORED FEEDBACK EMAIL ADDRESS IN APP STORE CONNECT]

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

- First name: [TONY: ENTER REVIEW CONTACT FIRST NAME]
- Last name: [TONY: ENTER REVIEW CONTACT LAST NAME]
- Phone: [TONY: ENTER REVIEW CONTACT PHONE]
- Email: [TONY: ENTER REVIEW CONTACT EMAIL]

## Review notes

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent gateways. The app is not a standalone offline chat client: reviewers should connect to the supplied isolated demo environment.

Install the submitted build, open Gateways, and use the reviewer-safe endpoint and scoped credentials (or private QR pairing artifact) entered in App Store Connect's demo-access fields. Authenticate if prompted, wait for gateway and roster health, open or create a demo profile session, and send a harmless prompt such as "Reply with READY and a short sentence describing this demo environment." The response should stream into the conversation. Then inspect the bot/profile details and, if available, run the supplied read-only demo skill.

The demo environment contains synthetic data only. Production gateways, personal/business data, privileged shell or file operations, destructive administration, billing, and account-management actions are intentionally disabled. Capabilities vary with the gateway's advertised methods. The app stores credentials in the iOS Keychain and does not require a Fleet account.

## Demo access fields — private only

[TONY: IN APP STORE CONNECT, PROVIDE THE CURRENT REVIEWER-SAFE ENDPOINT AND TEMPORARY SCOPED CREDENTIAL OR QR SETUP ARTIFACT USING THE PRIVATE REVIEW-ACCESS FIELDS. NEVER COMMIT THEM HERE.]

Before submitting, verify the exact endpoint and access material from a clean install and from an off-network location. Rotate/revoke the credential after the review window or if it is exposed. The reviewer environment must remain operational for the full review period.

## Privacy answers dependency

Issue #13 owns the privacy manifest implementation and audit. Do not infer App Store Connect privacy answers from this draft. After #13's audit of the shipping RC and dependencies, reconcile the final answers with actual collection/transmission, required-reason APIs, the privacy policy URL, and the exact build submitted for review.

## Export compliance confirmation

The repository currently declares `ITSAppUsesNonExemptEncryption = false` in `HermesFleetApp/Info.plist`. [TONY: CONFIRM THIS IS TRUE FOR THE FINAL RC AND COMPLETE APP STORE CONNECT EXPORT-COMPLIANCE QUESTIONS; DO NOT RELY ON THIS DRAFT WITHOUT HUMAN REVIEW.]

## Pre-submission checklist

- [ ] All `[TONY: ...]` placeholders are resolved in App Store Connect.
- [ ] Feedback address and review contact are monitored for the review window.
- [ ] Privacy answers match the issue #13 audit and final RC.
- [ ] Privacy-policy URL is configured and reachable.
- [ ] Demo access is entered privately and tested from a clean install/off-network.
- [ ] No secret or private infrastructure detail was added to this repository.
- [ ] Export-compliance posture is human-confirmed for the final RC.
