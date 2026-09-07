# Contributing to Hermes Fleet

Hermes Fleet is a native iPhone control plane for user-owned Hermes Agent
installations. Contributions should preserve the thin, native, read-mostly
architecture and explicit identity and privilege boundaries.

## Prerequisites

- macOS with Xcode 26.x and an available iOS simulator
- Swift 6 toolchain
- [xcodegen](https://github.com/yonaskolb/XcodeGen)
- [gitleaks](https://github.com/gitleaks/gitleaks)

## Build and test

The generated Xcode project is derived from `project.yml`; never hand-edit the
project file. From the repository root:

```sh
xcodegen generate
make build
make test
make test-core
make validate
bash scripts/public_safety_guard.sh
gitleaks detect --source . --no-git
```

The CI workflow is the authoritative hosted validation path. Live gateway,
LAN, tailnet, device, signing, and deployment checks are opt-in local work and
must not be required for ordinary CI.

## Branches and pull requests

Use a focused branch and explain the user-visible or architectural reason for
the change. Include validation commands and results in the pull request. Do
not merge changes that require private infrastructure to reproduce unless the
private dependency is explicitly optional and documented.

Please do not include credentials, private endpoints, device identifiers,
personal filesystem paths, or real hostnames in fixtures, screenshots, logs,
docs, or commit messages. Use clearly synthetic values.

## Bugs and features

Use the issue templates for reproducible bugs and feature requests. For
security vulnerabilities, follow `SECURITY.md` instead of opening a public
issue.
