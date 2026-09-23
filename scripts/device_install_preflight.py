#!/usr/bin/env python3
"""Fail closed before a device install that would downgrade Hermes Fleet."""

import argparse
import json
import plistlib
import re
from pathlib import Path


BUNDLE_ID = "com.aiowa.hermesfleet"


def source_setting(project: str, name: str) -> str:
    matches = re.findall(rf"^\s*{re.escape(name)}:\s*(\S+)\s*$", project, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"project.yml must define exactly one {name}")
    return matches[0]


def build_number(value: object, label: str) -> int:
    if not isinstance(value, (str, int)) or not re.fullmatch(r"[0-9]+", str(value)):
        raise ValueError(f"{label} must be a decimal build number")
    return int(value)


def validate(project_path: Path, app_info_path: Path, apps_path: Path, require_installed_match: bool) -> str:
    project = project_path.read_text()
    expected_build = build_number(source_setting(project, "CURRENT_PROJECT_VERSION"), "source build")
    expected_version = source_setting(project, "MARKETING_VERSION")
    with app_info_path.open("rb") as handle:
        app = plistlib.load(handle)
    if app.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("built app bundle identifier does not match Hermes Fleet")
    candidate = build_number(app.get("CFBundleVersion"), "built app version")
    if candidate != expected_build or app.get("CFBundleShortVersionString") != expected_version:
        raise ValueError("built app version does not match project.yml")

    apps_doc = json.loads(apps_path.read_text())
    apps = apps_doc.get("result", {}).get("apps")
    if not isinstance(apps, list):
        raise ValueError("device app inventory is missing its apps list")
    installed = [item for item in apps if item.get("bundleIdentifier") == BUNDLE_ID]
    if len(installed) > 1:
        raise ValueError("device app inventory contains duplicate Hermes Fleet entries")
    if not installed:
        if require_installed_match:
            raise ValueError("Hermes Fleet is missing after install")
        return f"first install permitted: build {candidate}"

    previous = build_number(installed[0].get("bundleVersion"), "installed app version")
    if require_installed_match and previous != candidate:
        raise ValueError(f"installed build {previous} does not match built build {candidate}")
    if previous > candidate:
        raise ValueError(f"downgrade blocked: installed build {previous}, built build {candidate}")
    return f"in-place install permitted: build {previous} → {candidate}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("app_info", type=Path)
    parser.add_argument("device_apps", type=Path)
    parser.add_argument("--require-installed-match", action="store_true")
    args = parser.parse_args()
    try:
        print(validate(args.project, args.app_info, args.device_apps, args.require_installed_match))
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"DEVICE INSTALL BLOCKED: {error}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
