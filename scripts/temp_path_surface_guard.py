#!/usr/bin/env python3
"""Fail if a script reachable from a supported workflow uses a fixed temp path.

Supported entry points are the Makefile, the CI workflows and the scripts a
current document tells people to run. From those roots the guard follows every
script that one script mentions by file name, then flags any reachable script
that writes to a predictable shared location (`/tmp/<name>` or
`${TMPDIR:-/tmp}/<name>` not created by mktemp or scripts/private_dir_lib.sh).
Historical milestone scripts that nothing reachable mentions are out of scope
on purpose; they are listed by `--report`.

Roots: the Makefile, CI workflows, the current docs, project.yml / xcconfig /
Package.swift (build phases), and any Swift file that spawns processes.
Dynamic invocations (`scripts/*`, `$SCRIPT_DIR/${name}_test.sh`) are expanded
conservatively: a computed script name reaches every script it could match.

Remaining limits (also in docs/dev-loop.md): invocation through names built
from several string pieces at run time, scripts reached only by hand, and
patterns that do not literally contain `/tmp/<name>` or `$TMPDIR/<name>`.

Usage: temp_path_surface_guard.py [--root DIR] [--report]
"""
import fnmatch
import glob
import os
import re
import sys

DOC_ROOTS = [
    "README.md", "AGENTS.md", "docs/README.md", "docs/DEVELOPMENT.md", "docs/dev-loop.md",
    "docs/release-preflight.md", "docs/release/REVIEWER-ENVIRONMENT.md", "docs/fleet-dev.md",
    "docs/tls-first-use-review.md",
]

# Dynamic invocations the guard cannot resolve to specific scripts. Each entry
# was reviewed: (file, token) -> why it is not a way to reach unreviewed scripts.
UNRESOLVED_ALLOWED = [
    ("private_dir_lib_test.sh", "scripts/$s.sh"),   # loops over six l1_* names written out in that file
    ("c1_ui_preflight.sh", "scripts/*"),            # changed-file path classification, not an invocation
]

# Reachable scripts whose matching line was reviewed and is NOT a host path.
# (script, substring of the line)
ALLOWED = [
    ("private_dir_lib.sh", "hermes-fleet"),          # unused example text
    ("private_dir_lib.sh", '"${TMPDIR:-/tmp}" "$1"'),  # the per-uid name builder itself
    ("public_safety_guard.sh", "DESTRUCTIVE_FIXTURE"),  # destructive-command fixture string
    ("reviewer_containment_test.sh", "udp53probe"),     # path INSIDE the container's tmpfs
    ("reviewer_provider_env_test.sh", "HOME=/tmp/evil"),  # hostile-environment fixture value
]


BUILD_ROOT_GLOBS = ["project.yml", "Config/*", "Package.swift", "Packages/*/Package.swift", "*.xcconfig"]
SPAWN_API = re.compile(r"\bProcess\(\)|\bNSTask\b|\bposix_spawn\b|\.executableURL\b")
DYNAMIC_TOKEN = re.compile(r"[A-Za-z0-9_./${}*?-]*[$*][A-Za-z0-9_./${}*?-]*\.(?:sh|py)\b")
GLOB_ALL = re.compile(r"scripts/\*(?![\w.])")


def build(root):
    scripts = {os.path.basename(p): p for p in glob.glob(os.path.join(root, "scripts", "*")) if os.path.isfile(p)}

    unresolved = []

    def refs(text, origin=None):
        found = {n for n in scripts if re.search(r"(?<![\w.-])" + re.escape(n) + r"(?![\w.-])", text)}
        if GLOB_ALL.search(text) and origin is not None:
            unresolved.append((origin, "scripts/*"))
        for token in DYNAMIC_TOKEN.findall(text):
            pattern = re.sub(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*", "*", os.path.basename(token))
            if len(pattern.replace("*", "")) < 4:
                # Too unspecific to expand (would reach everything): report it.
                if origin is not None:
                    unresolved.append((origin, token))
                continue
            found |= {n for n in scripts if fnmatch.fnmatch(n, pattern)}
        return found

    roots = set()
    files = [os.path.join(root, "Makefile")] + glob.glob(os.path.join(root, ".github", "**", "*"), recursive=True)
    files += [os.path.join(root, d) for d in DOC_ROOTS]
    for pattern in BUILD_ROOT_GLOBS:
        files += glob.glob(os.path.join(root, pattern))
    for f in files:
        if os.path.isfile(f):
            roots |= refs(open(f, errors="ignore").read(), os.path.basename(f))
    # Swift sources that spawn processes can invoke scripts.
    for f in glob.glob(os.path.join(root, "**", "*.swift"), recursive=True):
        if "/.build/" in f or "/build/" in f or "DerivedData" in f:
            continue
        text = open(f, errors="ignore").read()
        if SPAWN_API.search(text):
            roots |= refs(text, os.path.basename(f))
    seen, stack = set(), list(roots)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        if n.startswith("temp_path_surface_guard"):
            continue  # its docstring/fixtures mention patterns by example
        for m in refs(open(scripts[n], errors="ignore").read(), n):
            if m != n:
                stack.append(m)
    return scripts, seen, unresolved


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
    scripts, reachable, unresolved = build(root)
    failures = []
    for origin, token in sorted(set(unresolved)):
        if origin.startswith("temp_path_surface_guard") or (origin, token) in UNRESOLVED_ALLOWED:
            continue
        failures.append(f"{origin}: unresolved dynamic script invocation '{token}' (review it, then add it to UNRESOLVED_ALLOWED)")
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
