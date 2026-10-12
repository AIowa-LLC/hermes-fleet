from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / "installer.py"
spec = importlib.util.spec_from_file_location("fleet_installer", MODULE)
installer = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(installer)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "hermes-source"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.before = b"base capability absent\n"
        self.intermediate = b"fleet pairing capability at ECD\n"
        self.after = b"base capability plus Fleet owner binding\n"
        (self.source / "changed.py").write_bytes(self.before)
        os.chmod(self.source / "changed.py", 0o755)
        self.git("add", "changed.py")
        self.git("commit", "-qm", "fixture source")
        self.base = self.git("rev-parse", "HEAD")
        (self.source / "changed.py").write_bytes(self.intermediate)
        (self.source / "added.py").write_bytes(b"owner status handler\n")
        self.git("add", "-N", "added.py")
        self.after_added = b"owner status handler\n"
        self.git("add", "changed.py", "added.py")
        self.git("commit", "-qm", "fixture prior overlay")
        self.overlay = self.git("rev-parse", "HEAD")
        (self.source / "changed.py").write_bytes(self.after)
        self.patch = subprocess.run(["git", "-C", str(self.source), "diff", "--binary", "--full-index",
                                     self.base], check=True, stdout=subprocess.PIPE).stdout
        self.upgrade_patch = subprocess.run(["git", "-C", str(self.source), "diff", "--binary", "--full-index"],
                                            check=True, stdout=subprocess.PIPE).stdout
        self.git("add", "changed.py")
        self.git("commit", "-qm", "fixture safety upgrade")
        self.target = self.git("rev-parse", "HEAD")
        self.paths = {
            "added.py": {"before_sha256": None, "after_sha256": sha(self.after_added)},
            "changed.py": {"before_sha256": sha(self.before), "after_sha256": sha(self.after)},
        }
        self.supported_preimages = {"added.py": sha(self.after_added), "changed.py": sha(self.intermediate)}
        self.upgrade_paths = {"changed.py": {"before_sha256": sha(self.intermediate),
                                              "after_sha256": sha(self.after)}}
        self.git("checkout", "-q", self.base)
        (self.source / "changed.py").write_bytes(self.before)
        (self.source / "added.py").unlink(missing_ok=True)
        self.release = self.root / "release"
        self.release.mkdir()
        plugin_repo = self.root / "plugin-source"
        plugin_repo.mkdir()
        subprocess.run(["git", "init", "-q", "--initial-branch=main", str(plugin_repo)], check=True)
        subprocess.run(["git", "-C", str(plugin_repo), "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(plugin_repo), "config", "user.name", "Fixture"], check=True)
        (plugin_repo / "plugin.yaml").write_text("name: fixture\n")
        subprocess.run(["git", "-C", str(plugin_repo), "add", "plugin.yaml"], check=True)
        subprocess.run(["git", "-C", str(plugin_repo), "commit", "-qm", "fixture plugin"], check=True)
        self.plugin_commit = subprocess.run(["git", "-C", str(plugin_repo), "rev-parse", "HEAD"],
                                            check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
        self.plugin_bundle = self.release / "owner-control.bundle"
        subprocess.run(["git", "-C", str(plugin_repo), "bundle", "create", str(self.plugin_bundle),
                        "refs/heads/main"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        installer.BASE, installer.SUPPORTED_OVERLAY = self.base, self.overlay
        installer.SUPPORTED_TARGET = self.target
        installer.MANIFEST, installer.PATCH = self.release / "manifest.json", self.release / "overlay.patch"
        installer.UPGRADE_PATCH = self.release / "upgrade.patch"
        installer.PLUGIN_BUNDLE = self.plugin_bundle
        self.manifest = {"format": 1, "base_commit": self.base,
                         "target_commit": self.target, "supported_overlay_commit": self.overlay,
                         "commits": ([{"short": short, "full": "0" * 40, "subject": "fixture"}
                                     for short in installer.REQUIRED_COMMITS]
                                     + [{"short": self.target[:10],
                                         "full": self.target, "subject": "fixture safety supplement"}]),
                         "changed_paths": sorted(self.paths), "paths": self.paths,
                         "supported_preimages": self.supported_preimages,
                         "upgrade_paths": self.upgrade_paths,
                         "upgrade_patch_sha256": sha(self.upgrade_patch),
                         "plugin_commit": self.plugin_commit,
                         "plugin_bundle_sha256": sha(self.plugin_bundle.read_bytes()),
                         "patch_sha256": sha(self.patch),
                         "support_files": {rel: sha((installer.ROOT / rel).read_bytes())
                                           for rel in installer.REQUIRED_SUPPORT_FILES},
                         "release_scope": "fixture"}
        self.write_release()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.source), *args], check=True,
                              stdout=subprocess.PIPE, text=True).stdout.strip()

    def write_release(self):
        installer.PATCH.write_bytes(self.patch)
        installer.UPGRADE_PATCH.write_bytes(self.upgrade_patch)
        installer.MANIFEST.write_text(json.dumps(self.manifest, sort_keys=True, indent=2) + "\n")
        self.trusted = sha(installer.MANIFEST.read_bytes())

    def candidate(self):
        output = self.root / "candidate"
        installer.candidate(type("Args", (), {"source": str(self.source), "output": str(output),
                                               "trusted_manifest_sha256": self.trusted})())
        return output.resolve()

    def receipt(self, candidate):
        record, _, patch = installer.candidate_record(candidate, self.trusted)
        test_log = self.root / "canonical-tests.log"
        test_log.write_text("fixture tests passed\n")
        installer.write_json(candidate / ".fleet-overlay-test-receipt.json", {
            "candidate": str(candidate), "source": record["source"],
            "source_head": record["source_head"], "source_tree": record["source_tree"],
            "candidate_tree": record["candidate_tree"], "patch_sha256": sha(patch),
            "manifest_sha256": self.trusted, "passed": True, "exit_code": 0,
            "test_exit_code": 0,
            "test_interpreter": sys.executable,
            "test_command": ["bash", "scripts/run_tests.sh", *installer.TEST_PATHS],
            "test_log_path": str(test_log), "test_output_sha256": sha(test_log.read_bytes())})

    def test_stage_apply_and_rollback_restore_only_allowlisted_source(self):
        home = self.root / "home"
        home.mkdir()
        home_marker = home / "config.yaml"
        home_marker.write_text("preserve me\n")
        candidate = self.candidate()
        self.receipt(candidate)
        state = self.root / "state"
        installer.apply(type("Args", (), {"source": str(self.source), "candidate": str(candidate),
                                            "state": str(state),
                                            "trusted_manifest_sha256": self.trusted})())
        self.assertEqual((self.source / "changed.py").read_bytes(), self.after)
        self.assertEqual((self.source / "added.py").read_bytes(), self.after_added)
        self.assertEqual(home_marker.read_text(), "preserve me\n")
        unrelated = self.source / "unrelated-later-work.txt"
        unrelated.write_text("preserve later source work\n")
        journal = next(state.glob("txn-*/journal.json"))
        installer.rollback(type("Args", (), {"journal": str(journal),
                                               "trusted_manifest_sha256": self.trusted})())
        self.assertEqual((self.source / "changed.py").read_bytes(), self.before)
        self.assertEqual(stat.S_IMODE((self.source / "changed.py").stat().st_mode), 0o755)
        self.assertFalse((self.source / "added.py").exists())
        self.assertEqual(unrelated.read_text(), "preserve later source work\n")
        self.assertEqual(home_marker.read_text(), "preserve me\n")

    def test_supported_ecd_source_uses_narrow_upgrade_patch(self):
        prior = self.root / "ecd-source"
        subprocess.run(["git", "clone", "--no-hardlinks", "--local", str(self.source), str(prior)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(["git", "-C", str(prior), "checkout", "-q", self.overlay], check=True)
        self.assertEqual(installer.source_kind(prior, self.manifest), "upgrade")
        output = self.root / "upgrade-candidate"
        installer.candidate(type("Args", (), {"source": str(prior), "output": str(output),
                                               "trusted_manifest_sha256": self.trusted})())
        candidate = output.resolve()
        record, _, selected = installer.candidate_record(candidate, self.trusted)
        self.assertEqual(record["install_mode"], "upgrade")
        self.assertEqual(selected, self.upgrade_patch)
        self.receipt(candidate)
        installer.apply(type("Args", (), {"source": str(prior), "candidate": str(candidate),
                                            "state": str(self.root / "upgrade-state"),
                                            "trusted_manifest_sha256": self.trusted})())
        self.assertEqual((prior / "changed.py").read_bytes(), self.after)
        self.assertEqual((prior / "added.py").read_bytes(), self.after_added)
        journal = next((self.root / "upgrade-state").glob("txn-*/journal.json"))
        installer.rollback(type("Args", (), {"journal": str(journal),
                                               "trusted_manifest_sha256": self.trusted})())
        self.assertEqual((prior / "changed.py").read_bytes(), self.intermediate)
        self.assertEqual((prior / "added.py").read_bytes(), self.after_added)

    def test_dirty_and_changed_preimage_refuse_staging(self):
        (self.source / "local.txt").write_text("local work\n")
        with self.assertRaises(installer.Refusal):
            self.candidate()
        (self.source / "local.txt").unlink()
        (self.source / "changed.py").write_bytes(b"drifted source\n")
        self.git("add", "changed.py")
        self.git("commit", "-qm", "upstream drift")
        with self.assertRaises(installer.Refusal):
            self.candidate()

    def test_candidate_conflict_and_capability_drift_fail_closed(self):
        self.assertEqual(installer.file_hash(self.source / "changed.py"), sha(self.before))
        self.assertEqual(installer.source_kind(self.source, self.manifest), "base")
        (self.source / "changed.py").write_bytes(b"unexpected capability drift\n")
        with self.assertRaises(installer.Refusal):
            installer.source_kind(self.source, self.manifest)

    def test_trusted_manifest_tamper_and_path_traversal_refuse(self):
        with self.assertRaises(installer.Refusal):
            installer.load_release("0" * 64)
        self.manifest["paths"]["../outside"] = {"before_sha256": None, "after_sha256": "0" * 64}
        self.manifest["changed_paths"] = sorted(self.manifest["paths"])
        self.write_release()
        with self.assertRaises(installer.Refusal):
            installer.load_release(self.trusted)
        with self.assertRaises(installer.Refusal):
            installer.safe_file(self.source, "../outside")

    def test_interrupted_apply_journal_rolls_back_partial_mutation(self):
        candidate = self.candidate()
        self.receipt(candidate)
        state = self.root / "state"
        original_run = subprocess.run

        def interrupted(command, *args, **kwargs):
            if command[:4] == ["git", "-C", str(self.source.resolve()), "apply"]:
                (self.source / "changed.py").write_bytes(self.after)
                return subprocess.CompletedProcess(command, 1, "", "injected interruption")
            return original_run(command, *args, **kwargs)

        with mock.patch.object(installer.subprocess, "run", side_effect=interrupted):
            with self.assertRaises(installer.Refusal):
                installer.apply(type("Args", (), {"source": str(self.source), "candidate": str(candidate),
                                                    "state": str(state),
                                                    "trusted_manifest_sha256": self.trusted})())
        journal = next(state.glob("txn-*/journal.json"))
        installer.rollback(type("Args", (), {"journal": str(journal),
                                               "trusted_manifest_sha256": self.trusted})())
        self.assertEqual((self.source / "changed.py").read_bytes(), self.before)
        self.assertFalse((self.source / "added.py").exists())

    def test_validate_creates_receipt_only_after_runner_exit_zero(self):
        candidate = self.candidate()
        original_run = subprocess.run

        def runner(command, *args, **kwargs):
            if len(command) >= 3 and command[1:3] == ["-c", "import pytest"]:
                return subprocess.CompletedProcess(command, 0, b"", b"")
            if command[:2] == ["bash", "scripts/run_tests.sh"]:
                kwargs["stdout"].write(b"fixture tests passed\n")
                return subprocess.CompletedProcess(command, 1, 0, None)
            return original_run(command, *args, **kwargs)

        validate_args = type("Args", (), {"candidate": str(candidate), "python": sys.executable,
                                           "log": str(self.root / "validation.log"),
                                           "trusted_manifest_sha256": self.trusted})()
        with mock.patch.object(installer.subprocess, "run", side_effect=runner):
            with self.assertRaises(installer.Refusal):
                installer.validate(validate_args)
        self.assertFalse((candidate / ".fleet-overlay-test-receipt.json").exists())
        validate_args.log = str(self.root / "validation-passed.log")

        def passing_runner(command, *args, **kwargs):
            if len(command) >= 3 and command[1:3] == ["-c", "import pytest"]:
                return subprocess.CompletedProcess(command, 0, b"", b"")
            if command[:2] == ["bash", "scripts/run_tests.sh"]:
                kwargs["stdout"].write(b"fixture tests passed\n")
                return subprocess.CompletedProcess(command, 0, 0, None)
            return original_run(command, *args, **kwargs)

        with mock.patch.object(installer.subprocess, "run", side_effect=passing_runner):
            installer.validate(validate_args)
        receipt = json.loads((candidate / ".fleet-overlay-test-receipt.json").read_text())
        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["exit_code"], 0)
        self.assertEqual(receipt["test_exit_code"], 0)
        self.assertEqual(Path(receipt["test_log_path"]).read_bytes(), b"fixture tests passed\n")

    def test_apply_refuses_missing_or_tampered_full_test_log(self):
        candidate = self.candidate()
        self.receipt(candidate)
        receipt = json.loads((candidate / ".fleet-overlay-test-receipt.json").read_text())
        Path(receipt["test_log_path"]).write_text("edited\n")
        with self.assertRaises(installer.Refusal):
            installer.apply(type("Args", (), {"source": str(self.source), "candidate": str(candidate),
                                                "state": str(self.root / "state"),
                                                "trusted_manifest_sha256": self.trusted})())

    def test_validate_preserves_real_venv_python_symlink_and_prefix(self):
        candidate = self.candidate()
        venv = self.root / "approved-venv"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(venv)], check=True)
        interpreter = venv / "bin" / "python"
        self.assertTrue(interpreter.is_symlink(), "regression fixture must exercise a venv symlink")
        prefix = subprocess.run([str(interpreter), "-c", "import sys; print(sys.prefix)"],
                                check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
        self.assertEqual(Path(prefix).resolve(), venv.resolve())
        purelib = subprocess.run([str(interpreter), "-c",
                                  "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
                                 check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
        pytest_dir = Path(purelib) / "pytest"
        pytest_dir.mkdir()
        (pytest_dir / "__init__.py").write_text("__version__ = 'fixture'\n")
        validate_args = type("Args", (), {"candidate": str(candidate), "python": str(interpreter),
                                           "log": str(self.root / "venv-validation.log"),
                                           "trusted_manifest_sha256": self.trusted})()
        original_run = subprocess.run
        observed_prefix = []

        def runner(command, *args, **kwargs):
            if command[:2] == ["bash", "scripts/run_tests.sh"]:
                actual = original_run([kwargs["env"]["HERMES_PYTHON"], "-c",
                                       "import sys; print(sys.prefix)"], check=True,
                                      stdout=subprocess.PIPE, text=True)
                observed_prefix.append(Path(actual.stdout.strip()))
                kwargs["stdout"].write(b"fixture tests passed\n")
                return subprocess.CompletedProcess(command, 0)
            return original_run(command, *args, **kwargs)

        with mock.patch.object(installer.subprocess, "run", side_effect=runner):
            installer.validate(validate_args)
        self.assertEqual(len(observed_prefix), 1)
        self.assertEqual(observed_prefix[0].resolve(), venv.resolve())
        receipt = json.loads((candidate / ".fleet-overlay-test-receipt.json").read_text())
        self.assertEqual(receipt["test_interpreter"], str(interpreter))
        self.assertEqual(receipt["source_head"], self.base)


if __name__ == "__main__":
    unittest.main()
