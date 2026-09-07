# Feature guide

Hermes Fleet exposes Hermes fleet and session controls in a native iOS interface. Availability can vary with the capabilities provided by a connected gateway.

## Fleet and gateways

- register, edit, test, and remove gateways
- multiple authentication strategies
- connection lifecycle and reconnect controls
- multi-gateway roster aggregation
- bot and session discovery
- per-gateway health information
- QR-assisted gateway pairing

## Conversations

- create and resume sessions
- stream assistant output and tool activity
- reconnect and recover missed events
- preserve cached conversation history for cold-start presentation
- approvals and per-session control surfaces
- model selection and context information
- steer, rename, and fork workflows where supported
- attachments and message reactions

Very long conversations use a bounded display window while retaining authoritative cached history separately.

## Management surfaces

Depending on gateway support, the app includes:

- cron management
- skills management
- read-only Kanban board visibility
- Projects browsing
- memory/learning graph browsing and supported mutations
- connection-health details

The Kanban surface is intentionally read-only in the current client.

## Voice

Voice input and spoken replies are implemented on the iOS device. Recognized text is submitted through the normal conversation path; the client does not invent a remote-audio gateway protocol when one is not available.

Speech-recognition behavior can vary by locale and platform capability.

## Security and privacy behavior

- credentials and tokens use Keychain-backed storage
- gateway endpoints are normalized at the registry boundary
- sensitive URL material is rejected or redacted
- private infrastructure should never be embedded in fixtures or documentation
- TLS-protected gateway endpoints are preferred

## Capability honesty

Hermes Fleet should not present unsupported gateway methods as available. Feature code should either:

- use a verified gateway capability, or
- fail closed with an explicit unavailable/error state

Simulator fixtures may demonstrate UI behavior, but they do not prove that a particular live gateway deployment exposes the same capability.
