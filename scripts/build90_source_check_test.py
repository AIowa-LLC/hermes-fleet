#!/usr/bin/env python3
"""Check the release source guard against synthetic Git trees, without Xcode."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build90_source_check import differences, infrastructure, source_tree


class PreservationContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-source-contract-')
        self.repo = Path(self.tmp.name)
        self.git('init', '-q')
        self.write('App/View.swift', 'original app\n')
        self.write('project.yml', 'version: 90\n')
        self.write('Package.resolved', 'dependency lock\n')
        self.write('HermesFleetAppUITests/Room.swift', 'regression\n')
        self.write('docs/notes.md', 'old documentation\n')
        self.base = self.tree()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True, stderr=subprocess.PIPE).strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def tree(self):
        self.git('add', '-A')
        return self.git('write-tree')

    def changed(self):
        return differences(source_tree(self.repo, self.base), source_tree(self.repo, self.tree()))

    def test_identical_tree_matches(self):
        self.assertEqual(self.changed(), [])

    def test_documentation_and_ci_changes_are_explicitly_allowed(self):
        self.write('docs/notes.md', 'new documentation\n')
        self.write('scripts/check.sh', 'new check\n')
        self.write('.github/workflows/ci.yml', 'new workflow\n')
        self.write('RELEASES.md', 'release record\n')
        self.assertEqual(self.changed(), [])

    def test_app_change_is_rejected(self):
        self.write('App/View.swift', 'changed app\n')
        self.assertEqual(self.changed(), ['App/View.swift'])

    def test_dependency_change_is_rejected(self):
        self.write('Package.resolved', 'different dependency\n')
        self.assertEqual(self.changed(), ['Package.resolved'])

    def test_build_configuration_change_is_rejected(self):
        self.write('project.yml', 'version: 91\n')
        self.assertEqual(self.changed(), ['project.yml'])

    def test_regression_test_change_is_rejected(self):
        self.write('HermesFleetAppUITests/Room.swift', 'weakened test\n')
        self.assertEqual(self.changed(), ['HermesFleetAppUITests/Room.swift'])

    def test_deletion_is_rejected(self):
        (self.repo / 'App/View.swift').unlink()
        self.assertEqual(self.changed(), ['App/View.swift'])

    def test_added_product_file_is_rejected(self):
        self.write('App/New.swift', 'new behavior\n')
        self.assertEqual(self.changed(), ['App/New.swift'])

    def test_git_mode_change_is_rejected(self):
        self.git('update-index', '--chmod=+x', 'App/View.swift')
        target = self.git('write-tree')
        self.assertEqual(differences(source_tree(self.repo, self.base), source_tree(self.repo, target)), ['App/View.swift'])

    def test_nested_docs_name_is_not_an_allowlist_escape(self):
        self.assertFalse(infrastructure('App/docs/View.swift'))
        self.assertFalse(infrastructure('docs.swift'))
        self.assertFalse(infrastructure('.gitmodules'))
        self.assertFalse(infrastructure('Packages/FleetUI/Sources/scripts.swift'))

    def test_unknown_source_fails_instead_of_passing(self):
        with self.assertRaises(subprocess.CalledProcessError):
            source_tree(self.repo, 'not-a-real-object')


if __name__ == '__main__':
    unittest.main(verbosity=2)
