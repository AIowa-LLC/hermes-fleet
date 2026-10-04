#!/usr/bin/env python3
"""Fail-closed Fleet Dev boundaries. No credentials or Apple mutations."""
import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

TARGET = 'HermesFleetDev'
BUNDLE = 'com.aiowa.hermesfleet.dev'
NAME = 'Hermes Fleet Dev'
SCHEME = 'hermes-fleet-dev'
VERSION = '0.1.0'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def source(root, sha):
    require(re.fullmatch('[0-9a-f]{40}', sha), 'explicit full lowercase SHA required')
    require(git(root, 'rev-parse', 'HEAD') == sha, 'SHA must equal HEAD')
    require(not git(root, 'status', '--porcelain=v1', '--untracked-files=all'), 'source must be clean')
    # Existing reviewed ancestry floor stays authoritative and unmodified.
    subprocess.run(['bash', str(root / 'scripts/release_lineage_guard.sh'), sha], check=True)
    subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', 'origin/main', sha], check=True)
    # XcodeGen recursively includes app source: ignored injection is still source.
    ignored = git(root, 'ls-files', '--others', '--ignored', '--exclude-standard', '--',
                  'HermesFleetApp', 'Config', 'Packages/*/Sources')
    require(not ignored, 'ignored files in build inputs are forbidden')
    project = (root / 'project.yml').read_text()
    require(len(re.findall(r'^  HermesFleetDev:\s*$', project, re.M)) == 2,
            'Dev target and scheme are not integrated in authoritative project.yml; coordinate shared ownership')
    # The package/shortcut identity integration must be present before archives.
    consumers = {
        'HermesFleetApp/FleetConversationShortcuts.swift': 'FleetAppIdentity.conversationURLScheme',
        'HermesFleetApp/FleetServiceGraph.swift': 'FleetAppIdentity.cacheDirectoryName',
        'Packages/FleetSecurity/Sources/FleetSecurity/KeychainCredentialStore.swift': 'FleetAppIdentity.keychainNamespace',
        'Packages/FleetSecurity/Sources/FleetSecurity/KeychainTokenStore.swift': 'FleetAppIdentity.keychainNamespace',
        'Packages/FleetSecurity/Sources/FleetSecurity/KeychainPinStore.swift': 'FleetAppIdentity.keychainNamespace',
    }
    for name, expression in consumers.items():
        require(expression in (root / name).read_text(), 'runtime isolation integration missing: ' + name)


def export_options(path):
    p = plistlib.loads(path.read_bytes())
    expected = {'destination': 'export', 'method': 'app-store-connect',
                'manageAppVersionAndBuildNumber': False, 'signingStyle': 'automatic',
                'testFlightInternalTestingOnly': True, 'uploadSymbols': False}
    require(p == expected and all(type(p[k]) is type(v) for k, v in expected.items()), 'only committed local internal-only export options are allowed')


def entitlements(p):
    # No shared groups/extensions/push in this initial lane. Adding any requires
    # a separately coordinated capability audit and expanded identity tests.
    require(not p.get('com.apple.security.application-groups'), 'app groups require coordinated Dev isolation')
    require('aps-environment' not in p, 'push capability requires coordinated Dev isolation')
    allowed = {'application-identifier', 'com.apple.developer.team-identifier',
               'get-task-allow', 'keychain-access-groups'}
    require(set(p) <= allowed, 'unreviewed capability entitlement')
    appid = p.get('application-identifier')
    if appid:
        require(appid.endswith('.' + BUNDLE), 'production or foreign application identifier')
    groups = p.get('keychain-access-groups', [])
    require(not groups or (appid and groups == [appid]), 'shared keychain access group forbidden')


