import json
import plistlib
import tempfile
import unittest
from pathlib import Path

from device_install_preflight import validate


class DeviceInstallPreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = self.root / "project.yml"
        self.app = self.root / "Info.plist"
        self.inventory = self.root / "apps.json"
        self.project.write_text("CURRENT_PROJECT_VERSION: 83\nMARKETING_VERSION: 0.2.0\n")
        with self.app.open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "com.aiowa.hermesfleet",
                "CFBundleVersion": "83",
                "CFBundleShortVersionString": "0.2.0",
            }, handle)
        self.device_build("82")

    def device_build(self, number):
        apps = [] if number is None else [{
            "bundleIdentifier": "com.aiowa.hermesfleet", "bundleVersion": number,
        }]
        self.inventory.write_text(json.dumps({"result": {"apps": apps}}))

    def check(self, require_match=False):
        return validate(self.project, self.app, self.inventory, require_match)

    def test_upgrade_keeps_existing_install(self):
        self.assertIn("82 → 83", self.check())

    def test_downgrade_is_blocked(self):
        self.device_build("84")
        with self.assertRaisesRegex(ValueError, "downgrade blocked"):
            self.check()

    def test_first_install_and_post_install_verification(self):
        self.device_build(None)
        self.assertIn("first install", self.check())
        with self.assertRaisesRegex(ValueError, "missing after install"):
            self.check(require_match=True)
        self.device_build("83")
        self.assertIn("83 → 83", self.check(require_match=True))

    def test_stale_built_artifact_is_blocked(self):
        with self.app.open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "com.aiowa.hermesfleet",
                "CFBundleVersion": "75",
                "CFBundleShortVersionString": "0.2.0",
            }, handle)
        with self.assertRaisesRegex(ValueError, "does not match project.yml"):
            self.check()

    def test_inventory_must_be_readable(self):
        self.inventory.write_text("{}")
        with self.assertRaisesRegex(ValueError, "missing its apps list"):
            self.check()


if __name__ == "__main__":
    unittest.main()
