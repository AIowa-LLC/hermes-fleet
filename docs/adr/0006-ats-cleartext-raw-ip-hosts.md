# ADR 0006: ATS cleartext exceptions for raw-IP gateway hosts

- Status: Accepted (P0-3, t_c4a93ba8)
- Date: 2026-08-31
- Context: live dogfood, http://192.168.50.37:9120 (LAN relay on Tony's Mac)

## Context

The app talks to developer-operated Hermes gateways over cleartext HTTP on
three classes of hosts:

1. Tailscale tailnet IP (`100.100.200.61`) — covered by an explicit
   `NSExceptionDomains` entry since the P3 LAN-gateway fix.
2. Loopback (`127.0.0.1`) — ATS-exempt, no config needed.
3. Raw RFC1918 LAN IPs (`http://192.168.50.37:9120`) — hit in live dogfood.

`NSAllowsLocalNetworking=true` does NOT cover raw LAN IPs: it only relaxes ATS
for unicast .local / Bonjour-resolved names. iOS therefore silently blocks
cleartext HTTP to `192.168.50.37` even though the backend is fully healthy
(curl replay: providers/login/ws-ticket 200, WS 101). There is no runtime
error surfaced to the user beyond a connection failure.

ATS is also the wrong layer to fix at runtime: `NSAppTransportSecurity` is
static Info.plist configuration; it cannot be toggled per saved gateway.

## Decision

1. Minimal fix now: add each raw-IP cleartext host as an explicit
   `NSExceptionDomains` entry in `HermesFleetApp/Info.plist`
   (`NSExceptionAllowsInsecureHTTPLoads=true`,
   `NSIncludesSubdomains=false`). Applied for `192.168.50.37`, keeping the
   existing `100.100.200.61` entry. Idempotent bash/PlistBuddy script:
   `scripts/p03_add_lan_ats_exception.sh`.
2. Rejected alternatives:
   - `NSAllowsArbitraryLoads=true` — disables ATS app-wide; strictly worse
     blast radius than named exceptions (App Review friction, no scoping).
   - Build-config whitelist of a LAN subnet — ATS has no subnet primitive;
     it would still expand to per-IP entries at build time, adding machinery
     without changing the plist semantics.
3. Known constraint (documented, not solved): a NEW raw-IP cleartext host
   requires a plist edit + rebuild. This is acceptable because gateway hosts
   are few, developer-controlled, and known at dogfood time. If the set grows,
   prefer TLS on the gateway rather than widening ATS.
4. The B2/S3 cleartext-warning flow is orthogonal and unchanged: it is a
   Swift-side `PrivateNetworkClassifier` decision in the Add-Gateway form
   (warn + explicit confirmation for http:// to non-private hosts), not an
   ATS behavior. ATS exceptions only remove the transport-layer block.

## Consequences

- App connects and renders the roster over `http://192.168.50.37:9120`.
- ATS violations remain scoped to two named developer hosts.
- Adding a new raw-IP cleartext gateway host is a deliberate, reviewed
  plist change (script provided), not a silent config drift.
