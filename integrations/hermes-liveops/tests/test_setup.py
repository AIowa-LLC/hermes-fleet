import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from ruamel.yaml import YAML

BASE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fleet_setup", BASE / "setup/setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
builder_spec = importlib.util.spec_from_file_location("fleet_bundle", BASE.parents[1] / "scripts/build_liveops_bundle.py")
builder = importlib.util.module_from_spec(builder_spec)
builder_spec.loader.exec_module(builder)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "hermes"
        self.root.mkdir()
        self.original = b'# retained comment\nplugins:\n  enabled: [existing]\n  disabled: [fleet-liveops, other]\nprovider:\n  api_key: "${SYNTHETIC_API_KEY}"\n'
        (self.root / "config.yaml").write_bytes(self.original)
        (self.root / "config.yaml").chmod(0o640)
        for name in ("development", "untouched"):
            path = self.root / "profiles" / name
            path.mkdir(parents=True)
            (path / "config.yaml").write_bytes(self.original)
        self.bundle = self.base / "bundle"
        self.plugin = self.bundle / "plugin"
        for name in setup.RUNTIME_FILES:
            path = self.plugin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((BASE / name).read_bytes())
        self.manifest = {"version": setup.VERSION, "files": {name:
            hashlib.sha256((self.plugin / name).read_bytes()).hexdigest() for name in setup.RUNTIME_FILES}}
        (self.bundle / "release.json").write_text(json.dumps(self.manifest))

    def install(self, selected=("development",), scanner=lambda plugin: None):
        return setup.install(self.root, setup.verify_bundle(self.bundle), list(selected), YAML, scanner)

    def test_selected_profiles_preserve_comments_env_references_and_other_plugins(self):
        self.assertTrue(self.install())
        for path in (self.root / "config.yaml", self.root / "profiles/development/config.yaml"):
            raw = path.read_bytes()
            self.assertIn(b"# retained comment", raw)
            self.assertIn(b'"${SYNTHETIC_API_KEY}"', raw)
            config = YAML(typ="safe").load(raw)
            self.assertEqual(config["plugins"]["enabled"], ["existing", "fleet-liveops"])
            self.assertEqual(config["plugins"]["disabled"], ["other"])
        self.assertEqual((self.root / "profiles/untouched/config.yaml").read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE((self.root / "config.yaml").stat().st_mode), 0o640)
        backups = list((self.root / "backups").glob("fleet-liveops-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "development.yaml").read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o700)
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in backups[0].glob("*.yaml")))

    def test_repeat_install_is_noop_and_can_enable_newly_created_profile(self):
        self.install()
        before = (self.root / "config.yaml").read_bytes()
        self.assertFalse(self.install())
        self.assertEqual(len(list((self.root / "backups").glob("fleet-liveops-*"))), 1)
        self.assertEqual((self.root / "config.yaml").read_bytes(), before)
        self.assertTrue(self.install(("untouched",)))

    def test_bundle_corruption_extra_files_and_symlinks_are_rejected(self):
        file = self.plugin / "dashboard/index.js"
        original = file.read_bytes()
        file.write_text("modified")
        with self.assertRaises(setup.SetupError): setup.verify_bundle(self.bundle)
        file.write_bytes(original)
        extra = self.plugin / "extra.py"
        extra.write_text("unexpected")
        with self.assertRaises(setup.SetupError): setup.verify_bundle(self.bundle)
        extra.unlink()
        file.unlink()
        file.symlink_to(self.root / "config.yaml")
        with self.assertRaises(setup.SetupError): setup.verify_bundle(self.bundle)

    def test_manifest_cannot_select_paths_outside_runtime_allowlist(self):
        self.manifest["files"]["../config.yaml"] = "ignored"
        (self.bundle / "release.json").write_text(json.dumps(self.manifest))
        with self.assertRaises(setup.SetupError): self.install()
        self.assertFalse((self.root / "plugins").exists())

    def test_blocked_scan_and_invalid_config_do_not_mutate_installation(self):
        def blocked(plugin): raise setup.SetupError("Synthetic scan rejection")
        with self.assertRaises(setup.SetupError): self.install(scanner=blocked)
        self.assertFalse((self.root / "plugins").exists())
        bad = self.root / "profiles/development/config.yaml"
        bad.write_text("plugins: [not-a-mapping]\n")
        with self.assertRaises(setup.SetupError): self.install()
        self.assertFalse((self.root / "plugins").exists())
        self.assertEqual((self.root / "config.yaml").read_bytes(), self.original)

    def test_symlink_config_and_plugin_directory_are_rejected(self):
        cfg = self.root / "profiles/development/config.yaml"
        cfg.unlink(); cfg.symlink_to(self.root / "config.yaml")
        with self.assertRaises(setup.SetupError): self.install()
        cfg.unlink(); cfg.write_bytes(self.original)
        (self.root / "plugins").symlink_to(self.base)
        with self.assertRaises(setup.SetupError): self.install()
        self.assertEqual((self.root / "config.yaml").read_bytes(), self.original)

    def test_mid_transaction_failure_restores_plugin_and_written_settings(self):
        old = self.root / "plugins/fleet-liveops"
        old.mkdir(parents=True)
        (old / "plugin.yaml").write_text("name: fleet-liveops\nversion: 0.1.0\n")
        (old / "sentinel").write_text("previous plugin")
        real_write = setup.write_atomic
        failed = False
        def failing_write(path, data, mode):
            nonlocal failed
            if path == self.root / "config.yaml" and not failed:
                failed = True
                raise OSError("Synthetic disk failure")
            real_write(path, data, mode)
        with patch.object(setup, "write_atomic", failing_write):
            with self.assertRaises(setup.SetupError): self.install()
        self.assertTrue(failed)
        self.assertEqual((old / "sentinel").read_text(), "previous plugin")
        self.assertEqual((self.root / "profiles/development/config.yaml").read_bytes(), self.original)
        self.assertEqual((self.root / "config.yaml").read_bytes(), self.original)

    def test_concurrent_settings_edit_is_retained_and_install_is_refused(self):
        edited = b"plugins: {enabled: [new-choice]}\n"
        def edit_during_scan(plugin): (self.root / "config.yaml").write_bytes(edited)
        with self.assertRaises(setup.SetupError): self.install(scanner=edit_during_scan)
        self.assertEqual((self.root / "config.yaml").read_bytes(), edited)
        self.assertFalse((self.root / "plugins/fleet-liveops").exists())

    def test_downgrade_unknown_profile_and_missing_root_are_refused(self):
        with self.assertRaises(setup.SetupError): self.install(("missing",))
        old = self.root / "plugins/fleet-liveops"
        old.mkdir(parents=True)
        (old / "plugin.yaml").write_text("version: 9.0.0\n")
        with self.assertRaises(setup.SetupError): self.install()
        self.assertEqual((self.root / "config.yaml").read_bytes(), self.original)
        with self.assertRaises(setup.SetupError): setup.discover_profiles(self.base / "missing")

    def test_bundle_build_is_deterministic_and_extracted_runtime_installs(self):
        import zipfile
        repo = BASE.parents[1]
        def read(path): return (repo / path).read_bytes()
        one = builder.build("a" * 40, self.base / "one", read)
        two = builder.build("a" * 40, self.base / "two", read)
        self.assertEqual(one.read_bytes(), two.read_bytes())
        extracted = self.base / "extracted"
        with zipfile.ZipFile(one) as z: z.extractall(extracted)
        release = extracted / ("Fleet-Live-Reporting-" + setup.VERSION)
        plugin = setup.verify_bundle(release)
        self.assertTrue(setup.install(self.root, plugin, ["development"], YAML, lambda plugin: None))

    def test_scanner_requires_explicit_approval_and_refuses_unavailable_scanner(self):
        import sys
        from types import ModuleType
        guard = ModuleType("tools.plugin_guard")
        guard.scan_plugin = lambda plugin, source: object()
        guard.should_allow_plugin_install = lambda result, force: (True, "synthetic approval")
        with patch.dict(sys.modules, {"tools": ModuleType("tools"), "tools.plugin_guard": guard}):
            setup.runtime_scanner(self.plugin)
            for verdict in (False, None):
                guard.should_allow_plugin_install = lambda result, force: (verdict, "synthetic rejection")
                with self.assertRaises(setup.SetupError): setup.runtime_scanner(self.plugin)
        with patch.dict(sys.modules, {"tools.plugin_guard": None}):
            with self.assertRaises(ImportError): setup.runtime_scanner(self.plugin)

    def test_cli_installs_extracted_bundle_and_refuses_unreviewed_noninteractive_selection(self):
        import os
        import subprocess
        import sys
        sdk = self.base / "synthetic-sdk"
        (sdk / "tools").mkdir(parents=True)
        (sdk / "tools/__init__.py").write_text("")
        (sdk / "tools/plugin_guard.py").write_text(
            'def scan_plugin(plugin, source): return object()\n'
            'def should_allow_plugin_install(result, force=False): return True, "synthetic approval"\n')
        (sdk / "hermes_constants.py").write_text(
            'import os\nfrom pathlib import Path\n'
            'def get_default_hermes_root(): return Path(os.environ["HERMES_HOME"])\n')
        env = {**os.environ, "PYTHONPATH": str(sdk), "HERMES_HOME": str(self.root),
               "HERMES_FLEET_SETUP_PYTHON": sys.executable}
        (self.bundle / "setup.py").write_bytes((BASE / "setup/setup.py").read_bytes())
        command = [sys.executable, str(self.bundle / "setup.py"), "--hermes-root", str(self.root)]
        rejected = subprocess.run(command + ["--yes"], env=env, capture_output=True, text=True)
        self.assertEqual(rejected.returncode, 1)
        self.assertFalse((self.root / "plugins").exists())
        installed = subprocess.run(command + ["--profiles", "development", "--yes"], env=env, capture_output=True, text=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertIn("Setup complete", installed.stdout)
        self.assertNotIn("SYNTHETIC_API_KEY", installed.stdout + installed.stderr)
        self.assertTrue((self.root / "plugins/fleet-liveops/plugin.yaml").exists())
        launcher = self.bundle / "Setup.command"
        launcher.write_bytes((BASE / "setup/Setup.command").read_bytes())
        repeated = subprocess.run(["bash", str(launcher), "--hermes-root", str(self.root),
            "--profiles", "development", "--yes"], env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertIn("already installed", repeated.stdout)


if __name__ == "__main__": unittest.main()
