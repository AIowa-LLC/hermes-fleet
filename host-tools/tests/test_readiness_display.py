import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import readiness
import qr_display
import build_release


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.runtime, self.home = (self.root / p for p in ("source", "runtime", "home"))
        for path in (self.source, self.runtime, self.home):
            path.mkdir()
        (self.home / "config.yaml").write_text("dashboard: {}\n")
        paths = {}
        for rel in readiness.REQUIRED:
            data = ("synthetic contract for " + rel).encode()
            for root in (self.source, self.runtime):
                target = root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            paths[rel] = {"before_sha256": None, "after_sha256": hashlib.sha256(data).hexdigest()}
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"format": 1, "paths": paths}))
        self.pin = readiness.digest_file(self.manifest)
        self.origin = "https://host.private.ts.net"
        self.receipt = self.root / "observation.json"

    def inspect(self, **kwargs):
        kwargs.setdefault("display_probe", lambda: True)
        return readiness.inspect_readiness(
            self.home, self.runtime, source=self.source, manifest=self.manifest,
            trusted_digest=self.pin, origin=self.origin, approval=self.receipt,
            network_probe=lambda _: True, origin_reader=lambda *_: self.origin, **kwargs)

    def record(self, **changes):
        now = time.time()
        record = {"created_at": now - 1, "expires_at": now + 500,
                  "binding": readiness.approval_binding(self.home, self.runtime, self.origin, self.pin),
                  **{gate: True for gate in readiness.OBSERVED_GATES}, **changes}
        self.receipt.write_text(json.dumps(record))
        self.receipt.chmod(0o600)

    def test_private_dns_is_allowed_but_insecure_ip_and_credential_urls_fail(self):
        self.assertEqual(readiness.normalise_origin(self.origin), self.origin)
        for origin in ("http://host.test", "https://127.0.0.1", "https://localhost",
                       "https://owner:password@host.test", "https://host.test/api", "https://host.test?secret=x"):
            with self.assertRaises(ValueError):
                readiness.normalise_origin(origin)

    def test_static_compatibility_does_not_grant_issue_authority_or_create_store(self):
        before = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*"))
        report = self.inspect()
        self.assertTrue(report["issuer_ready"])
        self.assertTrue(report["runtime_matches"])
        self.assertFalse(report["can_issue"])
        self.assertFalse(report["phone_reachability_verified"])
        self.assertEqual(before, sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*")))

    def test_wrong_runtime_or_missing_source_fails_before_network_probe(self):
        (self.runtime / readiness.REQUIRED[0]).write_text("upstream drift")
        (self.source / readiness.REQUIRED[1]).unlink()
        report = self.inspect()
        self.assertFalse(report["issuer_ready"])
        self.assertFalse(report["runtime_matches"])
        self.assertFalse(report["https_origin_verified"])

    def test_origin_mismatch_fails_closed_before_network(self):
        with patch.object(readiness, "effective_origin", return_value="https://other.test"):
            report = readiness.inspect_readiness(
                self.home, self.runtime, source=self.source, manifest=self.manifest,
                trusted_digest=self.pin, origin=self.origin, approval=self.receipt,
                origin_reader=lambda *_: "https://other.test", network_probe=lambda _: self.fail("must not probe"))
        self.assertFalse(report["home_matches"])
        self.assertFalse(report["https_origin_verified"])

    def test_untrusted_manifest_and_source_symlink_rejected(self):
        with self.assertRaises(ValueError):
            readiness.load_manifest(self.manifest, "0" * 64)
        target = self.source / readiness.REQUIRED[0]
        target.unlink()
        target.symlink_to(self.runtime / readiness.REQUIRED[0])
        self.assertFalse(self.inspect()["issuer_ready"])

    def test_bound_fresh_owner_observations_never_replace_actual_telegram_event(self):
        self.record()
        report = self.inspect()
        self.assertTrue(report["phone_reachability_verified"])
        self.assertTrue(report["local_display_ready"])
        self.assertTrue(report["service_runtime_verified"])
        self.assertFalse(report["can_issue"])
        self.assertEqual(report["blockers"], ["actual_private_numeric_owner_event_and_explicit_issue_request"])

    def test_expired_overlong_world_readable_or_wrong_binding_observations_fail(self):
        now = time.time()
        for changes in ({"expires_at": now - 10}, {"created_at": now - 700, "expires_at": now + 1},
                        {"binding": {}}, {"phone_https_observed": "true"}):
            self.record(**changes)
            self.assertFalse(self.inspect()["phone_reachability_verified"])
        self.record()
        self.receipt.chmod(0o644)
        self.assertFalse(self.inspect()["local_display_ready"])

    def test_config_change_and_symlinked_approval_invalidate_observations(self):
        self.record()
        (self.home / "config.yaml").write_text("dashboard: {changed: true}\n")
        self.assertFalse(self.inspect()["service_runtime_verified"])
        self.record()
        moved = self.root / "receipt-backup"
        self.receipt.rename(moved)
        self.receipt.symlink_to(moved)
        self.assertFalse(self.inspect()["local_display_ready"])

    def test_recent_observation_cannot_authorize_issuance_after_display_becomes_unavailable(self):
        self.record()
        report = self.inspect(display_probe=lambda: False)
        self.assertFalse(report["local_display_ready"])
        self.assertIn("local_display_ready", report["blockers"])
        self.assertFalse((self.home / "dashboard_auth").exists())


class QRDisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identifier = "A" * 22
        self.link = f"https://host.example.test/pair#v=1&i={self.identifier}&s={'B' * 43}"

    def render(self, runner, capability=lambda: True):
        with patch.object(qr_display.shutil, "which", return_value="/trusted/qrencode"):
            return qr_display.render_private(self.link, invitation_id=self.identifier, home=self.root,
                                             runtime_dir=self.root, runner=runner, capability=capability)

    def test_bearer_only_on_stdin_and_png_is_private_then_deleted(self):
        seen = []
        def run(argv, **kwargs):
            self.assertTrue(all(self.link not in arg and "B" * 43 not in arg for arg in argv))
            if argv[0] == "/trusted/qrencode":
                self.assertEqual(kwargs["input"], self.link.encode())
                image = Path(argv[-1])
                self.assertEqual(image.stat().st_mode & 0o777, 0o600)
                self.assertEqual(image.parent.stat().st_mode & 0o777, 0o700)
                image.write_bytes(b"synthetic PNG")
                seen.append(image)
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        self.assertTrue(self.render(run))
        self.assertFalse(seen[0].exists())

    def test_no_display_means_no_renderer_execution(self):
        with self.assertRaises(qr_display.DisplayFailure):
            self.render(lambda *_args, **_kw: self.fail("no process may run"), capability=lambda: False)

    def test_failed_renderer_or_expiry_cleans_up_and_redacts_exception(self):
        images = []
        def run(argv, **kwargs):
            if argv[0] == "/trusted/qrencode":
                image = Path(argv[-1]); image.write_bytes(b"synthetic PNG"); images.append(image)
                return subprocess.CompletedProcess(argv, 0)
            raise subprocess.TimeoutExpired(argv, 600, output=self.link)
        with self.assertRaises(qr_display.DisplayFailure) as failure:
            self.render(run)
        self.assertNotIn("B" * 43, str(failure.exception))
        self.assertFalse(images[0].exists())

    def test_malformed_link_fails_before_process(self):
        for link in (self.link + "&s=other", self.link.replace("https://", "http://"),
                     self.link.replace(self.identifier, "wrong", 1)):
            with self.assertRaises(qr_display.DisplayFailure):
                qr_display.validate_link(link, self.identifier)


class PackageHelperTests(unittest.TestCase):
    def test_packaging_refreshes_helpers_without_touching_other_plugin_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "owner_control"; package.mkdir()
            sentinel = package / "unchanged.py"; sentinel.write_text("preserved")
            for name in ("readiness.py", "qr_display.py"):
                (root / name).write_text("new maintained source")
                (package / name).write_text("old package copy")
            build_release.sync_plugin_helpers(root)
            self.assertEqual(sentinel.read_text(), "preserved")
            for name in ("readiness.py", "qr_display.py"):
                self.assertEqual((package / name).read_bytes(), (root / name).read_bytes())
            (package / "readiness.py").unlink()
            (package / "readiness.py").symlink_to(sentinel)
            with self.assertRaises(RuntimeError):
                build_release.sync_plugin_helpers(root)
            self.assertEqual(sentinel.read_text(), "preserved")


if __name__ == "__main__":
    unittest.main()
