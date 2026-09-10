#!/bin/bash
# Issue #6 static guard: runtime FleetUI/app views must consume the active
# FleetThemeValues environment for product colors. Layout, typography, and
# semantic operational/status colors remain separate concerns.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
import sys

roots = [Path("Packages/FleetUI/Sources/FleetUI"), Path("HermesFleetApp")]
files = sorted(path for root in roots for path in root.rglob("*.swift"))

# These are palette-definition or legacy/semantic files. They are the source
# of truth, not consumers, so their platform colors are expected here.
definition_files = {
    Path("Packages/FleetUI/Sources/FleetUI/FleetTheme.swift"),
    Path("Packages/FleetUI/Sources/FleetUI/FleetThemePalette.swift"),
    Path("Packages/FleetUI/Sources/FleetUI/FleetAccent.swift"),
    Path("Packages/FleetUI/Sources/FleetUI/Components/FleetStatus.swift"),
}

# A camera frame is not a Fleet surface. The QR guidance/error capsules keep
# a black backing for guaranteed contrast over arbitrary live video.
camera_overlay_allow = {
    Path("Packages/FleetUI/Sources/FleetUI/GatewayPairingScannerView.swift")
}

palette_tokens = (
    "FleetTheme.accent",
    "FleetTheme.background",
    "FleetTheme.surface",
    "FleetTheme.surfaceElevated",
    "FleetTheme.surfaceIncreased",
    "FleetTheme.textPrimary",
    "FleetTheme.textSecondary",
    "FleetTheme.textMuted",
    "FleetTheme.border",
    "FleetTheme.borderColor",
)
platform_color_patterns = (
    r"Color\(uiColor:\s*\.(?:systemBackground|label|secondaryLabel|tertiaryLabel)\)",
    r"\bColor\.(?:black|white)\b",
    r"\.foregroundStyle\(\.(?:primary|secondary|tertiary)\)",
    r"\.tint\(\.(?:black|white)\)",
)

failures = []
for path in files:
    if path in definition_files:
        continue
    text = path.read_text()
    runtime = text.split("#Preview", 1)[0]
    for token in palette_tokens:
        for line_no, line in enumerate(runtime.splitlines(), 1):
            if token in line:
                failures.append(f"{path}:{line_no}: runtime uses {token}: {line.strip()}")
    for pattern in platform_color_patterns:
        for match in re.finditer(pattern, runtime):
            line_no = runtime.count("\n", 0, match.start()) + 1
            failures.append(f"{path}:{line_no}: runtime uses a hard-coded/system color: {match.group(0)}")

    if path not in camera_overlay_allow:
        for line_no, line in enumerate(runtime.splitlines(), 1):
            if ".background(.black.opacity" in line:
                failures.append(f"{path}:{line_no}: unclassified black camera overlay")

if failures:
    print("Theme call-site audit FAILED:")
    print("\n".join(f"  {failure}" for failure in failures))
    sys.exit(1)

print(f"Theme call-site audit passed ({len(files)} Swift files inspected).")
print("  Runtime product colors resolve through FleetThemeValues.")
print("  FleetTheme.swift/FleetThemePalette.swift own platform color definitions.")
print("  FleetStatus.swift owns semantic status colors independently of the palette.")
print("  GatewayPairingScannerView.swift black backing is limited to camera overlays.")
PY
