#!/bin/bash
# Audit required-reason API call sites in the shipping app and local package
# sources. The table-driven Python scanner follows Apple's current API list;
# tests, docs, comments, and build artifacts are intentionally out of scope.
# The manifest validator then requires declarations to equal detected use.
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/privacy_manifest_validate.sh
python3 scripts/privacy_required_reason_audit.py
