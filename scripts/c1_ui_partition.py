#!/usr/bin/env python3
"""Partition all requested UI suites deterministically, without dropping any.

Use the canonical historical runtime weights, not test-method counts.
Historical weights guide partitioning; they do not predict completion times.
Each suite remains isolated and each selected suite belongs to exactly one job.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


def partition(classes: list[str], weights: dict[str, int], shards: int) -> list[list[str]]:
    if shards < 1 or len(classes) != len(set(classes)):
        raise ValueError("positive shard count and unique suite names are required")
    buckets: list[list[str]] = [[] for _ in range(shards)]
    loads = [0] * shards
    positions = {name: index for index, name in enumerate(classes)}
    for name in sorted(classes, key=lambda item: (-weights.get(item, 1), positions[item])):
        target = min(range(shards), key=lambda index: (loads[index], index))
        buckets[target].append(name)
        loads[target] += max(1, weights.get(name, 1))
    for bucket in buckets:
        bucket.sort(key=positions.__getitem__)
    flattened = [name for bucket in buckets for name in bucket]
    if len(flattened) != len(classes) or set(flattened) != set(classes):
        raise ValueError("partition coverage mismatch")
    return buckets


def runtime_weights(path: Path) -> dict[str, int]:
    """Read the two literal canonical arrays as data, without executing shell.

    Missing, duplicate, nonpositive, or incomplete weights fail closed. New
    suites must register a weight rather than silently receiving a cheap one.
    Returned units are seconds; canonical weights use tenths of a minute.
    """
    text = path.read_text()
    def tokens(name: str) -> list[str]:
        matches = re.findall(r"^" + re.escape(name) + r"=\((.*?)^\)", text, re.M | re.S)
        if len(matches) != 1:
            raise ValueError(f"expected exactly one literal {name} array")
        return " ".join(line.split("#", 1)[0] for line in matches[0].splitlines()).split()
    names = tokens("UI_CLASSES")
    values = tokens("UI_WEIGHT_TENTHS_OF_MINUTE")
    if not names or len(names) != len(set(names)) or len(names) != len(values):
        raise ValueError("runtime weights must cover every unique canonical suite")
    if any(not re.fullmatch(r"[A-Za-z0-9_]+", name) for name in names):
        raise ValueError("invalid canonical suite name")
    if any(not value.isdigit() or int(value) <= 0 for value in values):
        raise ValueError("runtime weights must be positive integers")
    return {name: int(value) * 6 for name, value in zip(names, values)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--classes", required=True)
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--shards", type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.shard <= args.shards <= 64:
        parser.error("require 1 <= shard <= shards <= 64")
    classes = args.classes.split()
    source = Path(__file__).resolve().parent.parent / "HermesFleetAppUITests"
    weights: dict[str, int] = {}
    try:
        for name in classes:
            if not re.fullmatch(r"[A-Za-z0-9_]+", name):
                raise ValueError(f"invalid suite name: {name!r}")
            if not (source / f"{name}UITests.swift").is_file():
                raise ValueError(f"missing suite source: {name}")
        canonical = runtime_weights(source.parent / "scripts/c1_ui_matrix.sh")
        for name in classes:
            if name not in canonical:
                raise ValueError(f"suite has no historical runtime weight: {name}")
            weights[name] = canonical[name]
        print(" ".join(partition(classes, weights, args.shards)[args.shard - 1]))
    except (OSError, ValueError) as error:
        print(f"UI partition failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
