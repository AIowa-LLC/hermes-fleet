# Hermes Fleet iOS — M0 validation commands.
PROJECT := HermesFleetApp
DEST := platform=iOS Simulator,name=iPhone 17 Pro,OS=latest
DD := build/DerivedData

.PHONY: generate build test test-core validate clean

## Regenerate the Xcode project from project.yml (single source of truth).
generate:
	xcodegen generate

## Build the app for the iOS Simulator.
build:
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -destination '$(DEST)' -derivedDataPath $(DD) build

## Run the hosted unit tests on the iOS Simulator.
test:
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -destination '$(DEST)' -derivedDataPath $(DD) test

## Run FleetCore's own package tests on the host (fast, pure-domain).
test-core:
	cd Packages/FleetCore && swift test

## Full M0 validation: generate -> build -> simulator tests -> package tests.
validate: generate build test test-core

clean:
	rm -rf build $(PROJECT).xcodeproj Packages/*/.build
