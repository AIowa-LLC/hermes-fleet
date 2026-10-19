#!/usr/bin/env python3
"""Fixture tests for temp_path_surface_guard.py (reachability + fixed-path rules)."""
import os
import subprocess
import sys
import tempfile

GUARD = os.path.join(os.path.dirname(__file__), "temp_path_surface_guard.py")


def run(files):
    with tempfile.TemporaryDirectory(prefix="hf_tmp_guard_test.") as root:
        for rel, text in files.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as fh:
                fh.write(text)
        r = subprocess.run([sys.executable, GUARD, "--root", root], capture_output=True, text=True)
        return r.returncode, r.stdout


FIXED = "#!/bin/bash\necho x > /tmp/fixed-name.log\n"
cases = []


def case(name, files, expect):
    rc, out = run(files)
    ok = rc == expect
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f" (rc={rc})\n{out}"))
    cases.append(ok)


case("fixed /tmp in a Makefile-reachable script fails",
     {"Makefile": "t:\n\tbash scripts/a.sh\n", "scripts/a.sh": FIXED}, 1)
case("fixed /tmp two hops from CI fails",
     {".github/workflows/ci.yml": "run: bash scripts/a.sh\n", "scripts/a.sh": "bash scripts/b.sh\n", "scripts/b.sh": FIXED}, 1)
case("fixed ${TMPDIR:-/tmp}/name in a documented script fails",
     {"README.md": "run `bash scripts/a.sh`\n", "scripts/a.sh": 'LOG="${TMPDIR:-/tmp}/name.log"\n'}, 1)
case("mktemp-created paths pass",
     {"Makefile": "t:\n\tbash scripts/a.sh\n", "scripts/a.sh": 'D=$(mktemp -d "${TMPDIR:-/tmp}/hf.XXXXXX")\n'}, 0)
case("private_dir_lib users pass",
     {"Makefile": "t:\n\tbash scripts/a.sh\n", "scripts/a.sh": 'W=$(hf_private_dir "${TMPDIR:-/tmp}/x-$(id -u)")\n'}, 0)
case("an unreachable historical script is out of scope",
     {"Makefile": "t:\n\tbash scripts/a.sh\n", "scripts/a.sh": "echo ok\n", "scripts/old.sh": FIXED}, 0)
case("comments are ignored",
     {"Makefile": "t:\n\tbash scripts/a.sh\n", "scripts/a.sh": "# logs used to go to /tmp/a.log\n"}, 0)
case("computed script names expand to every script they could match",
     {"Makefile": "t:\n\tbash scripts/runner.sh\n",
      "scripts/runner.sh": 'bash "scripts/${name}_check.sh"\n',
      "scripts/a_check.sh": FIXED, "scripts/old.sh": FIXED}, 1)
case("an unspecific computed name is reported, not silently ignored",
     {"Makefile": "t:\n\tbash scripts/runner.sh\n", "scripts/runner.sh": 'bash "scripts/$x.sh"\n', "scripts/old.sh": FIXED}, 1)
case("a scripts/* glob in a reachable script is reported",
     {"Makefile": "t:\n\tbash scripts/runner.sh\n", "scripts/runner.sh": "for f in scripts/*; do echo $f; done\n"}, 1)
case("project.yml build phases are roots",
     {"project.yml": "targets:\n  A:\n    postBuildScripts:\n      - script: bash scripts/a.sh\n", "scripts/a.sh": FIXED}, 1)
case("a Swift file that spawns a process makes its scripts roots",
     {"Sources/T.swift": 'let p = Process()\np.executableURL = URL(fileURLWithPath: "scripts/a.sh")\n', "scripts/a.sh": FIXED}, 1)
case("a Swift file that merely mentions a script is not a root",
     {"Sources/T.swift": "// started by scripts/a.sh\n", "scripts/a.sh": FIXED}, 0)
print(f"temp-path guard fixtures: {cases.count(False)} failure(s)")
sys.exit(0 if all(cases) else 1)
