#!/usr/bin/env python3
"""Source guard for launch-environment overrides and OSLog privacy (P0.3d).

Checks production Swift sources (Packages/*/Sources and HermesFleetApp; test
targets are excluded) for two regressions:

1. Lock override reads. `HERMES_FLEET_APP_LOCK` and any `HERMES_FLEET_LOCK_*`
   launch-environment variable, along with security-relevant migration, purge
   and input fixtures, must only appear inside an active `#if DEBUG`
   region, so a Release build cannot be told to disable App Lock. Comment
   lines are ignored.

2. OSLog privacy. An interpolation marked `privacy: .public` must not carry a
   URL, host, endpoint, gateway address, session id, title, or path. Those
   values reach sysdiagnose and device logs; use `.private` (the default for
   strings) or a stable, non-identifying label instead.

Usage:
  security_hygiene_guard.py [ROOT]            run both checks (default ROOT=repo)
  security_hygiene_guard.py --audit [ROOT]    list every non-DEBUG read of any
                                              HERMES_FLEET_* variable (audit aid)

Exit status is 1 when any violation is found.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

LOCK_VAR = re.compile(r"HERMES_FLEET_(APP_LOCK|LOCK_[A-Z_]+|SKIP_KEYCHAIN_PURGE|LEGACY_MIGRATION|DEFAULT_ENDPOINT|ATTACHMENT_PICK|PAIRING_SIMULATED_SCAN|PAIRING_CAMERA_DENIED|UI_TEST_PASTE_FIXTURES)")
ANY_VAR = re.compile(r"HERMES_FLEET_[A-Z_]+")
SENSITIVE_EXPR = re.compile(
    r"(url|host|endpoint|address|origin|gateway|session|title|path|domain)",
    re.IGNORECASE,
)
IF_LINE = re.compile(r"^\s*#if\b(.*)$")
ELIF_LINE = re.compile(r"^\s*#elseif\b")
ELSE_LINE = re.compile(r"^\s*#else\b")
ENDIF_LINE = re.compile(r"^\s*#endif\b")


def production_sources(root: Path) -> list[Path]:
    files: list[Path] = []
    for base in [root / "HermesFleetApp", *sorted((root / "Packages").glob("*/Sources"))]:
        if base.is_dir():
            files.extend(sorted(base.rglob("*.swift")))
    return files


def debug_only_flags(lines: list[str]) -> list[bool]:
    """Per line: True when the line is inside an active `#if DEBUG` branch.

    Only a condition that starts with `DEBUG` (optionally `&& ...`) counts as
    debug-only. Conditions containing OR are conservatively rejected because
    a later operand can allow Release execution. `#else` / `#elseif` branches
    of such a block are not.
    """
    flags: list[bool] = []
    stack: list[bool] = []  # per open #if: is the current branch debug-only
    for line in lines:
        m = IF_LINE.match(line)
        if m:
            cond = m.group(1).strip()
            stack.append(bool(re.match(r"^DEBUG\b", cond)) and "||" not in cond)
            flags.append(any(stack))
            continue
        if ELIF_LINE.match(line) or ELSE_LINE.match(line):
            if stack:
                stack[-1] = False
            flags.append(any(stack))
            continue
        if ENDIF_LINE.match(line):
            flags.append(any(stack))
            if stack:
                stack.pop()
            continue
        flags.append(any(stack))
    return flags


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("//")


def unguarded_reads(path: Path, pattern: re.Pattern[str]) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    flags = debug_only_flags(lines)
    hits = []
    for idx, line in enumerate(lines):
        if is_comment(line) or not pattern.search(line):
            continue
        if not flags[idx]:
            hits.append((idx + 1, line.strip()))
    return hits


def public_interpolations(line: str) -> list[str]:
    """Return the expression text of each `\\(expr, privacy: .public)`."""
    found = []
    for m in re.finditer(r"privacy:\s*\.public\s*\)", line):
        end = m.start()
        depth = 1
        i = end - 1
        while i >= 0 and depth > 0:
            ch = line[i]
            if ch == ")":
                depth += 1
            elif ch == "(":
                depth -= 1
            i -= 1
        # i+1 is the "(" of the interpolation; the expression follows it.
        expr = line[i + 2 : end]
        found.append(expr.rstrip().rstrip(","))
    return found


def check(root: Path) -> list[str]:
    problems: list[str] = []
    for path in production_sources(root):
        rel = path.relative_to(root)
        for lineno, text in unguarded_reads(path, LOCK_VAR):
            problems.append(
                f"{rel}:{lineno}: lock override read outside #if DEBUG: {text}"
            )
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if is_comment(line):
                continue
            for expr in public_interpolations(line):
                if SENSITIVE_EXPR.search(expr):
                    problems.append(
                        f"{rel}:{lineno}: 'privacy: .public' on sensitive-looking "
                        f"interpolation '{expr}' (use .private)"
                    )
    return problems


def audit(root: Path) -> None:
    for path in production_sources(root):
        for lineno, text in unguarded_reads(path, ANY_VAR):
            print(f"{path.relative_to(root)}:{lineno}: {text}")


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if a != "--audit"]
    root = Path(args[0]) if args else Path(__file__).resolve().parent.parent
    if "--audit" in argv[1:]:
        audit(root)
        return 0
    problems = check(root)
    for p in problems:
        print(f"FAIL  {p}")
    if problems:
        print(f"\nsecurity hygiene guard: {len(problems)} violation(s)")
        return 1
    print("security hygiene guard: lock override is DEBUG-only; no sensitive .public log interpolations")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
