# Security Policy

## Reporting a vulnerability

Please do not report security vulnerabilities in a public issue. Open a private
security advisory for this repository when GitHub enables that feature, or
contact the maintainers through the private contact channel listed by the
repository owner. Include enough detail to reproduce the issue, but do not
include live credentials, tokens, private endpoints, or personal device data.

## Scope and expectations

Hermes Fleet is an iPhone-native control plane for user-owned Hermes Agent
installations. Reports about credential handling, authorization boundaries,
transport security, Keychain storage, data redaction, or local app-lock
behavior are especially valuable. Please allow reasonable time for
investigation and coordinated disclosure before public discussion.

## Protect credentials and personal data

Never commit or paste passwords, bearer tokens, API keys, private keys,
provisioning material, device identifiers, private IP addresses, hostnames, or
local filesystem paths. Use synthetic fixtures and placeholders in tests.

Gateway credentials are intended to be stored in the platform Keychain rather
than source files or logs. The app should redact sensitive URL components and
avoid printing credentials. If you find a credential in a checkout, stop using
it and report it privately so the owner can rotate it.

## Security model

Fleet connects directly to Hermes infrastructure selected by the user. It is
not a central AIowa credential relay and does not require a shared central
operator account. Users should prefer TLS-protected gateway endpoints and
should treat cleartext or untrusted networks as unsafe.

Local biometric and passcode protections reduce casual access to the app on a
device; they do not replace secure device configuration, gateway
authentication, authorization, or TLS. Do not interpret the app's local lock
as a guarantee that a compromised device or gateway is safe.
