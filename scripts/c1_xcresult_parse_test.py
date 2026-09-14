#!/usr/bin/env python3
"""Contract tests for c1_xcresult_parse.py."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PARSER = ROOT / "scripts" / "c1_xcresult_parse.py"
REQUESTED = "ExampleUITests"


def run(summary: dict, tests: dict) -> tuple[int, int, int, int, int]:
    with tempfile.TemporaryDirectory(prefix="c1-xcresult-parse-") as directory:
        root = Path(directory)
        summary_path = root / "summary.json"
        tests_path = root / "tests.json"
        summary_path.write_text(json.dumps(summary), encoding="utf-8")
        tests_path.write_text(json.dumps(tests), encoding="utf-8")
        output = subprocess.check_output(
            [
                sys.executable,
                str(PARSER),
                "--summary",
                str(summary_path),
                "--tests",
                str(tests_path),
                "--requested",
                REQUESTED,
            ],
            text=True,
        )
        return tuple(int(value) for value in output.split())  # type: ignore[return-value]


def summary(result: str = "Passed", total: int = 1) -> dict:
    return {"result": result, "totalTestCount": total}


def case(name: str, result: str, **extra: object) -> dict:
    return {
        "name": name,
        "nodeIdentifier": f"{REQUESTED}/{name}",
        "nodeType": "Test Case",
        "result": result,
        **extra,
    }


def tests(*cases: dict) -> dict:
    return {"testNodes": [{"children": list(cases)}]}


def check(label: str, actual: tuple[int, int, int, int, int], expected: tuple[int, int, int, int, int]) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected}, got {actual}")
    print(f"PASS  {label}")


check(
    "ordinary pass",
    run(summary(), tests(case("testPass()", "Passed"))),
    (1, 0, 1, 1, 0),
)
check(
    "failed first attempt recovered by retry",
    run(
        summary(),
        tests(
            case("testFlake()", "Failed", iteration=1),
            case("testFlake()", "Passed", iteration=2),
        ),
    ),
    (1, 0, 1, 1, 1),
)
check(
    "final retry failure remains a failure",
    run(
        summary("Failed"),
        tests(
            case("testStillFails()", "Passed", iteration=1),
            case("testStillFails()", "Failed", iteration=2),
        ),
    ),
    (1, 1, 0, 1, 0),
)
check(
    "selector mismatch is absent",
    run(
        summary(),
        tests(
            {
                "name": "testOther()",
                "nodeIdentifier": "OtherUITests/testOther()",
                "nodeType": "Test Case",
                "result": "Passed",
            }
        ),
    ),
    (0, 0, 1, 0, 0),
)
check(
    "incomplete result is not a pass",
    run(summary("Passed", total=0), tests(case("testIncomplete()", "Passed"))),
    (1, 0, 0, 1, 0),
)

print("PASS: xcresult retry parser contract tests")
