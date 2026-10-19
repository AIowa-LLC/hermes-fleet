#!/usr/bin/env python3
"""Inspect only the local Dev export produced by fleet_dev_build.sh."""
import json
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path
from fleet_dev_guard import BUNDLE, app, entitlements, export_options, require, settings
from release_artifact_inspect import inspect_profile, parse_codesign_display, run


def inspect(out, build):
    root = Path(__file__).resolve().parent.parent
    export_options(root / 'Config/FleetDevExportOptions.plist')
    resolved = settings(json.loads((out / 'settings.json').read_text()), build)
    team = resolved.get('DEVELOPMENT_TEAM', '')
    require(bool(team), 'Dev export requires an existing selected team')
    ipas = list((out / 'export').glob('*.ipa'))
    require(len(ipas) == 1, 'export must produce exactly one IPA')
    extracted = out / 'ipa-inspection'
    require(not extracted.exists(), 'inspection directory already exists; preserve prior evidence')
    with zipfile.ZipFile(ipas[0]) as archive:
        for name in archive.namelist():
            path = Path(name)
            require(not path.is_absolute() and '..' not in path.parts, 'unsafe IPA member')
        archive.extractall(extracted)
    apps = list((extracted / 'Payload').glob('*.app'))
    require(apps == [extracted / 'Payload/HermesFleetDev.app'], 'IPA must contain one Dev app')
    built = apps[0]
    sha = resolved.get('FLEET_DEV_SOURCE_SHA', '')
    require(bool(sha), 'resolved source provenance missing')
    app(built, build, sha, 'iPhoneOS')
    info = plistlib.loads((built / 'Info.plist').read_bytes())
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'wrong export platform')
    require(bool(info.get('DTXcode')) and bool(info.get('DTXcodeBuild')), 'missing toolchain provenance')
    # Reuse existing signature/profile primitives without its production-only
    # Payload/HermesFleetApp.app assertion. Do not change release tooling.
    run(['codesign', '--verify', '--deep', '--strict', str(built)], label='Dev IPA signature')
    display = run(['codesign', '-dvv', str(built)], label='Dev IPA signing metadata')
    authority, signed_team = parse_codesign_display(display.stdout + display.stderr)
    require(authority.startswith(('Apple Distribution:', 'iPhone Distribution:')), 'distribution authority required')
    require(signed_team == team, 'signed team mismatch')
    signed = run(['codesign', '-d', '--entitlements', ':-', str(built)], label='Dev IPA entitlements')
    e = plistlib.loads(signed.stdout.encode())
    entitlements(e)
    require(e.get('beta-reports-active') is True, 'App Store TestFlight beta entitlement required')
    require(e.get('application-identifier') == team + '.' + BUNDLE, 'signed application identity mismatch')
    require(e.get('com.apple.developer.team-identifier') == team, 'signed team entitlement mismatch')
    require(e.get('get-task-allow') is not True, 'distribution must disable debugging')
    inspect_profile(built / 'embedded.mobileprovision', expected_bundle=BUNDLE, expected_team=team)
    print('Dev IPA identity/signing: PASS; Apple validation/upload NOT RUN')


if __name__ == '__main__':
    try:
        inspect(Path(sys.argv[1]), sys.argv[2])
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError, TypeError) as e:
        print('FLEET-DEV-FAIL: ' + str(e), file=sys.stderr)
        sys.exit(1)
