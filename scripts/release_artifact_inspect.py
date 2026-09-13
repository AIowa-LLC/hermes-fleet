#!/usr/bin/env python3
"""Inspect the signed IPA that will actually be sent to Apple.

This deliberately does not inspect the archive as a proxy for the exported
artifact. xcodebuild performs distribution signing while exporting, so the
IPA is the source of truth for the final signing, profile, entitlements, and
bundle metadata checks.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {message}")


def run(command: list[str], *, label: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        fail(f"{label} failed{': ' + details if details else ''}")
    return result


def load_plist(path: Path, *, label: str) -> dict:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        fail(f"{label} is not a valid plist: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a dictionary")
    return value


def parse_codesign_display(output: str) -> tuple[str, str]:
    authorities = re.findall(r"^Authority=(.*)$", output, flags=re.MULTILINE)
    identity = authorities[0].strip() if authorities else ""
    team_match = re.search(r"^TeamIdentifier=(.*)$", output, flags=re.MULTILINE)
    team = team_match.group(1).strip() if team_match else ""
    return identity, team


def inspect_profile(profile: Path, *, expected_bundle: str, expected_team: str) -> tuple[str, str]:
    decoded = run(["security", "cms", "-D", "-i", str(profile)], label="embedded provisioning profile decode")
    try:
        profile_plist = plistlib.loads(decoded.stdout.encode())
    except (plistlib.InvalidFileException, ValueError) as error:
        fail(f"embedded provisioning profile is not a valid plist: {error}")
    if not isinstance(profile_plist, dict):
        fail("embedded provisioning profile is not a dictionary")

    entitlements = profile_plist.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail("embedded provisioning profile has no Entitlements dictionary")

    profile_team = str(entitlements.get("com.apple.developer.team-identifier", ""))
    profile_app_id = str(entitlements.get("application-identifier", ""))
    expected_app_id = f"{expected_team}.{expected_bundle}"
    if profile_team != expected_team:
        fail(f"profile team identifier {profile_team!r}, expected {expected_team!r}")
    if profile_app_id != expected_app_id:
        fail(f"profile application identifier {profile_app_id!r}, expected {expected_app_id!r}")
    if "ProvisionedDevices" in profile_plist:
        fail("exported IPA contains a device-limited provisioning profile")
    if entitlements.get("get-task-allow") is True:
        fail("exported provisioning profile enables get-task-allow")
    if profile_plist.get("ProvisionsAllDevices") is True:
        fail("exported IPA contains an enterprise provisioning profile")
    if "ExpirationDate" not in profile_plist:
        fail("embedded provisioning profile has no expiration date")

    name = str(profile_plist.get("Name", "<unnamed>"))
    return name, profile_app_id


def inspect_ipa(
    ipa: Path,
    *,
    expected_bundle: str,
    expected_version: str,
    expected_build: str,
    expected_team: str,
    inspection_root: Path,
) -> None:
    if not ipa.is_file():
        fail(f"IPA does not exist: {ipa}")
    if inspection_root.exists():
        fail(f"inspection path already exists; choose a new output root: {inspection_root}")
    inspection_root.mkdir(parents=True)

    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        for name in names:
            path = Path(name)
            if path.is_absolute() or ".." in path.parts:
                fail("IPA contains an unsafe archive path")
        archive.extractall(inspection_root)

    payload = inspection_root / "Payload"
    apps = sorted(path for path in payload.glob("*.app") if path.is_dir())
    if apps != [payload / "HermesFleetApp.app"]:
        fail(f"IPA Payload apps are {[path.name for path in apps]!r}, expected ['HermesFleetApp.app']")
    app = apps[0]
    info = load_plist(app / "Info.plist", label="exported app Info.plist")

    expected = {
        "CFBundleIdentifier": expected_bundle,
        "CFBundleShortVersionString": expected_version,
        "CFBundleVersion": expected_build,
        "MinimumOSVersion": "26.0",
    }
    for key, value in expected.items():
        if str(info.get(key)) != value:
            fail(f"exported app {key}={info.get(key)!r}, expected {value!r}")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        fail(f"exported app platform metadata is {info.get('CFBundleSupportedPlatforms')!r}")
    if info.get("UIDeviceFamily") != [1, 2]:
        fail(f"exported app UIDeviceFamily={info.get('UIDeviceFamily')!r}, expected [1, 2]")
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        fail("exported app must declare ITSAppUsesNonExemptEncryption=false")
    privacy_manifest = app / "PrivacyInfo.xcprivacy"
    if not privacy_manifest.is_file():
        fail("exported IPA has no embedded PrivacyInfo.xcprivacy")

    run(["codesign", "--verify", "--deep", "--strict", str(app)], label="exported app code-sign verification")
    display = run(["codesign", "-dvv", str(app)], label="exported app code-sign metadata")
    identity, signed_team = parse_codesign_display(display.stderr + display.stdout)
    if not identity.startswith(("Apple Distribution:", "iPhone Distribution:")):
        fail(f"exported IPA signing authority is {identity or '<missing>'!r}, not a distribution identity")
    if signed_team != expected_team:
        fail(f"exported IPA team identifier {signed_team!r}, expected {expected_team!r}")

    entitlements_output = run(
        ["codesign", "-d", "--entitlements", "-", str(app)],
        label="exported app entitlements inspection",
    )
    if not entitlements_output.stdout.strip():
        fail("exported app has no readable signed entitlements")
    try:
        signed_entitlements = plistlib.loads(entitlements_output.stdout.encode())
    except (plistlib.InvalidFileException, ValueError) as error:
        fail(f"exported signed entitlements are not a valid plist: {error}")
    if not isinstance(signed_entitlements, dict):
        fail("exported signed entitlements are not a dictionary")
    expected_app_id = f"{expected_team}.{expected_bundle}"
    if signed_entitlements.get("application-identifier") != expected_app_id:
        fail("exported signed application-identifier does not match the bundle/team")
    if signed_entitlements.get("com.apple.developer.team-identifier") != expected_team:
        fail("exported signed team identifier does not match the release team")
    if signed_entitlements.get("get-task-allow") is True:
        fail("exported signed entitlements enable get-task-allow")

    profile = app / "embedded.mobileprovision"
    if not profile.is_file():
        fail("exported IPA has no embedded provisioning profile")
    profile_name, profile_app_id = inspect_profile(profile, expected_bundle=expected_bundle, expected_team=expected_team)

    print("Exported IPA inspection: PASS")
    print(f"  IPA: {ipa}")
    print(f"  bundle identifier: {expected_bundle}")
    print(f"  marketing version: {expected_version}")
    print(f"  build number: {expected_build}")
    print(f"  signing authority: {identity}")
    print(f"  team identifier: {signed_team}")
    print(f"  application identifier: {profile_app_id}")
    print(f"  provisioning profile: {profile_name}")
    print("  distribution posture: App Store profile; no device list; get-task-allow disabled")
    print("  export compliance: ITSAppUsesNonExemptEncryption=false")
    print("  embedded privacy manifest: present")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--expected-bundle-id", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--expected-team", required=True)
    parser.add_argument("--inspection-root", type=Path, required=True)
    args = parser.parse_args()
    inspect_ipa(
        args.ipa,
        expected_bundle=args.expected_bundle_id,
        expected_version=args.expected_version,
        expected_build=args.expected_build,
        expected_team=args.expected_team,
        inspection_root=args.inspection_root,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
