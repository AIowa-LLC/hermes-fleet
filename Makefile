# Hermes Fleet — local development validation targets.
#
# Use the smallest relevant tests while iterating, then `make dev-check`.
# Required PR validation and exact merge-candidate checks follow Dev Loop v3
# in docs/dev-loop.md. `make ci` is the broad local validation lane, not an
# unconditional prerequisite to opening every focused pull request.
# Shared-layer changes still require the broader coverage selected by policy.
PROJECT := HermesFleetApp
# Simulator destination: HERMES_FLEET_SIM_UDID, then this worktree's lane
# simulator when HERMES_FLEET_LANE_SIM=1, else the named default below. The
# precedence lives in scripts/sim_destination.sh (docs/DEVELOPMENT.md). Expanded
# lazily so targets that never build do not create a simulator. Override with
# `make test DEST='platform=iOS Simulator,...'`.
DEFAULT_DEST := platform=iOS Simulator,name=iPhone 17 Pro,OS=latest
DEST = $(shell bash scripts/sim_destination.sh iphone --default-dest '$(DEFAULT_DEST)')
DD := build/DerivedData
# SwiftStreamingMarkdown v0.7.0 brings the reviewed Equatable macro through
# its package graph. Headless/local xcodebuild has no approval dialog, so use
# the same explicit trust bypass as the canonical CI phase scripts.
XCODEBUILD_FLAGS := -skipMacroValidation

.PHONY: generate build test test-core validate dev-check ci release-preflight clean

## Regenerate the Xcode project from project.yml (single source of truth).
generate:
	xcodegen generate

## Build the app for the iOS Simulator.
build:
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -destination '$(DEST)' -derivedDataPath $(DD) $(XCODEBUILD_FLAGS) build

## Run the hosted unit tests on the iOS Simulator.
test:
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -destination '$(DEST)' -derivedDataPath $(DD) $(XCODEBUILD_FLAGS) test

## Run FleetCore's own package tests on the host (fast, pure-domain).
test-core:
	cd Packages/FleetCore && swift test

## Fast local development validation: generate -> build -> simulator unit tests -> package tests.
## Not the full repository gate — run `make ci` for that.
validate: generate build test test-core

## Fast local development loop (Dev Loop v3): static guards -> simulator build
## -> package tests -> focused UI suites selected from the working diff.
## PR/merge coverage and critical smoke follow docs/dev-loop.md; broad shared
## changes still select broader coverage. Use `make ci` for the broad local lane.
dev-check:
	bash scripts/dev_check.sh

## Authoritative broad repository/CI validation gate (wraps scripts/c1_ci_validate.sh).
ci:
	bash scripts/c1_ci_validate.sh

## Deterministic SHA-pinned Release/archive preflight; signing is required by default.
## Usage: make release-preflight SHA=$$(git rev-parse HEAD)
release-preflight:
	@test -n "$(SHA)" || (echo "usage: make release-preflight SHA=$$(git rev-parse HEAD)" >&2; exit 2)
	bash scripts/release_preflight.sh --sha "$(SHA)"

clean:
	rm -rf build $(PROJECT).xcodeproj Packages/*/.build
