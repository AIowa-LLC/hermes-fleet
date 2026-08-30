#!/bin/bash
# U3 package regression — swift test for every package layer (host).
# Run with: bash scripts/u3_package_tests.sh
set -u
cd "$(dirname "$0")/.."

note() { printf '\n=== %s ===\n' "$1"; }

note "FleetCore"
(cd Packages/FleetCore && swift test) 2>&1 | grep -E 'Executed|error:|failed' | tail -8

note "FleetNetworking"
(cd Packages/FleetNetworking && swift test) 2>&1 | grep -E 'Executed|error:|failed' | tail -8

note "FleetSecurity"
(cd Packages/FleetSecurity && swift test) 2>&1 | grep -E 'Executed|error:|failed' | tail -8

note "FleetPersistence"
(cd Packages/FleetPersistence && swift test) 2>&1 | grep -E 'Executed|error:|failed' | tail -8

echo "=== done ==="
