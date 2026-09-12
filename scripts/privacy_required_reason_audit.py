#!/usr/bin/env python3
"""Audit Apple required-reason API families used by Fleet production Swift.

The API table mirrors Apple's current NSPrivacyAccessedAPIType documentation.
The scanner deliberately operates on the app and local package Sources trees
only; tests, comments, strings, and derived products are not app-owned call
sites.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

APPLE_REQUIRED_REASON_API_DOC = (
    "https://developer.apple.com/documentation/bundleresources/"
    "app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype"
)

# Keep this table explicit. Some APIs intentionally map to more than one
# Apple category (for example getattrlist), so they appear in each applicable
# family. lstat and fstatat were reviewed against the current Apple table and
# are intentionally absent because Apple does not list them there.
API_FAMILIES: dict[str, tuple[str, ...]] = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ("UserDefaults",),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        "creationDate",
        "modificationDate",
        "fileModificationDate",
        "contentModificationDateKey",
        "creationDateKey",
        "getattrlist",
        "getattrlistbulk",
        "fgetattrlist",
        "stat",
        "fstat",
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        "systemUptime",
        "mach_absolute_time",
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "volumeAvailableCapacityKey",
        "volumeAvailableCapacityForImportantUsageKey",
        "volumeAvailableCapacityForOpportunisticUsageKey",
        "volumeTotalCapacityKey",
        "systemFreeSize",
        "systemSize",
        "statfs",
        "statvfs",
        "fstatfs",
        "fstatvfs",
        "getattrlist",
        "fgetattrlist",
        "getattrlistat",
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ("activeInputModes",),
}

_PATTERNS = {
    category: re.compile(
        r"\b(?P<api>" + "|".join(sorted(apis, key=len, reverse=True)) + r")\b"
    )
    for category, apis in API_FAMILIES.items()
}

# Preserve line breaks while blanking comments and string literals. This keeps
# diagnostics useful and prevents prose, fixture strings, or user-facing copy
# from becoming false API call sites.
_NON_CODE = re.compile(
    r"//[^\n]*|/\*.*?\*/|\"\"\"(?:\\.|(?!\"\"\").)*\"\"\"|\"(?:\\.|[^\"\\])*\"",
    re.DOTALL,
)
_LOCAL_FUNCTION = re.compile(r"\bfunc\s+(?P<api>[A-Za-z_][A-Za-z0-9_]*)\s*\(")


def _blank_non_code(source: str) -> str:
    def blank(match: re.Match[str]) -> str:
        return "".join("\n" if char == "\n" else " " for char in match.group(0))

    return _NON_CODE.sub(blank, source)


def _source_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix == ".swift":
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(path.rglob("*.swift")))
    return sorted(set(files))


def scan(paths: list[Path]) -> dict[str, list[dict[str, object]]]:
    found = {category: [] for category in API_FAMILIES}
    for path in _source_files(paths):
        code = _blank_non_code(path.read_text(encoding="utf-8"))
        locally_declared = {
            match.group("api") for match in _LOCAL_FUNCTION.finditer(code)
        }
        for category, pattern in _PATTERNS.items():
            for match in pattern.finditer(code):
                # A local helper shadows an unqualified POSIX-style function
                # name. Do not turn an app helper such as `func stat(...)`
                # into a Disk/File Timestamp finding.
                if match.group("api") in locally_declared:
                    continue
                found[category].append(
                    {
                        "api": match.group("api"),
                        "path": str(path),
                        "line": code.count("\n", 0, match.start()) + 1,
                    }
                )
    return found


def _default_sources(repo: Path) -> list[Path]:
    return [repo / "HermesFleetApp", *sorted((repo / "Packages").glob("*/Sources"))]


def _declared_categories(manifest: Path) -> set[str]:
    with manifest.open("rb") as stream:
        value = plistlib.load(stream)
    return {
        entry["NSPrivacyAccessedAPIType"]
        for entry in value["NSPrivacyAccessedAPITypes"]
    }


def _print_text(found: dict[str, list[dict[str, object]]]) -> None:
    for category, hits in found.items():
        if not hits:
            print(f"  {category}: no production hits; no declaration")
            continue
        print(f"  {category}: {len(hits)} production API hits")
        for hit in hits:
            print(f"    {hit['api']}: {hit['path']}:{hit['line']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("HermesFleetApp/PrivacyInfo.xcprivacy"))
    parser.add_argument("--source", type=Path, action="append", dest="sources")
    parser.add_argument("--scan-only", action="store_true")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args()

    repo = Path.cwd()
    sources = args.sources if args.sources else _default_sources(repo)
    found = scan(sources)

    if args.format == "json":
        print(json.dumps({"categories": found}, sort_keys=True))
    else:
        print(f"Required-reason API source: {APPLE_REQUIRED_REASON_API_DOC}")
        _print_text(found)

    if args.scan_only:
        return 0

    if not args.manifest.is_file():
        print(f"Required-reason audit FAILED: missing manifest {args.manifest}", file=sys.stderr)
        return 1
    detected = {category for category, hits in found.items() if hits}
    declared = _declared_categories(args.manifest)
    if detected != declared:
        print("Required-reason audit FAILED: detected and declared categories differ", file=sys.stderr)
        print(f"  detected: {sorted(detected)}", file=sys.stderr)
        print(f"  declared: {sorted(declared)}", file=sys.stderr)
        return 1
    print("Required-reason API audit: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
