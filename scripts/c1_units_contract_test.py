#!/usr/bin/env python3
"""Mocked hosted-unit diagnostic contracts; not simulator acceptance evidence."""
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
LANE_UDID = "11111111-2222-3333-4444-555555555555"
EXPLICIT_UDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
MOCK_XCODE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args == ["-version"]:
    print("Xcode synthetic\nBuild version fixture")
    sys.exit(0)
Path(os.environ["MOCK_ARGS"]).write_text(json.dumps(args))
mode = os.environ.get("MOCK_MODE", "success")
if mode == "infrastructure":
    print("error: synthetic simulator unavailable")
    sys.exit(70)
result = Path(args[args.index("-resultBundlePath") + 1])
result.mkdir()
(result / "fixture.txt").write_text("Synthetic fixture, not an xcresult.")
if mode == "failure":
    print("Test Case '-[FixtureTests testEarlyFailure]' failed (0.001 seconds).")
    for index in range(60):
        print(f"Test Suite 'PassingFixture{index}' passed")
    print("Executed 3 tests, with 1 failure (0 unexpected)")
    sys.exit(65)
print("Executed 3 tests, with 0 failures (0 unexpected)")
'''


class HostedUnitDiagnosticsContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-unit-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(ROOT / "scripts/c1_units.sh", scripts / "c1_units.sh")
        shutil.copy2(ROOT / "scripts/sim_destination.sh", scripts / "sim_destination.sh")
        # Selection contract only: the real lane simulator has its own tests.
        (scripts / "lane_simulator.sh").write_text(
            f"#!/bin/bash\n[ \"$1\" = ensure ] && echo {LANE_UDID}\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        commands = {
            "xcrun": "#!/bin/sh\nprintf '    iPhone 17 Pro (fixture) (Shutdown)\\n'\n",
            "git": "#!/bin/sh\nprintf 'synthetic-source-sha\\n'\n",
            "xcodebuild": MOCK_XCODE,
        }
        for name, content in commands.items():
            executable = self.bin / name
            executable.write_text(content)
            executable.chmod(0o755)
        self.results = self.root / "runner temporary files"
        self.results.mkdir()
        self.output = self.root / "step-output.txt"
        self.args_path = self.root / "args.json"
        self.env = dict(os.environ)
        self.env.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            RUNNER_TEMP=str(self.results),
            GITHUB_OUTPUT=str(self.output),
            MOCK_ARGS=str(self.args_path),
        )

    def invoke(self, mode: str = "success", *, local: bool = False, **extra_env):
        env = dict(self.env, MOCK_MODE=mode, **extra_env)
        if local:
            env.pop("GITHUB_OUTPUT", None)
        result = subprocess.run(
            ["bash", str(self.root / "scripts/c1_units.sh")],
            cwd=self.root, env=env, text=True, capture_output=True, timeout=15,
        )
        match = re.search(r"diagnostics: (.+)", result.stdout)
        directory = Path(match.group(1)) if match else None
        return result, directory

    def test_success_keeps_bundle_log_metadata_and_existing_test_scope(self):
        result, directory = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNotNone(directory)
        self.assertTrue((directory / "units.xcresult").is_dir())
        self.assertIn("0 failures", (directory / "xcodebuild.log").read_text())
        metadata = (directory / "metadata.txt").read_text()
        self.assertIn("source_sha=synthetic-source-sha", metadata)
        self.assertIn("Xcode synthetic", metadata)
        args = json.loads(self.args_path.read_text())
        self.assertEqual([a for a in args if a.startswith("-only-testing:")],
                         ["-only-testing:HermesFleetAppTests"])
        self.assertIn("-skipMacroValidation", args)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", args)
        self.assertEqual(self.output.read_text(), f"diagnostics_dir={directory}\n")

    def destination(self) -> str:
        args = json.loads(self.args_path.read_text())
        return args[args.index("-destination") + 1]

    def test_default_selection_is_first_available_iphone(self):
        result, directory = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.destination(), "platform=iOS Simulator,name=iPhone 17 Pro,OS=latest")
        metadata = (directory / "metadata.txt").read_text()
        self.assertIn("simulator_selection=default", metadata)
        self.assertIn("simulator_udid=unspecified", metadata)

    def test_ci_true_keeps_default_selection(self):
        result, _ = self.invoke(CI="true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.destination(), "platform=iOS Simulator,name=iPhone 17 Pro,OS=latest")

    def test_lane_simulator_selected_when_opted_in(self):
        result, directory = self.invoke(HERMES_FLEET_LANE_SIM="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.destination(), f"platform=iOS Simulator,id={LANE_UDID}")
        metadata = (directory / "metadata.txt").read_text()
        self.assertIn("simulator_selection=lane", metadata)
        self.assertIn(f"simulator_udid={LANE_UDID}", metadata)

    def test_explicit_udid_overrides_lane_simulator(self):
        result, directory = self.invoke(HERMES_FLEET_LANE_SIM="1", HERMES_FLEET_SIM_UDID=EXPLICIT_UDID)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.destination(), f"platform=iOS Simulator,id={EXPLICIT_UDID}")
        self.assertIn(f"simulator_udid={EXPLICIT_UDID}", (directory / "metadata.txt").read_text())

    def test_failed_lane_simulator_fails_closed_before_xcode(self):
        (self.root / "scripts/lane_simulator.sh").write_text("#!/bin/bash\nexit 1\n")
        result, _ = self.invoke(HERMES_FLEET_LANE_SIM="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.args_path.exists())

    def test_failure_keeps_early_failed_case_visible_and_stays_failed(self):
        result, directory = self.invoke("failure")
        self.assertEqual(result.returncode, 1)
        self.assertIn("testEarlyFailure", result.stdout)
        self.assertTrue((directory / "units.xcresult").is_dir())
        self.assertIn("PassingFixture59", (directory / "xcodebuild.log").read_text())
        self.assertIn(str(directory), self.output.read_text())

    def test_infrastructure_failure_retains_log_without_fabricating_bundle(self):
        result, directory = self.invoke("infrastructure")
        self.assertEqual(result.returncode, 1)
        self.assertFalse((directory / "units.xcresult").exists())
        self.assertIn("simulator unavailable", (directory / "xcodebuild.log").read_text())
        self.assertTrue((directory / "metadata.txt").exists())

    def test_repeated_runs_never_overwrite_prior_evidence(self):
        first, first_dir = self.invoke("failure")
        before = (first_dir / "xcodebuild.log").read_bytes()
        second, second_dir = self.invoke()
        self.assertEqual((first.returncode, second.returncode), (1, 0))
        self.assertNotEqual(first_dir, second_dir)
        self.assertEqual((first_dir / "xcodebuild.log").read_bytes(), before)

    def test_local_run_does_not_require_github_output(self):
        result, directory = self.invoke(local=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((directory / "xcodebuild.log").exists())
        self.assertFalse(self.output.exists())

    def test_missing_result_root_fails_before_running_tests(self):
        self.env["RUNNER_TEMP"] = str(self.root / "missing-root")
        result, directory = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(directory)
        self.assertFalse(self.args_path.exists())

    def test_workflow_upload_is_exact_directory_and_runs_after_failure(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        units = workflow.split("\n  units:\n", 1)[1].split("\n  critical-smoke:", 1)[0]
        self.assertIn("id: unit_tests", units)
        self.assertIn("if: always() && steps.unit_tests.outputs.diagnostics_dir != ''", units)
        self.assertIn("path: ${{ steps.unit_tests.outputs.diagnostics_dir }}", units)
        self.assertIn("unit-test-diagnostics-attempt-${{ github.run_attempt }}", units)
        self.assertIn("uses: actions/upload-artifact@v4", units)
        self.assertIn("retention-days: 7", units)
        self.assertNotIn("path: /tmp/", units)


if __name__ == "__main__":
    unittest.main(verbosity=2)
