# External reviewer package

This package is for an isolated, reviewer-safe Hermes gateway used during TestFlight App Review. It is not a production Fleet environment. Do not use a maintainer gateway, personal conversations, business data, private LAN/tailnet addresses, or long-lived administrator credentials.

## Before giving Apple access

The operator must provision a disposable or narrowly scoped Hermes gateway that is:

- reachable from outside the maintainer network over an encrypted, supported path;
- isolated from personal and business data;
- limited to harmless demonstration capabilities;
- stable for the complete review window; and
- backed by credentials that can be revoked or rotated afterward.

Record the endpoint and temporary access material in App Store Connect's private review-access fields only. Never commit credentials, QR images, access tokens, private hostnames, or setup artifacts to this repository. If a QR code is used, generate it from a fresh scoped credential and send it through Apple's private submission flow.

The app's supported QR payload is documented in [`docs/gateway-pairing.md`](../gateway-pairing.md). Review the decoded endpoint and username before saving; do not paste a secret into a public issue or log.

## Apple review walkthrough

Use a clean install of the exact submitted build. The labels may vary slightly by build, but the sequence is:

1. Launch Hermes Fleet.
2. Open **Gateways** and choose **Add Gateway**. Either enter the supplied reviewer endpoint and scoped credentials, or choose **Scan Pairing Code** and scan the private QR supplied in App Store Connect.
3. Review the populated endpoint and authentication fields, then save. Authenticate when prompted. The app stores gateway credentials in the iOS Keychain; it does not require a Fleet account.
4. Wait for the gateway to become connected and for the roster/health state to settle. A healthy result shows the supplied demo gateway and its available profiles/bots rather than an empty or guessed roster.
5. Open a supplied profile's session from the roster. If no session is supplied, create a new chat session from the profile. Confirm the gateway/profile identity before sending anything.
6. Send a harmless prompt such as: `Reply with the word READY and a short sentence describing this demo environment.` Observe the response arriving incrementally as streamed text, then confirm the completed reply.
7. Optionally open the **Skills** surface and invoke one pre-installed, read-only demo skill (for example, a skill that reports a static capability or formats text). Do not run shell, file mutation, network administration, scheduling, payment, or account-management actions.
8. Open bot/profile inspection to show the profile description, model/session state, and available capabilities. Capability lists are gateway-provided; unavailable methods should remain unavailable rather than being treated as app failure.
9. Stop there. Do not add a personal gateway, import private data, or retain the reviewer credential beyond the review session.

If the roster is initially loading, wait for the connection state to update before retrying the roster. If the demo gateway is unavailable, do not substitute a maintainer endpoint; contact the submission operator through the private review channel.

## Reviewer-environment requirements

The environment owner should verify, before submission and again after any credential rotation:

- a clean profile/database with synthetic bots, conversations, and files only;
- least-privilege credentials scoped to this review;
- TLS or another supported encrypted/authenticated access path;
- no production integrations, personal data, destructive tools, privileged administration, or billing actions;
- a known harmless skill for step 7;
- gateway health, roster, session creation, streaming replies, and bot inspection;
- off-network reachability using the same endpoint Apple receives; and
- revocation/rotation and an owner on call for the review window.

The repository preflight script can check metadata and local export-compliance declarations, but it cannot prove that a private endpoint, credential, QR code, or backend is operational. Those checks remain an operator responsibility.

## Intentionally restricted capabilities

The reviewer environment intentionally does not promise access to personal or business Hermes data, production gateways, privileged shell/file operations, destructive administration, account or billing changes, or private network resources. Cross-gateway operations, attachments, voice behavior, scheduling, and other surfaces may be unavailable when the demo gateway does not advertise the required capability. These restrictions are safety boundaries, not missing review setup. Fleet is the native iPhone control plane; compute and gateway capabilities remain owned by the connected Hermes gateway.

## Privacy and App Store Connect coordination

Privacy answers must describe the exact RC and its included dependencies, not this walkthrough's assumptions. The dedicated privacy-manifest work for issue #13 is a dependency and is intentionally not implemented here. Before external submission, the release owner must reconcile that audit with App Store Connect answers, the privacy policy, and the final build.

The app's current source declares `ITSAppUsesNonExemptEncryption` as false in `HermesFleetApp/Info.plist`; the release owner must confirm that declaration remains truthful for the RC and obtain the required human export-compliance confirmation.

## Incident and rotation procedure

If access leaks or the endpoint becomes unhealthy, revoke the reviewer credential, rotate the demo access path, repair or replace the isolated environment, and update Apple's private review-access fields before submission/review. Do not publish troubleshooting output containing endpoint details, usernames, QR payloads, cookies, or tokens.
