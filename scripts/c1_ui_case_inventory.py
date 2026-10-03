#!/usr/bin/env python3
"""Exact XCTest method inventory for one deterministic source class."""
import argparse
from pathlib import Path
import re


def cases(root: Path, name: str) -> list[str]:
    if not re.fullmatch(r"[A-Za-z0-9_]+", name):
        raise ValueError("invalid suite name")
    text = (root / "HermesFleetAppUITests" / f"{name}UITests.swift").read_text()
    methods = re.findall(r"^[ \t]*func[ \t]+(test[A-Za-z0-9_]+)[ \t]*\(", text, re.M)
    if not methods or len(methods) != len(set(methods)):
        raise ValueError("expected unique XCTest methods in the requested class")
    return [method + "()" for method in methods]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--class", dest="name", required=True)
    args = parser.parse_args()
    try:
        print("\n".join(cases(Path(__file__).resolve().parent.parent, args.name)))
    except (OSError, ValueError) as error:
        parser.exit(1, f"UI inventory failed: {error}\n")
