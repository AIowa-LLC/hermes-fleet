#!/usr/bin/env python3
"""Extension-safe module boundary guard (F3).

Rules (see AGENTS.md "Module boundary" and docs/extension-kit.md):

1. FleetClientKit sources may import only Foundation, Security, OSLog,
   CryptoKit, FleetCore, and FleetSecurity. In particular never FleetNetworking,
   FleetUI, FleetPersistence, SwiftUI, UIKit, SwiftData, or app code.
2. FleetClientKit's Package.swift may depend only on ../FleetCore and
   ../FleetSecurity.
3. Every extension target in project.yml (type app-extension or
   extensionkit-extension) may link only the packages FleetCore, FleetSecurity,
   and FleetClientKit, and its source files may not import FleetNetworking,
   FleetUI, FleetPersistence, or HermesFleetApp code. (No extension targets
   exist yet; the rule is enforced as soon as R3/R5/R6 add them.)

Usage: extension_boundary_guard.py [ROOT]   (default: the repository root)
Exit 0 when every rule holds, 1 with one line per violation otherwise.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

KIT_ALLOWED_IMPORTS = {
    "Foundation", "Security", "OSLog", "CryptoKit", "FleetCore", "FleetSecurity",
}
KIT_ALLOWED_PACKAGE_PATHS = {"../FleetCore", "../FleetSecurity"}
EXTENSION_ALLOWED_PACKAGES = {"FleetCore", "FleetSecurity", "FleetClientKit"}
EXTENSION_FORBIDDEN_IMPORTS = {
    "FleetNetworking", "FleetUI", "FleetPersistence", "HermesFleetApp",
}
EXTENSION_TYPES = {"app-extension", "extensionkit-extension"}

IMPORT_RE = re.compile(
    r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)"
)


def swift_imports(path: Path) -> list[tuple[int, str]]:
    found = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = IMPORT_RE.match(line)
        if match:
            found.append((number, match.group(1)))
    return found


def swift_files(directory: Path) -> list[Path]:
    if directory.is_file() and directory.suffix == ".swift":
        return [directory]
    if not directory.is_dir():
        return []
    return sorted(directory.rglob("*.swift"))


def check_kit(root: Path) -> list[str]:
    violations: list[str] = []
    kit = root / "Packages" / "FleetClientKit"
    if not kit.is_dir():
        return violations
    for path in swift_files(kit / "Sources"):
        for number, module in swift_imports(path):
            if module not in KIT_ALLOWED_IMPORTS:
                violations.append(
                    f"FleetClientKit source {path.relative_to(root)}:{number} imports '{module}' "
                    f"(allowed: {', '.join(sorted(KIT_ALLOWED_IMPORTS))})"
                )
    manifest = kit / "Package.swift"
    if manifest.is_file():
        for path in re.findall(r'\.package\(\s*path:\s*"([^"]+)"', manifest.read_text(encoding="utf-8")):
            if path not in KIT_ALLOWED_PACKAGE_PATHS:
                violations.append(
                    f"FleetClientKit Package.swift depends on '{path}' "
                    f"(allowed: {', '.join(sorted(KIT_ALLOWED_PACKAGE_PATHS))})"
                )
    return violations


def parse_targets(project_yml: Path) -> dict[str, dict[str, object]]:
    """Minimal, dependency-free reader for the `targets:` block of project.yml.

    Understands exactly the shapes XcodeGen files here use: a target name at
    indent 2, `type:` / list-valued `sources:` / `dependencies:` at indent 4.
    """
    targets: dict[str, dict[str, object]] = {}
    in_targets = False
    current: dict[str, object] | None = None
    section: str | None = None
    for raw in project_yml.read_text(encoding="utf-8").splitlines():
        line = raw.split(" #")[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        text = line.strip()
        if indent == 0:
            in_targets = text == "targets:"
            current = None
            section = None
            continue
        if not in_targets:
            continue
        if indent == 2 and text.endswith(":"):
            current = {"type": "", "sources": [], "packages": [], "targets": []}
            targets[text[:-1]] = current
            section = None
            continue
        if current is None:
            continue
        if indent == 4:
            key, _, value = text.partition(":")
            value = value.strip()
            if key == "type":
                current["type"] = value
            section = key if key in {"sources", "dependencies"} else None
            continue
        if section and text.startswith("- "):
            item = text[2:].strip()
            if section == "sources":
                if item.startswith("path:"):
                    item = item.split(":", 1)[1].strip()
                current["sources"].append(item)  # type: ignore[union-attr]
            elif section == "dependencies":
                key, _, value = item.partition(":")
                value = value.strip()
                if key == "package":
                    current["packages"].append(value)  # type: ignore[union-attr]
                elif key == "target":
                    current["targets"].append(value)  # type: ignore[union-attr]
    return targets


def check_extensions(root: Path) -> list[str]:
    violations: list[str] = []
    project_yml = root / "project.yml"
    if not project_yml.is_file():
        return violations
    for name, target in parse_targets(project_yml).items():
        if target["type"] not in EXTENSION_TYPES:
            continue
        for package in target["packages"]:  # type: ignore[union-attr]
            if package not in EXTENSION_ALLOWED_PACKAGES:
                violations.append(
                    f"extension target {name} links package '{package}' "
                    f"(allowed: {', '.join(sorted(EXTENSION_ALLOWED_PACKAGES))})"
                )
        for dependency in target["targets"]:  # type: ignore[union-attr]
            violations.append(
                f"extension target {name} depends on target '{dependency}' "
                "(extensions may not link app code)"
            )
        for source in target["sources"]:  # type: ignore[union-attr]
            for path in swift_files(root / source):
                for number, module in swift_imports(path):
                    if module in EXTENSION_FORBIDDEN_IMPORTS:
                        violations.append(
                            f"extension source {path.relative_to(root)}:{number} imports '{module}'"
                        )
    return violations


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parent.parent
    violations = check_kit(root) + check_extensions(root)
    if violations:
        for violation in violations:
            print(f"VIOLATION: {violation}")
        return 1
    print("extension boundary: FleetClientKit and extension targets respect the allow-lists")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
