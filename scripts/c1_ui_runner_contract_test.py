#!/usr/bin/env python3
"""Exercise CI plumbing with mocked Xcode, never a simulator or live gateway.

These tests validate selection, execution, and fail-closed evidence handling.
They are not product UI acceptance tests.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from c1_ui_partition import partition, runtime_weights
from c1_xcresult_parse import parse

ROOT = Path(__file__).resolve().parent.parent
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if pathlib.Path(sys.argv[0]).name == 'xcodebuild':
    with open(os.environ['MOCK_CALLS'], 'a') as log:
        log.write(json.dumps(args) + '\n')
    if '-version' in args:
        print('Xcode mock (runner contract test only)')
        sys.exit(0)
    if 'build-for-testing' in args:
        sys.exit(23 if os.environ.get('MOCK_BUILD_FAIL') else 0)
    if 'test-without-building' not in args:
        sys.exit(24)
    if os.environ.get('MOCK_TEST_FAIL'):
        sys.exit(25)
    bundle = pathlib.Path(args[args.index('-resultBundlePath') + 1])
    if os.environ.get('MOCK_MISSING_BUNDLE'):
        sys.exit(0)
    bundle.mkdir(parents=True)
    selected = [a.split(':', 1)[1].split('/') for a in args if a.startswith('-only-testing:')]
    nodes = []
    for parts in selected:
        cls = parts[1]
        method = parts[2] if len(parts) == 3 else 'testMockCase'
        if os.environ.get('MOCK_WRONG_METHOD'):
            method = 'testDifferentCase'
        result = 'Skipped' if os.environ.get('MOCK_SKIP') else 'Passed'
        nodes.append({'nodeType':'Test Case', 'nodeIdentifier':cls + '/' + method + '()', 'name':method + '()', 'result':result})
    if os.environ.get('MOCK_EMPTY'):
        nodes = []
    (bundle / 'mock.json').write_text(json.dumps(nodes))
    sys.exit(0)
if args[:3] == ['simctl', 'list', 'devices']:
    print('    iPhone Contract Test (00000000-0000-0000-0000-000000000001) (Shutdown)')
    sys.exit(0)
if args[:3] == ['xcresulttool', 'get', 'test-results']:
    if os.environ.get('MOCK_BAD_JSON'):
        print('not JSON')
        sys.exit(0)
    bundle = pathlib.Path(args[args.index('--path') + 1])
    nodes = json.loads((bundle / 'mock.json').read_text())
    if args[3] == 'summary':
        print(json.dumps({'result':'Passed', 'totalTestCount':len(nodes)}))
    else:
        print(json.dumps({'testNodes':nodes}))
    sys.exit(0)
sys.exit(26)
'''


class PartitionContract(unittest.TestCase):
    def test_partition_preserves_all_large_selection_once(self):
        names = [f'Suite{i}' for i in range(59)]
        result = partition(names, {name: i + 1 for i, name in enumerate(names)}, 4)
        flattened = [name for bucket in result for name in bucket]
        self.assertEqual(len(flattened), 59)
        self.assertEqual(set(flattened), set(names))
        self.assertEqual(result, partition(names, {name: i + 1 for i, name in enumerate(names)}, 4))

    def test_empty_partitions_are_valid(self):
        self.assertEqual(partition([], {}, 4), [[], [], [], []])

    def test_duplicate_suite_is_rejected(self):
        with self.assertRaises(ValueError):
            partition(['A', 'A'], {}, 4)

    def test_zero_shards_rejected(self):
        with self.assertRaises(ValueError):
            partition(['A'], {}, 0)

    def test_real_selector_shards_preserve_exact_full_inventory(self):
        selected = []
        requested = None
        for shard in range(1, 5):
            result = subprocess.run(['bash', str(ROOT / 'scripts/c1_ui_preflight.sh'), '--files', '-', '--print', '--shard', str(shard), '--shards', '4'], input='Packages/FleetCore/Sources/FleetCore/Session.swift\n', text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            requested = re.search(r'^REQUESTED_CLASSES: *(.*)$', result.stdout, re.M).group(1).split()
            selected += re.search(r'^SELECTED_CLASSES: *(.*)$', result.stdout, re.M).group(1).split()
        self.assertEqual(len(selected), len(requested))
        self.assertEqual(set(selected), set(requested))

    def test_bad_shard_indices_fail_before_execution(self):
        for shard, shards in [('0','4'), ('5','4'), ('1','0'), ('-1','4'), ('x','4')]:
            result = subprocess.run(['bash', str(ROOT / 'scripts/c1_ui_preflight.sh'), '--files', '-', '--print', '--shard', shard, '--shards', shards], input='README.md\n', text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)


class RunnerContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-ui-runner-contract-')
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        for name in ('c1_ui_matrix.sh', 'c1_xcresult_parse.py', 'c1_critical_smoke.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        shutil.copytree(ROOT / 'HermesFleetAppUITests', self.root / 'HermesFleetAppUITests')
        shutil.copy2(ROOT / 'project.yml', self.root / 'project.yml')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        unavailable_rg = self.bin / 'rg'
        unavailable_rg.write_text('#!/bin/sh\nexit 127\n')
        unavailable_rg.chmod(0o755)
        for name in ('xcrun', 'xcodebuild'):
            path = self.bin / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], MOCK_CALLS=str(self.root / 'calls.jsonl'))
        self.evidence = []

    def tearDown(self):
        # Only remove directories returned by this test's own mock invocation.
        for path in self.evidence:
            if path.parent == Path('/tmp') and path.name.startswith('hermes-c1-results.'):
                shutil.rmtree(path)
        self.tmp.cleanup()

    def run_matrix(self, *args, **settings):
        result = subprocess.run(['bash', 'scripts/c1_ui_matrix.sh', *args], cwd=self.root, env=dict(self.env, **settings), text=True, capture_output=True, timeout=30)
        for match in re.findall(r'^UI evidence: (.+)$', result.stdout, re.M):
            self.evidence.append(Path(match))
        calls_file = self.root / 'calls.jsonl'
        calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
        return result, calls

    def test_build_once_then_test_without_building(self):
        result, calls = self.run_matrix('--classes', 'HermesFleetHappyPath HermesFleetReconnect')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum('build-for-testing' in call for call in calls), 1)
        self.assertEqual(sum('test-without-building' in call for call in calls), 2)
        self.assertFalse(any('test' in call or 'build' in call for call in calls))
        self.assertTrue((self.evidence[0] / 'provenance.log').exists())

    def test_failed_build_does_not_start_tests(self):
        result, calls = self.run_matrix('--classes', 'HermesFleetHappyPath', MOCK_BUILD_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('test-without-building' in call for call in calls))

    def test_focused_failure_stops_remaining_suites(self):
        result, calls = self.run_matrix('--classes', 'HermesFleetHappyPath HermesFleetReconnect', '--fail-fast', MOCK_TEST_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum('test-without-building' in call for call in calls), 1)

    def test_deep_failure_collects_remaining_suites(self):
        result, calls = self.run_matrix('--classes', 'HermesFleetHappyPath HermesFleetReconnect', MOCK_TEST_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum('test-without-building' in call for call in calls), 2)

    def test_empty_report_fails(self):
        result, _ = self.run_matrix('--classes', 'HermesFleetHappyPath', MOCK_EMPTY='1')
        self.assertNotEqual(result.returncode, 0)

    def test_missing_bundle_fails(self):
        result, _ = self.run_matrix('--classes', 'HermesFleetHappyPath', MOCK_MISSING_BUNDLE='1')
        self.assertNotEqual(result.returncode, 0)

    def test_invalid_report_fails(self):
        result, _ = self.run_matrix('--classes', 'HermesFleetHappyPath', MOCK_BAD_JSON='1')
        self.assertNotEqual(result.returncode, 0)

    def test_unexpected_skip_fails(self):
        result, _ = self.run_matrix('--classes', 'HermesFleetHappyPath', MOCK_SKIP='1')
        self.assertNotEqual(result.returncode, 0)

    def test_exact_method_is_executed(self):
        selector = 'HermesFleetHappyPath/testHappyPathGatewaysToConversationStreamedAnswer'
        result, calls = self.run_matrix('--tests', selector, '--fail-fast')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        test_call = next(call for call in calls if 'test-without-building' in call)
        self.assertIn('-only-testing:HermesFleetAppUITests/HermesFleetHappyPathUITests/testHappyPathGatewaysToConversationStreamedAnswer', test_call)

    def test_wrong_method_cannot_produce_false_green(self):
        result, _ = self.run_matrix('--tests', 'HermesFleetHappyPath/testHappyPathGatewaysToConversationStreamedAnswer', MOCK_WRONG_METHOD='1')
        self.assertNotEqual(result.returncode, 0)

    def test_unknown_selector_fails_before_xcode(self):
        result, calls = self.run_matrix('--tests', 'HermesFleetHappyPath/testDoesNotExist')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_missing_modern_room_regression_is_blocking(self):
        project = self.root / 'project.yml'
        project.write_text(re.sub(r'CURRENT_PROJECT_VERSION: *\d+', 'CURRENT_PROJECT_VERSION: 89', project.read_text()))
        test = self.root / 'HermesFleetAppUITests/FOS8AccessibilityUITests.swift'
        test.write_text(test.read_text().replace('testGroupConversationOpensAtLatestWithDeepHistory', 'removedForContractFixture'))
        result = subprocess.run(['bash', 'scripts/c1_critical_smoke.sh', '--list-tests'], cwd=self.root, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires the deep-history', result.stderr)


class ExactSelectionParserContract(unittest.TestCase):
    def test_missing_expected_case_is_incomplete(self):
        summary = {'result':'Passed', 'totalTestCount':1}
        nodes = [{'nodeType':'Test Case', 'nodeIdentifier':'ExampleUITests/testOne()', 'name':'testOne()', 'result':'Passed'}]
        result = parse(summary, nodes, 'ExampleUITests', expected_cases={'testOne()', 'testTwo()'})
        self.assertEqual(result[2], 0)

    def test_extra_case_is_incomplete(self):
        summary = {'result':'Passed', 'totalTestCount':2}
        nodes = [{'nodeType':'Test Case', 'nodeIdentifier':f'ExampleUITests/{name}()', 'name':f'{name}()', 'result':'Passed'} for name in ('testOne', 'testTwo')]
        self.assertEqual(parse(summary, nodes, 'ExampleUITests', expected_cases={'testOne()'})[2], 0)

    def test_exact_set_is_complete(self):
        summary = {'result':'Passed', 'totalTestCount':1}
        nodes = [{'nodeType':'Test Case', 'nodeIdentifier':'ExampleUITests/testOne()', 'name':'testOne()', 'result':'Passed'}]
        self.assertEqual(parse(summary, nodes, 'ExampleUITests', expected_cases={'testOne()'})[2], 1)


class RuntimeWeightContract(unittest.TestCase):
    def read_fixture(self, names, values):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'matrix.sh'
            p.write_text('UI_CLASSES=(\n' + names + '\n)\nUI_WEIGHT_TENTHS_OF_MINUTE=(\n' + values + '\n)\n')
            return runtime_weights(p)

    def test_literal_weights_convert_to_seconds(self):
        self.assertEqual(self.read_fixture('A B # comment', '10 25'), {'A': 60, 'B': 150})

    def test_missing_weight_fails(self):
        with self.assertRaises(ValueError):
            self.read_fixture('A B', '10')

    def test_zero_negative_and_expression_fail(self):
        for value in ('0', '-1', '$(command)'):
            with self.assertRaises(ValueError):
                self.read_fixture('A', value)

    def test_duplicate_suite_fails(self):
        with self.assertRaises(ValueError):
            self.read_fixture('A A', '10 20')

    def test_full_inventory_fits_historical_partition_budget(self):
        weights = runtime_weights(ROOT / 'scripts/c1_ui_matrix.sh')
        buckets = partition(list(weights), weights, 12)
        self.assertEqual(set(n for b in buckets for n in b), set(weights))
        self.assertEqual(sum(map(len, buckets)), len(weights))
        # Historical work per partition must leave setup/variance margin
        # inside the unchanged 75-minute job ceiling. This is not an ETA.
        self.assertLessEqual(max(sum(weights[n] for n in b) for b in buckets), 55 * 60)


if __name__ == '__main__':
    unittest.main(verbosity=2)
