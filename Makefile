# Hermes Fleet — local development validation targets.
#
# For quick iteration while developing, the targets below are the fast local
# loop. The authoritative broad repository/CI validation gate is
# scripts/c1_ci_validate.sh (XcodeGen generation + drift gate, package tests,
# hosted unit tests, simulator UI suites, module-boundary enforcement,
# public-safety residue guard, and gitleaks) — use `make ci` or run the
# script directly before opening a pull request.
PROJECT := HermesFleetApp
DEST := platform=iOS Simulator,name=iPhone 17 Pro,OS=latest
DD := build/DerivedData
# SwiftStreamingMarkdown v0.7.0 brings the reviewed Equatable macro through
# its package graph. Headless/local xcodebuild has no approval dialog, so use
# the same explicit trust bypass as the canonical CI phase scripts.
XCODEBUILD_FLAGS := -skipMacroValidation

.PHONY: generate build test test-core validate dev-check ci clean

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

## Fast local development loop (Dev Loop v2): static guards -> simulator build
## -> package tests -> focused UI suites selected from the working diff.
## Never runs the complete UI matrix; the merge queue runs the full C1.
dev-check:
	bash scripts/dev_check.sh

## Authoritative broad repository/CI validation gate (wraps scripts/c1_ci_validate.sh).
ci:
	bash scripts/c1_ci_validate.sh

clean:
	rm -rf build $(PROJECT).xcodeproj Packages/*/.build
