# ADR-0006: ATS policy for user-supplied gateway hosts

**Status:** Superseded

## Historical context

An earlier development configuration used host-specific App Transport Security exceptions for particular cleartext gateway addresses. That approach coupled the application bundle to maintainer infrastructure and did not scale to a public, user-configured client.

## Current decision

Hermes Fleet does not ship maintainer-specific raw-IP or tailnet host exceptions and does not ship a default gateway endpoint.

The application keeps local-network support in its Info.plist, but cleartext connectivity remains subject to iOS App Transport Security and platform networking rules.

For new deployments:

- prefer HTTPS/TLS-protected gateway endpoints
- do not add a maintainer's LAN, tailnet, or device-specific address to the public application configuration
- treat any future ATS exception as a narrowly scoped security decision that must be justified independently of one developer's network

## Consequences

The public app configuration is portable across users and does not encode a maintainer topology.

Some cleartext raw-IP configurations may require additional platform-specific handling or may be unsupported. The preferred resolution is a secure gateway endpoint rather than a growing list of bundled host exceptions.
