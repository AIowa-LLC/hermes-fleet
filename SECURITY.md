# Security Policy

## Supported code

Hermes Fleet is under active development. Security fixes are applied to the current `main` branch. Older commits and local forks are not guaranteed to receive backports.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion, pull request, screenshot, or log.

Use GitHub's private vulnerability reporting for this repository when it is available. If that option is unavailable, contact an AIowa LLC maintainer privately through a published contact method before sharing technical details publicly.

A useful report includes:

- affected component and version or commit
- reproduction steps
- expected and observed behavior
- security impact
- a minimal redacted proof of concept when appropriate

Do not send live credentials, tokens, private endpoints, personal device data, or unrelated user information.

## Security model

Hermes Fleet connects directly to Hermes infrastructure selected by the user. It is not a central credential relay and does not require a shared AIowa operator account.

The project is designed around these boundaries:

- credentials and tokens are stored in the platform Keychain rather than source files
- cached application data is non-secret and stored separately from credentials
- gateway endpoints are normalized and sensitive URL material is rejected or redacted
- TLS-protected endpoints are preferred, especially outside trusted local networks
- local biometric or passcode protection reduces casual access but does not replace device security, gateway authentication, authorization, or transport security
- unsupported or malformed security-sensitive states should fail closed rather than invent a permissive fallback

## Handling accidental secret exposure

If a credential or private key is discovered in a checkout, log, artifact, or published history:

1. stop using the credential
2. rotate or revoke it at the issuing system
3. report the exposure privately
4. remove the material from active source and artifacts
5. assess whether history or downstream copies also require remediation

Repository cleanup does not make an exposed credential safe again. Rotation is the primary containment action.
