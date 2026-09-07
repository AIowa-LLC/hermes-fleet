# Hermes Fleet

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent deployments. It connects directly to gateways selected by the user so fleet state, conversations, controls, and credentials stay between the phone and the user's Hermes infrastructure.

## Status

Hermes Fleet is under active development. The current project targets **iOS 26**, uses **Swift 6**, and is generated from `project.yml` with XcodeGen.

This repository contains source code and development tooling. It does not require an AIowa-hosted relay or shared operator account.

## Capabilities

Current surfaces include:

- multi-gateway registration, connection state, health, and fleet roster
- bot and session discovery across configured gateways
- streaming conversations with reconnect and replay handling
- gateway authentication and Keychain-backed credential storage
- approvals, session controls, model selection, context information, cron, and skills
- read-only Kanban visibility, memory graph, and Projects browsing
- attachments, message reactions, and on-device voice input/output

Some features depend on methods exposed by the connected Hermes gateway version. Unsupported capabilities should fail closed or remain unavailable rather than fabricate state.

## Architecture

```text
FleetCore          domain models, policies, and cross-module seams
   ▲
   ├─ FleetNetworking   JSON-RPC/WebSocket transport and gateway clients
   ├─ FleetSecurity     Keychain-backed credentials, tokens, and trust pins
   ├─ FleetPersistence  SwiftData non-secret cache and snapshots
   └─ FleetUI           SwiftUI screens and view models

HermesFleetApp     composition root that wires concrete implementations
```

`FleetUI` does not import `FleetNetworking`. Transport abstractions live in `FleetCore`, and the app target is responsible for composition. See [`docs/architecture.md`](docs/architecture.md) for the current architecture and known design work.

## Requirements

- macOS with Xcode 26.x
- Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- an iOS 26 simulator or compatible device
- [gitleaks](https://github.com/gitleaks/gitleaks) for the full repository validation gate

## Build and test

The committed Xcode project is generated output. `project.yml` is the source of truth.

```sh
xcodegen generate
make build
make test
make test-core
make validate
```

For the repository safety gates:

```sh
bash scripts/public_safety_guard.sh
gitleaks detect --source . --no-git
```

The GitHub Actions workflow runs the repository's C1 validation script for source, project, test, and CI changes.

## Connecting a gateway

Gateway details are user-supplied. Hermes Fleet does not ship with a maintainer endpoint or shared credentials. Prefer TLS-protected endpoints, especially outside trusted local networks.

See [`docs/gateway-pairing.md`](docs/gateway-pairing.md) for manual and QR-assisted setup.

## Documentation

Start with [`docs/README.md`](docs/README.md).

- [`docs/architecture.md`](docs/architecture.md) - module boundaries, data flow, and architectural constraints
- [`docs/features.md`](docs/features.md) - current feature surfaces and important limitations
- [`docs/gateway-pairing.md`](docs/gateway-pairing.md) - gateway setup and QR pairing
- [`docs/adr/`](docs/adr/) - architectural decision records
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - development and pull request guidance
- [`SECURITY.md`](SECURITY.md) - security model and vulnerability reporting

## Security

Credentials belong in the platform Keychain, not source, logs, screenshots, fixtures, or documentation. Gateway endpoints are treated as origins and sensitive URL material is rejected or redacted at trust boundaries.

Please report vulnerabilities privately according to [`SECURITY.md`](SECURITY.md).

## License

Hermes Fleet is available under the [MIT License](LICENSE).
