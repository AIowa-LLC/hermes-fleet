#!/usr/bin/env python3
"""Synthetic guard regressions; no simulators, keychain, signing or accounts."""
import json
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
import shutil
import os
from pathlib import Path
from unittest.mock import patch
import fleet_dev_guard as guard
import fleet_dev_export_inspect as exported
import fleet_dev_test_result as result_guard

ROOT = Path(__file__).resolve().parent.parent


def fixture_info():
    p = plistlib.loads((ROOT / 'Config/FleetDevInfo.plist').read_bytes())
    p['FleetDevSourceSHA'] = 'a' * 40
    p.update(CFBundleIdentifier=guard.BUNDLE, CFBundleDisplayName=guard.NAME,
             CFBundleShortVersionString=guard.VERSION, CFBundleVersion='1',
             UIDeviceFamily=[1, 2], MinimumOSVersion='26.0',
             CFBundleSupportedPlatforms=['iPhoneOS'], DTXcode='2700', DTXcodeBuild='SYNTHETIC')
    return p


def fixture_settings():
    return [{'target': guard.TARGET, 'buildSettings': {
        'PRODUCT_BUNDLE_IDENTIFIER': guard.BUNDLE, 'PRODUCT_NAME': guard.TARGET,
        'INFOPLIST_FILE': 'Config/FleetDevInfo.plist', 'CODE_SIGN_ENTITLEMENTS': 'Config/FleetDev.entitlements',
        'INFOPLIST_KEY_CFBundleDisplayName': guard.NAME, 'MARKETING_VERSION': guard.VERSION,
        'CURRENT_PROJECT_VERSION': '1', 'FLEET_DEV_BUILD': 'YES',
        'FLEET_URL_SCHEME': guard.SCHEME, 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG FLEET_DEV',
        'GENERATE_INFOPLIST_FILE': 'YES', 'DEVELOPMENT_TEAM': 'FIXTURE000', 'FLEET_DEV_SOURCE_SHA': 'a' * 40}}]


