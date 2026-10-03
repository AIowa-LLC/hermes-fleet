#!/usr/bin/env python3
"""Failure injection for owned process groups and Xcode progress detection."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from xcode_progress_watchdog import run


class WatchdogTests(unittest.TestCase):
    def execute(self, source, timeout=.4):
        with tempfile.TemporaryDirectory() as directory:
            log, report = Path(directory) / "xcode.log", Path(directory) / "watchdog.json"
            code = run([sys.executable, "-u", "-c", source], log, report, timeout, poll=.02)
            return code, log.read_text(), json.loads(report.read_text())

    def test_silent_launch_stops_and_preserves_partial_output(self):
        code, log, report = self.execute("import time; print('launch diagnostic'); time.sleep(30)")
        self.assertEqual(code, 124)
        self.assertIn("launch diagnostic", log)
        self.assertTrue(report["timed_out"])
        self.assertLess(report["elapsed_seconds"], 3)

    def test_repeated_app_logs_do_not_count_as_test_progress(self):
        code, log, report = self.execute("import time\nwhile True:\n print('app startup log', flush=True)\n time.sleep(.05)")
        self.assertEqual(code, 124)
        self.assertGreater(log.count("app startup log"), 2)

    def test_slow_but_progressing_test_keeps_its_full_budget(self):
        code, log, report = self.execute("import time\nfor i in range(10):\n print(f'    t = {i}.00s Find element', flush=True)\n time.sleep(.1)\nprint(\"Test Case '-[Fixture testSlow]' passed\")")
        self.assertEqual(code, 0)
        self.assertFalse(report["timed_out"])
        self.assertGreater(report["elapsed_seconds"], .9)

    def test_product_failure_exit_status_is_preserved_without_retry(self):
        code, log, report = self.execute("import sys; print(\"Test Case '-[Fixture testBug]' failed\"); sys.exit(17)")
        self.assertEqual(code, 17)
        self.assertFalse(report["timed_out"])

    def test_previous_progress_marker_cannot_refresh_deadline(self):
        code, log, report = self.execute("import time\nprint(\"Test Case '-[Fixture testStall]' started\")\nwhile True:\n print('noise', flush=True)\n time.sleep(.05)")
        self.assertEqual(code, 124)
        self.assertLess(report["elapsed_seconds"], 3)

    def test_stalled_child_group_does_not_signal_another_lane(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); pid_file = root / 'child.pid'
                child = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"
                source = (f"import subprocess,sys,time; from pathlib import Path; "
                          f"p=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                          f"Path({str(pid_file)!r}).write_text(str(p.pid)); time.sleep(30)")
                code = run([sys.executable, '-u', '-c', source], root/'log', root/'report', .5, poll=.02)
                self.assertEqual(code, 124)
                self.assertIsNone(unrelated.poll())
                child_pid = int(pid_file.read_text())
                # A killed orphan may briefly remain a zombie until reaped;
                # neither a live sleeper nor another lane may be left running.
                state = subprocess.run(['ps', '-o', 'stat=', '-p', str(child_pid)], text=True, capture_output=True).stdout.strip()
                self.assertTrue(not state or state.startswith('Z'), state)
        finally:
            unrelated.terminate(); unrelated.wait(timeout=5)

    def test_invalid_timeout_fails_before_starting_child(self):
        for timeout in ("0", "-1", "nan", "inf"):
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("xcode_progress_watchdog.py")),
                                     "--log", "/dev/null", "--report", "/dev/null", "--timeout", timeout,
                                     "--", sys.executable, "-c", "raise SystemExit(99)"], capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
