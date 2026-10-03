#!/usr/bin/env python3
"""Verify concurrency with barriers and preserve failures/diagnostic output."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

from dev_check_parallel import run_phases


class ParallelPhaseTests(unittest.TestCase):
    def test_both_phases_start_before_either_can_finish(self):
        with tempfile.TemporaryDirectory() as directory:
            results=Path(directory)
            def phase(name,other):
                source=(f"from pathlib import Path; import time; r=Path({directory!r}); "
                        f"(r/{name!r}).touch(); deadline=time.monotonic()+4\n"
                        f"while not (r/{other!r}).exists():\n"
                        " if time.monotonic()>deadline: raise SystemExit(9)\n"
                        " time.sleep(.02)\nprint('phase passed')")
                return [sys.executable,'-u','-c',source]
            statuses=run_phases({'build':phase('build.started','packages.started'),
                                 'packages':phase('packages.started','build.started')},results)
            self.assertEqual(statuses,{'build':0,'packages':0})
            for name in statuses: self.assertIn('phase passed',(results/f'{name}.log').read_text())

    def test_failed_build_does_not_hide_successful_package_results(self):
        with tempfile.TemporaryDirectory() as directory:
            results=Path(directory)
            statuses=run_phases({'build':[sys.executable,'-c',"print('build failure'); raise SystemExit(14)"],
                                 'packages':[sys.executable,'-c',"import time; time.sleep(.1); print('packages finished')"]},results)
            self.assertEqual(statuses,{'build':14,'packages':0})
            self.assertIn('packages finished',(results/'packages.log').read_text())
            self.assertEqual(json.loads((results/'phases.json').read_text())['exit_codes'],statuses)


if __name__=='__main__': unittest.main(verbosity=2)