class DevContract(unittest.TestCase):
    def test_resolved_dev_settings_pass(self):
        guard.settings(fixture_settings(), '1')

    def test_production_target_and_additional_target_fail(self):
        rows = fixture_settings()
        rows[0]['target'] = 'HermesFleetApp'
        with self.assertRaises(ValueError): guard.settings(rows, '1')
        with self.assertRaises(ValueError): guard.settings(fixture_settings() * 2, '1')

    def test_each_resolved_identity_drift_fails(self):
        for field in fixture_settings()[0]['buildSettings']:
            if field in ('DEVELOPMENT_TEAM', 'FLEET_DEV_SOURCE_SHA'): continue
            with self.subTest(field=field):
                rows = fixture_settings(); rows[0]['buildSettings'][field] = 'production'
                with self.assertRaises(ValueError): guard.settings(rows, '1')

    def test_global_xcconfig_fails(self):
        rows = fixture_settings(); rows[0]['buildSettings']['XCODE_XCCONFIG_FILE'] = 'override'
        with self.assertRaises(ValueError): guard.settings(rows, '1')

    def test_dev_app_metadata_passes(self):
        guard.app_info(fixture_info(), '1')

    def test_production_metadata_and_marker_drift_fail(self):
        for key in ['CFBundleIdentifier', 'CFBundleDisplayName', 'FleetDevBuild',
                    'FleetKeychainNamespace', 'FleetConversationURLScheme', 'FleetCacheDirectory',
                    'CFBundleVersion', 'CFBundleShortVersionString', 'UIDeviceFamily', 'MinimumOSVersion']:
            with self.subTest(key=key):
                p = fixture_info(); p[key] = 'production'
                with self.assertRaises(ValueError): guard.app_info(p, '1')

    def test_production_scheme_or_dual_registration_fails(self):
        p = fixture_info(); p['CFBundleURLTypes'][0]['CFBundleURLSchemes'].append('hermes-fleet')
        with self.assertRaises(ValueError): guard.app_info(p, '1')

    def test_shared_capabilities_fail(self):
        for e in [{'com.apple.security.application-groups': ['group.synthetic.production']},
                  {'keychain-access-groups': ['FIXTURE000.com.synthetic.production']},
                  {'aps-environment': 'production'}, {'unreviewed-capability': True},
                  {'application-identifier': 'FIXTURE000.com.aiowa.hermesfleet'}]:
            with self.subTest(e=e):
                with self.assertRaises(ValueError): guard.entitlements(e)
        guard.entitlements({'application-identifier': 'FIXTURE000.' + guard.BUNDLE,
                            'keychain-access-groups': ['FIXTURE000.' + guard.BUNDLE]})

    def test_export_policy_rejects_external_upload_and_number_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'options.plist'
            original = plistlib.loads((ROOT / 'Config/FleetDevExportOptions.plist').read_bytes())
            guard.export_options(ROOT / 'Config/FleetDevExportOptions.plist')
            for field, value in [('destination', 'upload'), ('testFlightInternalTestingOnly', False),
                                 ('method', 'release-testing'), ('manageAppVersionAndBuildNumber', True),
                                 ('uploadSymbols', True), ('extra', 'override')]:
                changed = dict(original); changed[field] = value
                p.write_bytes(plistlib.dumps(changed))
                with self.subTest(field=field):
                    with self.assertRaises(ValueError): guard.export_options(p)

    def test_privacy_manifest_and_extensions_guard(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); (p/'Info.plist').write_bytes(plistlib.dumps(fixture_info()))
            with self.assertRaises(ValueError): guard.app(p, '1')
            (p/'PrivacyInfo.xcprivacy').write_bytes(b'synthetic')
            guard.app(p, '1')
            (p/'PlugIns').mkdir()
            with self.assertRaises(ValueError): guard.app(p, '1')

    def test_source_requires_exact_sha_clean_tree_and_integrated_target(self):
        sha = 'a' * 40
        with patch.object(guard, 'git', side_effect=[sha, ' M source.swift']):
            with self.assertRaisesRegex(ValueError, 'clean'): guard.source(ROOT, sha)
        with patch.object(guard, 'git', return_value='b' * 40):
            with self.assertRaisesRegex(ValueError, 'HEAD'): guard.source(ROOT, sha)
        with self.assertRaises(ValueError): guard.source(ROOT, 'abc')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'project.yml').write_text('targets:\n  HermesFleetApp:\n')
            with patch.object(guard, 'git', side_effect=[sha, '', '']), patch.object(guard.subprocess, 'run'):
                with self.assertRaisesRegex(ValueError, 'not integrated'): guard.source(root, sha)

    def test_ignored_source_fails(self):
        with patch.object(guard, 'git', side_effect=['a'*40, '', 'HermesFleetApp/injected.swift']), patch.object(guard.subprocess, 'run'):
            with self.assertRaisesRegex(ValueError, 'ignored'): guard.source(ROOT, 'a'*40)

    def test_existing_ancestry_guard_failures_propagate(self):
        with patch.object(guard, 'git', side_effect=['a'*40, '']), patch.object(guard.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'lineage')):
            with self.assertRaises(subprocess.CalledProcessError): guard.source(ROOT, 'a'*40)

    def test_wrapper_rejects_passthrough_and_upload_before_xcode(self):
        for args in [['upload'], ['export', '--scheme', 'HermesFleetApp'],
                     ['export', '--allow-provisioning-updates'], ['export', '--build', '1']]:
            r = subprocess.run(['bash', str(ROOT/'scripts/fleet_dev_build.sh'), *args], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0); self.assertIn('FLEET-DEV-FAIL', r.stderr)


    def test_artifact_exact_source_platform_and_xcode_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp); info = fixture_info()
            (path/'Info.plist').write_bytes(plistlib.dumps(info))
            (path/'PrivacyInfo.xcprivacy').write_bytes(b'synthetic')
            guard.app(path, '1', 'a'*40, 'iPhoneOS')
            for sha, platform in [('b'*40, 'iPhoneOS'), ('a'*40, 'iPhoneSimulator')]:
                with self.assertRaises(ValueError): guard.app(path, '1', sha, platform)
            info['DTXcode'] = '2500'
            (path/'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError): guard.app(path, '1', 'a'*40, 'iPhoneOS')

    def test_real_git_clean_untracked_and_ancestry_guards(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def command(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.DEVNULL).strip()
            command('init', '-q'); command('config', 'user.name', 'Synthetic Fixture')
            command('config', 'user.email', 'fixture@example.invalid')
            (root/'baseline').write_text('synthetic')
            command('add', '.'); command('commit', '-qm', 'synthetic baseline')
            baseline = command('rev-parse', 'HEAD')
            (root/'scripts').mkdir(); (root/'docs/release').mkdir(parents=True)
            shutil.copy(ROOT/'scripts/release_lineage_guard.sh', root/'scripts/release_lineage_guard.sh')
            (root/'docs/release/integration-baseline.sha').write_text(baseline + '\n')
            (root/'project.yml').write_text('targets:\n  HermesFleetDev:\nschemes:\n  HermesFleetDev:\n')
            for name, expression in {
                'HermesFleetApp/FleetConversationShortcuts.swift': 'FleetAppIdentity.conversationURLScheme',
                'HermesFleetApp/FleetServiceGraph.swift': 'FleetAppIdentity.cacheDirectoryName',
                'Packages/FleetSecurity/Sources/FleetSecurity/KeychainCredentialStore.swift': 'FleetAppIdentity.keychainNamespace',
                'Packages/FleetSecurity/Sources/FleetSecurity/KeychainTokenStore.swift': 'FleetAppIdentity.keychainNamespace',
                'Packages/FleetSecurity/Sources/FleetSecurity/KeychainPinStore.swift': 'FleetAppIdentity.keychainNamespace',
            }.items():
                file = root/name; file.parent.mkdir(parents=True, exist_ok=True); file.write_text('// synthetic ' + expression)
            command('add', '.'); command('commit', '-qm', 'synthetic Dev guard fixture')
            sha = command('rev-parse', 'HEAD'); command('update-ref', 'refs/remotes/origin/main', baseline)
            guard.source(root, sha)
            (root/'untracked').write_text('synthetic')
            with self.assertRaisesRegex(ValueError, 'clean'): guard.source(root, sha)
            (root/'untracked').unlink()
            with self.assertRaisesRegex(ValueError, 'HEAD'): guard.source(root, baseline)
            # A newer fetched-main commit not contained by candidate fails closed.
            command('checkout', '-qb', 'newer-main')
            (root/'newer').write_text('synthetic'); command('add', '.'); command('commit', '-qm', 'newer integration')
            command('update-ref', 'refs/remotes/origin/main', command('rev-parse', 'HEAD'))
            command('checkout', '-q', sha)
            with self.assertRaises(subprocess.CalledProcessError): guard.source(root, sha)

    def test_synthetic_dev_ipa_export_signature_and_group_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp); (out/'export').mkdir()
            (out/'settings.json').write_text(json.dumps(fixture_settings()))
            with zipfile.ZipFile(out/'export/dev.ipa', 'w') as z:
                z.writestr('Payload/HermesFleetDev.app/Info.plist', plistlib.dumps(fixture_info()))
                z.writestr('Payload/HermesFleetDev.app/PrivacyInfo.xcprivacy', b'synthetic')
                z.writestr('Payload/HermesFleetDev.app/embedded.mobileprovision', b'synthetic')
            signed = {'application-identifier': 'FIXTURE000.' + guard.BUNDLE,
                      'com.apple.developer.team-identifier': 'FIXTURE000', 'get-task-allow': False,
                      'keychain-access-groups': ['FIXTURE000.' + guard.BUNDLE]}
            def fake_run(command, **kwargs):
                if '--entitlements' in command: output = plistlib.dumps(signed).decode()
                elif '-dvv' in command: output = 'Authority=Apple Distribution: Synthetic\nTeamIdentifier=FIXTURE000\n'
                else: output = ''
                return subprocess.CompletedProcess(command, 0, stdout=output, stderr='')
            with patch.object(exported, 'run', side_effect=fake_run), patch.object(exported, 'inspect_profile') as profile:
                exported.inspect(out, '1')
                profile.assert_called_once()
                shutil.rmtree(out/'ipa-inspection')
                signed['keychain-access-groups'] = ['FIXTURE000.com.synthetic.production']
                with self.assertRaisesRegex(ValueError, 'shared keychain'): exported.inspect(out, '1')

    def test_unsafe_ipa_paths_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp); (out/'export').mkdir()
            (out/'settings.json').write_text(json.dumps(fixture_settings()))
            with zipfile.ZipFile(out/'export/dev.ipa', 'w') as z: z.writestr('../escape', 'synthetic')
            with self.assertRaisesRegex(ValueError, 'unsafe'): exported.inspect(out, '1')
            self.assertFalse((out.parent/'escape').exists())


    def test_wrapper_three_modes_with_mocked_xcode(self):
        # Exercise real macOS Bash argument construction/locks/evidence paths.
        # Native tools and guards are isolated doubles; never acceptance evidence.
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root = base/'repo'; tools = base/'tools'
            (root/'scripts').mkdir(parents=True); tools.mkdir()
            shutil.copy(ROOT/'scripts/fleet_dev_build.sh', root/'scripts/fleet_dev_build.sh')
            (root/'scripts/fleet_dev_guard.py').write_text('import sys\nprint("synthetic guard double")\n')
            (root/'scripts/fleet_dev_export_inspect.py').write_text('print("synthetic IPA inspector double")\n')
            (root/'scripts/sim_destination.sh').write_text(
                'resolve_sim_destination() { SIM_SELECTION=lane; SIM_DEST="platform=iOS Simulator,id=SYNTHETIC"; }\n'
                'sim_metadata_lines() { echo simulator_selection=lane; }\n')
            (tools/'xcodegen').write_text('#!/bin/bash\nexit 0\n')
            (tools/'xcodegen').chmod(0o755)
            (tools/'xcodebuild').write_text('#!/usr/bin/env python3\n' +
                'import json,os,sys,pathlib\n'
                'a=sys.argv[1:]\n'
                'with open(os.environ["MOCK_XCODE_LOG"],"a") as f: f.write(json.dumps(a)+"\\n")\n'
                'if "-version" in a: print("Xcode 27.0\\nBuild version SYNTHETIC")\n'
                'elif "-showBuildSettings" in a: print("[]")\n')
            (tools/'xcodebuild').chmod(0o755)
            log = base/'commands.jsonl'
            env = dict(os.environ, PATH=str(tools)+':'+os.environ['PATH'], MOCK_XCODE_LOG=str(log))
            env.pop('XCODE_XCCONFIG_FILE', None); env.pop('HERMES_FLEET_SIM_UDID', None)
            for mode in ['simulator', 'structure-only', 'export']:
                r = subprocess.run(['bash', str(root/'scripts/fleet_dev_build.sh'), mode,
                                    '--sha', 'a'*40, '--build', '1'], env=env, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertFalse((root/'build/FleetDev/run.lock').exists())
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            builds = [a for a in commands if 'build' in a or 'archive' in a]
            self.assertEqual(len(builds), 3)
            for a in builds:
                self.assertEqual(a[a.index('-scheme')+1], 'HermesFleetDev')
                self.assertIn('FLEET_DEV_SOURCE_SHA='+'a'*40, a)
                self.assertNotIn('-xcconfig', a); self.assertNotIn('-allowProvisioningUpdates', a)
            self.assertIn('CODE_SIGNING_ALLOWED=NO', builds[0])
            self.assertIn('CODE_SIGNING_ALLOWED=NO', builds[1])
            self.assertNotIn('CODE_SIGNING_ALLOWED=NO', builds[2])
            self.assertIn('platform=iOS Simulator,id=SYNTHETIC', builds[0])
            exports = [a for a in commands if '-exportArchive' in a]
            self.assertEqual(len(exports), 1)
            self.assertEqual(exports[0][exports[0].index('-exportOptionsPlist')+1], 'Config/FleetDevExportOptions.plist')
            self.assertNotIn('-allowProvisioningUpdates', exports[0])
            self.assertEqual(len(list((root/'build/FleetDev').glob('*/provenance.txt'))), 3)


    def test_dev_hosted_scheme_rejects_production_host(self):
        rows = fixture_settings() + [{'target': 'HermesFleetDevTests', 'buildSettings': {
            'PRODUCT_BUNDLE_IDENTIFIER': guard.BUNDLE + '.tests',
            'TEST_HOST': '/synthetic/HermesFleetDev.app/HermesFleetDev',
            'BUNDLE_LOADER': '/synthetic/HermesFleetDev.app/HermesFleetDev'}}]
        guard.test_settings(rows, '1', 'a'*40)
        rows[1]['buildSettings']['TEST_HOST'] = '/synthetic/HermesFleetApp.app/HermesFleetApp'
        with self.assertRaises(ValueError): guard.test_settings(rows, '1', 'a'*40)

    def test_dev_result_rejects_missing_skipped_or_recovered_cases(self):
        summary = {'result': 'Passed', 'totalTestCount': 8, 'skippedTests': 0}
        tests = {'testNodes': [{'nodeType': 'Test Case', 'name': name,
                               'nodeIdentifier': 'FleetDevIsolationTests/' + name, 'result': 'Passed'}
                              for name in sorted(result_guard.EXPECTED)]}
        result_guard.verify(summary, tests)
        missing = {'testNodes': tests['testNodes'][:-1]}
        with self.assertRaises(ValueError): result_guard.verify(summary, missing)
        tests['testNodes'][0]['details'] = 'Passed after 1 retry'
        with self.assertRaises(ValueError): result_guard.verify(summary, tests)
        tests['testNodes'][0].pop('details'); summary['skippedTests'] = 1
        with self.assertRaises(ValueError): result_guard.verify(summary, tests)

    def test_version_counter_is_separate_and_production_unchanged(self):
        config = (ROOT/'Config/FleetDev.xcconfig').read_text()
        self.assertIn('MARKETING_VERSION = 0.1.0', config)
        self.assertIn('CURRENT_PROJECT_VERSION = 1', config)
        project = (ROOT/'project.yml').read_text()
        baseline = subprocess.check_output(['git', '-C', str(ROOT), 'show', 'origin/main:project.yml'], text=True)
        import re
        for key in ['CURRENT_PROJECT_VERSION', 'MARKETING_VERSION']:
            original = re.search(r'^    ' + key + r': (.+)$', baseline, re.M).group(0)
            self.assertIn(original, project)
        p = plistlib.loads((ROOT/'HermesFleetApp/Info.plist').read_bytes())
        self.assertEqual(p['CFBundleURLTypes'][0]['CFBundleURLSchemes'], ['hermes-fleet'])


if __name__ == '__main__': unittest.main()
