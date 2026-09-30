#!/usr/bin/env python3
"""Contracts for per-worktree lane simulators with a stubbed `xcrun simctl`.

No simulator is created or touched: a stateful stub stands in for xcrun and
real temporary git worktrees provide the worktree identity. These tests are
not product acceptance evidence.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

STUB_XCRUN = r'''#!/usr/bin/env python3
import json, os, sys, uuid
from pathlib import Path
args = sys.argv[1:]
state_path = Path(os.environ["STUB_STATE"])
state = json.loads(state_path.read_text())
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
def save():
    state_path.write_text(json.dumps(state))
if args[:3] == ["simctl", "list", "devicetypes"]:
    print("== Device Types ==")
    for name, ident in [
        ("iPhone 4s", "iPhone-4s"), ("iPhone 16", "iPhone-16"),
        ("iPhone 17 Pro", "iPhone-17-Pro"), ("iPhone Air", "iPhone-Air"),
        ("iPad Pro 11-inch (M4) (16GB)", "iPad-Pro-11-inch-M4-16GB"),
        ("iPad Pro 11-inch (M5)", "iPad-Pro-11-inch-M5-12GB"),
    ]:
        print(f"{name} (com.apple.CoreSimulator.SimDeviceType.{ident})")
elif args[:3] == ["simctl", "list", "runtimes"]:
    print("== Runtimes ==")
    print("iOS 9.3 (9.3 - 13E233) - com.apple.CoreSimulator.SimRuntime.iOS-9-3")
    print("iOS 27.0 (27.0 - 24A434) - com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    print("iOS 26.4 (26.4 - 23E244) - com.apple.CoreSimulator.SimRuntime.iOS-26-4")
    print("watchOS 27.0 (27.0 - 24R1) - com.apple.CoreSimulator.SimRuntime.watchOS-27-0")
elif args[:3] == ["simctl", "list", "devices"]:
    print("== Devices ==")
    print("-- iOS 27.0 --")
    for device in state["devices"]:
        print(f"    {device['name']} ({device['udid']}) ({device['state']})")
elif args[:2] == ["simctl", "create"]:
    name, dtype, runtime = args[2:5]
    state["counter"] += 1
    udid = str(uuid.UUID(int=state["counter"])).upper()
    state["devices"].append({"name": name, "udid": udid, "state": "Shutdown",
                             "type": dtype, "runtime": runtime})
    save()
    print(udid)
elif args[:2] == ["simctl", "boot"]:
    for device in state["devices"]:
        if device["udid"] == args[2]:
            if device["state"] == "Booted":
                sys.exit(149)
            device["state"] = "Booted"
    save()
elif args[:2] == ["simctl", "shutdown"]:
    for device in state["devices"]:
        if device["udid"] == args[2]:
            device["state"] = "Shutdown"
    save()
elif args[:2] == ["simctl", "delete"]:
    state["devices"] = [d for d in state["devices"] if d["udid"] != args[2]]
    save()
else:
    sys.exit(26)
'''

FOREIGN = [
    {"name": "Fleet-other-lane", "udid": "F0000000-0000-0000-0000-000000000001", "state": "Booted"},
    {"name": "HF-legacy", "udid": "F0000000-0000-0000-0000-000000000002", "state": "Shutdown"},
    {"name": "iPhone 17 Pro", "udid": "F0000000-0000-0000-0000-000000000003", "state": "Shutdown"},
    {"name": "HF-deadbeef-extra", "udid": "F0000000-0000-0000-0000-000000000004", "state": "Shutdown"},
]
ORPHAN = {"name": "HF-deadbeef", "udid": "F0000000-0000-0000-0000-000000000005", "state": "Shutdown"}


class LaneSimulatorContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="fleet-lane-sim-")
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.bin = base / "bin"
        self.bin.mkdir()
        xcrun = self.bin / "xcrun"
        xcrun.write_text(STUB_XCRUN)
        xcrun.chmod(0o755)
        self.state = base / "state.json"
        self.log = base / "calls.jsonl"
        self.set_devices([dict(d) for d in FOREIGN])
        self.env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                        STUB_STATE=str(self.state), STUB_LOG=str(self.log))
        self.env.pop("HERMES_FLEET_LANE_SIM_IPHONE_TYPE", None)
        self.env.pop("HERMES_FLEET_LANE_SIM_IPAD_TYPE", None)
        # Two real worktrees of one throwaway repository.
        self.repo = base / "repo-main"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "README").write_text("fixture\n")
        self.git(self.repo, "add", "README")
        self.git(self.repo, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-q", "-m", "fixture")
        self.second = base / "repo-second"
        self.git(self.repo, "worktree", "add", "-q", "-b", "second", str(self.second))
        for tree in (self.repo, self.second):
            self.install(tree)

    def install(self, tree: Path) -> None:
        (tree / "scripts").mkdir(parents=True, exist_ok=True)
        for name in ("lane_simulator.sh", "sim_destination.sh"):
            shutil.copy2(ROOT / "scripts" / name, tree / "scripts" / name)

    def git(self, cwd: Path, *args: str) -> None:
        subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)

    def set_devices(self, devices: list) -> None:
        self.state.write_text(json.dumps({"counter": 100, "devices": devices}))

    def devices(self) -> list:
        return json.loads(self.state.read_text())["devices"]

    def names(self) -> list:
        return [d["name"] for d in self.devices()]

    def calls(self) -> list:
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def lane(self, tree: Path, *args: str, **env):
        return subprocess.run(["bash", str(tree / "scripts/lane_simulator.sh"), *args],
                              cwd=tree, env=dict(self.env, **env), text=True, capture_output=True, timeout=30)

    def test_ensure_twice_returns_same_udid_and_creates_once(self):
        first = self.lane(self.repo, "ensure")
        second = self.lane(self.repo, "ensure")
        self.assertEqual((first.returncode, second.returncode), (0, 0), first.stderr + second.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertRegex(first.stdout.strip(), r"^[0-9A-F-]{36}$")
        self.assertEqual(sum(c[:2] == ["simctl", "create"] for c in self.calls()), 1)

    def test_create_uses_chosen_iphone_type_and_newest_runtime(self):
        self.lane(self.repo, "ensure")
        create = next(c for c in self.calls() if c[:2] == ["simctl", "create"])
        self.assertRegex(create[2], r"^HF-[0-9a-f]{8}$")
        self.assertEqual(create[3], "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        self.assertEqual(create[4], "com.apple.CoreSimulator.SimRuntime.iOS-27-0")

    def test_missing_preferred_type_falls_back_to_newest_similar(self):
        self.lane(self.repo, "ensure", HERMES_FLEET_LANE_SIM_IPHONE_TYPE="iPhone 99 Imaginary")
        create = next(c for c in self.calls() if c[:2] == ["simctl", "create"])
        self.assertEqual(create[3], "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")

    def test_second_worktree_gets_a_different_simulator(self):
        a = self.lane(self.repo, "ensure")
        b = self.lane(self.second, "ensure")
        self.assertEqual((a.returncode, b.returncode), (0, 0), a.stderr + b.stderr)
        self.assertNotEqual(a.stdout, b.stdout)
        self.assertNotEqual(self.lane(self.repo, "id").stdout, self.lane(self.second, "id").stdout)

    def test_names_output_and_logs_never_contain_local_paths(self):
        outputs = [self.lane(tree, *args) for tree in (self.repo, self.second)
                   for args in (("ensure",), ("ensure", "ipad"), ("list",), ("id",))]
        blob = "".join(o.stdout + o.stderr for o in outputs) + " ".join(self.names())
        blob += self.log.read_text()
        for needle in (self.tmp.name, "repo-main", "repo-second", os.environ.get("USER", "\0")):
            self.assertNotIn(needle, blob)
        for name in self.names():
            if name not in {d["name"] for d in FOREIGN}:
                self.assertRegex(name, r"^HF-[0-9a-f]{8}(-iPad)?$")

    def test_ipad_family_gets_its_own_device(self):
        phone = self.lane(self.repo, "ensure").stdout
        pad = self.lane(self.repo, "ensure", "ipad")
        self.assertEqual(pad.returncode, 0, pad.stderr)
        self.assertNotEqual(phone, pad.stdout)
        self.assertEqual(pad.stdout, self.lane(self.repo, "ensure", "ipad").stdout)
        creates = [c for c in self.calls() if c[:2] == ["simctl", "create"]]
        self.assertTrue(creates[1][2].endswith("-iPad"))
        self.assertEqual(creates[1][3], "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB")

    def test_boot_on_demand_boots_once(self):
        first = self.lane(self.repo, "ensure", "--boot")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.lane(self.repo, "ensure", "--boot")
        self.assertEqual(sum(c[:2] == ["simctl", "boot"] for c in self.calls()), 1)
        own = next(d for d in self.devices() if d["udid"] == first.stdout.strip())
        self.assertEqual(own["state"], "Booted")

    def test_shutdown_and_delete_only_touch_this_worktree(self):
        mine = self.lane(self.repo, "ensure", "--boot").stdout.strip()
        other = self.lane(self.second, "ensure", "--boot").stdout.strip()
        self.assertEqual(self.lane(self.repo, "shutdown").returncode, 0)
        states = {d["udid"]: d["state"] for d in self.devices()}
        self.assertEqual((states[mine], states[other]), ("Shutdown", "Booted"))
        self.assertEqual(states[FOREIGN[0]["udid"]], "Booted")
        self.lane(self.repo, "ensure", "ipad")
        self.assertEqual(self.lane(self.repo, "delete").returncode, 0)
        remaining = {d["udid"] for d in self.devices()}
        self.assertNotIn(mine, remaining)
        self.assertIn(other, remaining)
        self.assertEqual(len(remaining), len(FOREIGN) + 1)

    def test_gc_removes_only_orphaned_hf_devices(self):
        self.lane(self.repo, "ensure")
        self.lane(self.repo, "ensure", "ipad")
        gone = self.lane(self.second, "ensure").stdout.strip()
        gone_ipad = self.lane(self.second, "ensure", "ipad").stdout.strip()
        live_second = self.lane(self.repo, "ensure").stdout.strip()
        self.set_devices(self.devices() + [dict(ORPHAN)])
        before = {d["udid"] for d in self.devices()}
        # A live second worktree keeps its simulators.
        result = self.lane(self.repo, "gc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before - {d["udid"] for d in self.devices()}, {ORPHAN["udid"]})
        # Once that worktree is removed its simulators are collected.
        self.git(self.repo, "worktree", "remove", "--force", str(self.second))
        result = self.lane(self.repo, "gc")
        self.assertEqual(result.returncode, 0, result.stderr)
        remaining = {d["udid"] for d in self.devices()}
        self.assertEqual(before - remaining, {ORPHAN["udid"], gone, gone_ipad})
        self.assertIn(live_second, remaining)
        for foreign in FOREIGN:
            self.assertIn(foreign["udid"], remaining)
        deleted = [c[2] for c in self.calls() if c[:2] == ["simctl", "delete"]]
        self.assertEqual(sorted(deleted), sorted([ORPHAN["udid"], gone, gone_ipad]))

    def test_gc_dry_run_deletes_nothing(self):
        self.set_devices(self.devices() + [dict(ORPHAN)])
        result = self.lane(self.repo, "gc", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would delete HF-deadbeef", result.stderr)
        self.assertFalse(any(c[:2] == ["simctl", "delete"] for c in self.calls()))

    def test_gc_fails_closed_when_worktrees_cannot_be_listed(self):
        outside = Path(self.tmp.name) / "not-a-repo"
        self.install(outside)
        self.set_devices(self.devices() + [dict(ORPHAN)])
        result = self.lane(outside, "gc", GIT_CEILING_DIRECTORIES=self.tmp.name)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["simctl", "delete"] for c in self.calls()))

    def test_list_reports_owner_without_paths(self):
        self.lane(self.repo, "ensure")
        self.lane(self.second, "ensure")
        self.set_devices(self.devices() + [dict(ORPHAN)])
        rows = [line.split("\t") for line in self.lane(self.repo, "list").stdout.splitlines()]
        owners = sorted(r[3] for r in rows)
        self.assertEqual(owners, ["orphaned", "other-worktree", "this-worktree"])


class DestinationSelectionContracts(unittest.TestCase):
    """Precedence of sim_destination.sh: explicit UDID > lane > default."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="fleet-sim-dest-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts/sim_destination.sh", scripts / "sim_destination.sh")
        (scripts / "lane_simulator.sh").write_text(
            '#!/bin/bash\n[ "$1" = ensure ] && echo "LANE-$2"\n')
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        xcrun = bin_dir / "xcrun"
        xcrun.write_text("#!/bin/sh\nprintf '    iPhone Fixture (UDID) (Shutdown)\\n'\n")
        xcrun.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("HERMES_FLEET_") and k != "CI"}
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{self.env['PATH']}"

    def dest(self, *args: str, **env) -> str:
        result = subprocess.run(["bash", "scripts/sim_destination.sh", *args], cwd=self.root,
                                env=dict(self.env, **env), text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_iphone_precedence(self):
        self.assertEqual(self.dest("iphone"), "platform=iOS Simulator,name=iPhone Fixture,OS=latest")
        self.assertEqual(self.dest("iphone", CI="true"), "platform=iOS Simulator,name=iPhone Fixture,OS=latest")
        self.assertEqual(self.dest("iphone", HERMES_FLEET_LANE_SIM="1"), "platform=iOS Simulator,id=LANE-iphone")
        self.assertEqual(self.dest("iphone", HERMES_FLEET_LANE_SIM="1", HERMES_FLEET_SIM_UDID="EXPLICIT"),
                         "platform=iOS Simulator,id=EXPLICIT")
        self.assertEqual(self.dest("iphone", HERMES_FLEET_SIM_UDID="EXPLICIT"), "platform=iOS Simulator,id=EXPLICIT")

    def test_makefile_default_destination_needs_no_simulator_query(self):
        default = "platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
        self.assertEqual(self.dest("iphone", "--default-dest", default), default)
        self.assertEqual(self.dest("iphone", "--default-dest", default, HERMES_FLEET_SIM_UDID="EXPLICIT"),
                         "platform=iOS Simulator,id=EXPLICIT")

    def test_ipad_precedence(self):
        self.assertEqual(self.dest("ipad"), "platform=iOS Simulator,name=iPad Pro 11-inch (M5)")
        self.assertEqual(self.dest("ipad", HERMES_FLEET_LANE_SIM="1"), "platform=iOS Simulator,id=LANE-ipad")
        self.assertEqual(self.dest("ipad", HERMES_FLEET_IPAD_DESTINATION="iPad Custom", HERMES_FLEET_LANE_SIM="1"),
                         "platform=iOS Simulator,name=iPad Custom")
        self.assertEqual(self.dest("ipad", HERMES_FLEET_IPAD_SIM_UDID="PAD", HERMES_FLEET_IPAD_DESTINATION="iPad Custom"),
                         "platform=iOS Simulator,id=PAD")
        # The iPhone UDID override must never be applied to the iPad family.
        self.assertEqual(self.dest("ipad", HERMES_FLEET_SIM_UDID="PHONE"), "platform=iOS Simulator,name=iPad Pro 11-inch (M5)")

    def test_dev_check_defaults_lane_simulator_on_locally_and_off_in_ci(self):
        source = (ROOT / "scripts/dev_check.sh").read_text()
        self.assertRegex(source, r'"\$\{CI:-\}" = true \]; then HERMES_FLEET_LANE_SIM=0; else HERMES_FLEET_LANE_SIM=1')
        self.assertIn("export HERMES_FLEET_LANE_SIM", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
