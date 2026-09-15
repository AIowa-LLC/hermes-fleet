#!/usr/bin/env python3
"""Parse one class-selected xcresult test report.

The C1 runner allows Xcode to retry a failed test once.  xcresulttool keeps
the attempts in the report, so this parser evaluates the final attempt for
each test case while retaining enough information to report a recovered
flake.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict
from typing import Any


PASS_RESULTS = {"Passed", "Expected Failure"}
SKIP_RESULTS = {"Skipped", "Skip"}
ATTEMPT_KEYS = (
    "attempt",
    "attemptIndex",
    "iteration",
    "iterationIndex",
    "repetition",
    "repetitionIndex",
    "testIteration",
    "testIterationIndex",
)


def load_json(path: str) -> Any:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def walk(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def matches_requested(node: dict[str, Any], requested: str) -> bool:
    identifier = str(node.get("nodeIdentifier", ""))
    if identifier.startswith(f"{requested}/"):
        return True

    identifier_url = str(node.get("nodeIdentifierURL", ""))
    parts = [part for part in identifier_url.split("/") if part]
    return requested in parts[:-1]


def case_key(node: dict[str, Any], requested: str) -> str:
    # Test method names are stable across retry attempts and are preferable to
    # node identifiers, which Xcode may decorate with repetition metadata.
    name = node.get("name")
    if isinstance(name, str) and name:
        return f"{requested}/{name}"

    identifier = str(node.get("nodeIdentifier", ""))
    identifier = re.sub(
        r"(?:[/#:_-](?:attempt|iteration|repetition))[-_:#]?\d+$",
        "",
        identifier,
        flags=re.IGNORECASE,
    )
    return identifier or f"{requested}/<unnamed-{id(node)}>"


def attempt_rank(node: dict[str, Any]) -> int | None:
    for key in ATTEMPT_KEYS:
        value = node.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def parse(
    summary: Any,
    tests: Any,
    requested: str,
    allowed_skips: set[str] | None = None,
) -> tuple[int, int, int, int, int]:
    allowed_skips = allowed_skips or set()
    cases: OrderedDict[str, list[tuple[int, int | None, str]]] = OrderedDict()
    order = 0
    for node in walk(tests):
        if not isinstance(node, dict) or node.get("nodeType") != "Test Case":
            continue
        if not matches_requested(node, requested):
            continue
        result = str(node.get("result", ""))
        key = case_key(node, requested)
        cases.setdefault(key, []).append((order, attempt_rank(node), result))
        order += 1

    failures = 0
    executed = 0
    recovered = 0
    for key, attempts in cases.items():
        # Prefer Xcode's explicit attempt index.  When the report omits it,
        # traversal order is the only stable signal available in the JSON.
        if all(item[1] is not None for item in attempts):
            ordered = sorted(attempts, key=lambda item: (item[1], item[0]))
        else:
            ordered = sorted(attempts, key=lambda item: item[0])
        final_result = ordered[-1][2]
        case_name = case_key_from_result_key(key)
        if final_result in SKIP_RESULTS:
            if case_name not in allowed_skips or any(
                result not in PASS_RESULTS | SKIP_RESULTS
                for _, _, result in ordered
            ):
                failures += 1
            continue
        executed += 1
        if final_result not in PASS_RESULTS:
            failures += 1
        elif any(result not in PASS_RESULTS for _, _, result in ordered[:-1]):
            recovered += 1

    summary_result = summary.get("result") if isinstance(summary, dict) else None
    total = 0
    if isinstance(summary, dict):
        for key in ("totalTestCount", "testCount"):
            value = summary.get(key)
            if isinstance(value, int):
                total = max(total, value)
    complete = int(summary_result == "Passed" and total > 0)
    present = int(bool(cases))
    return executed, failures, complete, present, recovered


def case_key_from_result_key(key: str) -> str:
    """Return the stable test-case name from a requested/name key."""

    return key.split("/", 1)[-1] if "/" in key else key


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", required=True)
    parser.add_argument("--tests", required=True)
    parser.add_argument("--requested", required=True)
    parser.add_argument(
        "--allow-skipped",
        action="append",
        default=[],
        help="stable test-case name that may be skipped on this destination",
    )
    args = parser.parse_args()

    try:
        summary = load_json(args.summary)
        tests = load_json(args.tests)
        values = parse(summary, tests, args.requested, set(args.allow_skipped))
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"xcresult parse failure: {error}", file=sys.stderr)
        print("0 0 0 0 0")
        return 0

    print(" ".join(str(value) for value in values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
