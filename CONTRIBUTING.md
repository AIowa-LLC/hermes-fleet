# Contributing to Hermes Fleet

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent deployments. Contributions should preserve its direct-to-gateway architecture, explicit trust boundaries, and native iOS behavior.

## Development setup

You will need:

- macOS with Xcode 26.x
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- an iOS 26 simulator or compatible device
- [gitleaks](https://github.com/gitleaks/gitleaks) for the full validation gate

Generate the Xcode project from the repository root:

```sh
xcodegen generate
```

`project.yml` is the project source of truth. Do not hand-edit `project.pbxproj`.

## Build and test

```sh
make build
make test
make test-core
make validate
bash scripts/public_safety_guard.sh
gitleaks detect --source . --no-git
```

Run focused tests while iterating, then run the broadest relevant validation before opening a pull request.

Live gateway, physical-device, signing, LAN, and tailnet checks are environmental tests. Ordinary contributions must not depend on a maintainer's private infrastructure.

## Pull requests

Keep pull requests focused and explain:

- what changed
- why the change is needed
- user-visible or architectural impact
- validation performed
- known limitations or follow-up work

If `project.yml` changes, include the regenerated Xcode project in the same pull request.

## Privacy and test data

Do not include real credentials, tokens, private endpoints, hostnames, device identifiers, signing identifiers, personal filesystem paths, or private infrastructure details in source, fixtures, screenshots, logs, documentation, or commit messages.

Use clearly synthetic examples and deterministic test doubles.

## Bugs and feature requests

Use the repository issue templates for reproducible bugs and feature proposals. Security vulnerabilities should be reported privately according to `SECURITY.md`, not through a public issue.