def settings(rows, build):
    require(len(rows) == 1 and rows[0].get('target') == TARGET, 'scheme must build only explicit Dev app target')
    s = rows[0]['buildSettings']
    expected = {'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE, 'PRODUCT_NAME': TARGET,
                'INFOPLIST_FILE': 'Config/FleetDevInfo.plist',
                'CODE_SIGN_ENTITLEMENTS': 'Config/FleetDev.entitlements',
                'INFOPLIST_KEY_CFBundleDisplayName': NAME, 'MARKETING_VERSION': VERSION,
                'CURRENT_PROJECT_VERSION': build, 'FLEET_DEV_BUILD': 'YES',
                'FLEET_URL_SCHEME': SCHEME, 'GENERATE_INFOPLIST_FILE': 'YES'}
    require(all(str(s.get(k)) == v for k, v in expected.items()), 'resolved Dev settings disagree with isolation contract')
    require('FLEET_DEV' in s.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split(), 'Dev compilation condition missing')
    require(not s.get('XCODE_XCCONFIG_FILE'), 'global xcconfig override forbidden')
    return s


def app_info(p, build):
    expected = {'CFBundleIdentifier': BUNDLE, 'CFBundleDisplayName': NAME,
                'CFBundleShortVersionString': VERSION, 'CFBundleVersion': build,
                'FleetDevBuild': True, 'FleetKeychainNamespace': BUNDLE,
                'FleetConversationURLScheme': SCHEME, 'FleetCacheDirectory': 'HermesFleetDevCache',
                'ITSAppUsesNonExemptEncryption': False}
    require(all(type(p.get(k)) is type(v) and p.get(k) == v for k, v in expected.items()),
            'built app is not the expected Dev identity/version')
    require(p.get('CFBundleURLTypes') == [{'CFBundleURLName': BUNDLE + '.conversation',
                                         'CFBundleURLSchemes': [SCHEME]}], 'URL scheme isolation failed')
    require(p.get('UIDeviceFamily') == [1, 2], 'Dev must support iPhone and iPad')
    require(p.get('MinimumOSVersion') == '26.0', 'deployment target drift')


def app(path, build, sha=None, platform=None):
    info = plistlib.loads((path / 'Info.plist').read_bytes())
    app_info(info, build)
    if sha:
        require(re.fullmatch('[0-9a-f]{40}', sha) and info.get('FleetDevSourceSHA') == sha, 'artifact source SHA mismatch')
    if platform:
        require(info.get('CFBundleSupportedPlatforms') == [platform], 'artifact platform mismatch')
        require(str(info.get('DTXcode', '')).startswith(('26', '27')) and bool(info.get('DTXcodeBuild')), 'unsupported or missing toolchain provenance')
    require((path / 'PrivacyInfo.xcprivacy').is_file(), 'privacy manifest missing')
    require(not (path / 'PlugIns').exists(), 'extensions require coordinated identity audit')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sha')
    p.add_argument('--settings', type=Path)
    p.add_argument('--app', type=Path)
    p.add_argument('--build', default='1')
    p.add_argument('--artifact-sha')
    p.add_argument('--platform', choices=['iPhoneOS', 'iPhoneSimulator'])
    a = p.parse_args()
    require(re.fullmatch(r'[1-9][0-9]{0,3}', a.build), 'Dev build must be explicit integer 1..9999; no auto-increment')
    root = Path(__file__).resolve().parent.parent
    export_options(root / 'Config/FleetDevExportOptions.plist')
    entitlements(plistlib.loads((root / 'Config/FleetDev.entitlements').read_bytes()))
    if a.sha:
        source(root, a.sha)
    if a.settings:
        s = settings(json.loads(a.settings.read_text()), a.build)
        if a.artifact_sha:
            require(s.get('FLEET_DEV_SOURCE_SHA') == a.artifact_sha, 'resolved source SHA mismatch')
    if a.app:
        app(a.app, a.build, a.artifact_sha, a.platform)
    require(a.sha or a.settings or a.app, 'specify source, settings, or built app to inspect')
    print('Fleet Dev boundary: PASS')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError, TypeError) as e:
        print('FLEET-DEV-FAIL: ' + str(e), file=sys.stderr)
        sys.exit(1)
