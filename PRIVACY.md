# Hermes Fleet Privacy Policy

Last updated: 2026-09-19

Hermes Fleet is an iOS client for Hermes Agent gateways that the person using
the app selects and controls. This policy describes the behavior of the
shipping client; a connected gateway may have its own privacy policy and data
retention rules.

## Data Hermes Fleet handles

- Gateway addresses, display names, usernames, and connection preferences are
  stored on the device so the app can reconnect to gateways the user has
  configured.
- Gateway credentials and short-lived connection tokens are stored in the
  iOS Keychain. They are not stored in the app's ordinary cache.
- Conversation and fleet snapshots may be cached locally to make recently
  viewed screens useful during a temporary disconnect. These snapshots are
  device-local and are not sent to Hermes Fleet or an AIowa-operated service.
- If voice input is used, the app requests microphone and speech-recognition
  access. Speech recognition is required to run on the device; recognized text
  is submitted to the gateway only when the user sends it as a conversation
  prompt. Audio is not intentionally uploaded by Hermes Fleet.
- Attachments and message content are sent to the gateway selected by the user
  when the user explicitly submits them. Hermes Fleet does not sell this data
  or use it for advertising.

## Data we collect

Hermes Fleet does not include advertising identifiers, third-party analytics,
or a Hermes Fleet account. The app does not operate a central service that
receives gateway content. The official policy and terms documents are hosted at
hermes-fleet.aiowa.dev; the hosting operator may receive standard web-server
request information (such as IP address) when a document is opened, as may
GitHub when the user opens the support or repository links. GitHub's and the
host's own terms and privacy policies apply to those visits.

## Retention and deletion

Local cached fleet and conversation data remains on the device until it is
expired by the app's bounded cache policy or removed by the user through the
app's cache controls when available. Removing a saved gateway removes its
stored credential and gateway-local cached data. Deleting the app removes its
local data subject to iOS backup and device-management behavior. Data already
sent to a gateway is controlled by that gateway's operator and must be deleted
through the gateway's own controls.

## Security boundaries

Hermes Fleet is designed for direct, authenticated gateway connections. Users
should use an encrypted gateway endpoint for traffic that leaves the local
device, review the endpoint before saving a pairing payload, and never paste
credentials into a public issue or support request.

## Your choices

You control the data Hermes Fleet handles. You can revoke consent and
request deletion at any time by:

- Removing a gateway in the app (deletes its stored credential and
  gateway-local cached data immediately).
- Using Settings → Data & Storage → Delete Local Cache (removes cached
  conversations, roster snapshots, health history, and recent destinations;
  saved gateways and Keychain credentials are kept).
- Deleting the app (removes its local data, subject to iOS backup behavior).
- Contacting us through the support channel below to ask questions or
  request that we correct information we hold about you.

Data already sent to a gateway is controlled by that gateway's operator and
must be deleted through the gateway's own controls.

## Contact

For app support or privacy questions, use the project's public support issue
tracker: <https://github.com/AIowa-LLC/hermes-fleet/issues>. Do not include
credentials, private gateway addresses, pairing QR contents, or conversation
transcripts in a public issue.
