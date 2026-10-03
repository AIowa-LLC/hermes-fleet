#!/usr/bin/env python3
"""Serialize this repository's short simulator-management operations."""
import fcntl
import os
import subprocess
import sys

if len(sys.argv) < 4:
    raise SystemExit("expected lock file, repository identity, script and arguments")
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    result = subprocess.run(["bash", *sys.argv[3:]],
                            env=dict(os.environ, HF_SIM_LOCK_HELD=sys.argv[2]))
raise SystemExit(result.returncode)
