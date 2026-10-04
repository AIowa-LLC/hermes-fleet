#!/usr/bin/env python3
"""Fail if a script reachable from a supported workflow uses a fixed temp path.

Supported entry points are the Makefile, the CI workflows and the scripts a
current document tells people to run. From those roots the guard follows every
script that one script mentions by file name, then flags any reachable script
that writes to a predictable shared location (`/tmp/<name>` or
`${TMPDIR:-/tmp}/<name>` not created by mktemp or scripts/private_dir_lib.sh).
Historical milestone scripts that nothing reachable mentions are out of scope
on purpose; they are listed by `--report`.

Usage: temp_path_surface_guard.py [--root DIR] [--report]
"""
import glob
import os
import re
import sys

DOC_ROOTS = [
    "README.md", "AGENTS.md", "docs/README.md", "docs/DEVELOPMENT.md", "docs/dev-loop.md",
    "docs/release-preflight.md", "docs/release/REVIEWER-ENVIRONMENT.md", "docs/fleet-dev.md",
    "docs/tls-first-use-review.md",
]

# Reachable scripts whose matching line was reviewed and is NOT a host path.
# (script, substring of the line)
ALLOWED = [
    ("private_dir_lib.sh", "hermes-fleet"),          # unused example text
    ("private_dir_lib.sh", '"${TMPDIR:-/tmp}" "$1"'),  # the per-uid name builder itself
    ("public_safety_guard.sh", "rm -rf /tmp/scratch"),  # destructive-command fixture string
    ("reviewer_containment_test.sh", "udp53probe"),     # path INSIDE the container's tmpfs
    ("reviewer_provider_env_test.sh", "HOME=/tmp/evil"),  # hostile-environment fixture value
]


def build(root):
    scripts = {os.path.basename(p): p for p in glob.glob(os.path.join(root, "scripts", "*")) if os.path.isfile(p)}

    def refs(text):
        return {n for n in scripts if re.search(r"(?<![\w.-])" + re.escape(n) + r"(?![\w.-])", text)}

    roots = set()
    files = [os.path.join(root, "Makefile")] + glob.glob(os.path.join(root, ".github", "**", "*"), recursive=True)
    files += [os.path.join(root, d) for d in DOC_ROOTS]
    for f in files:
        if os.path.isfile(f):
            roots |= refs(open(f, errors="ignore").read())
    seen, stack = set(), list(roots)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        for m in refs(open(scripts[n], errors="ignore").read()):
            if m != n:
                stack.append(m)
    return scripts, seen


def fixed_temp_lines(path):
    hits = []
    for i, line in enumerate(open(path, errors="ignore").read().splitlines(), 1):
        if line.strip().startswith("#"):
            continue
        fixed = re.search(r"/tmp/[A-Za-z0-9_.-]", line) or re.search(r"\$\{?TMPDIR[^}]*\}?/[A-Za-z]", line)
        if fixed and "mktemp" not in line and "hf_private" not in line and "RESULT_ROOT" not in line:
            hits.append((i, line.strip()))
    return hits


def main(argv):
    root = "."
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    scripts, reachable = build(root)
    failures = []
    for name in sorted(reachable):
        if name.startswith("temp_path_surface_guard"):
            continue  # the guard's own patterns
        for lineno, text in fixed_temp_lines(scripts[name]):
            if any(name == s and frag in text for s, frag in ALLOWED):
                continue
            failures.append(f"{name}:{lineno}: {text[:100]}")
    if "--report" in argv:
        excluded = sorted(n for n in scripts if n not in reachable and fixed_temp_lines(scripts[n]))
        print(f"{len(reachable)} reachable scripts; {len(excluded)} unreachable scripts use fixed temp paths (historical):")
        print("  " + ", ".join(excluded))
    if failures:
        print("FAIL: reachable scripts use a predictable shared temp path:")
        for f in failures:
            print("  " + f)
        return 1
    print(f"PASS: {len(reachable)} reachable scripts use no predictable shared temp path")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
