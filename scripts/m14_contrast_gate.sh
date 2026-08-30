#!/usr/bin/env bash
# M14 Visual Identity — contrast acceptance gate (bash entry point).
# Runs the WCAG contrast checker over the Black/White/Signal Red theme tokens.
set -euo pipefail
cd "$(dirname "$0")"
python3 m14_contrast_gate.py
