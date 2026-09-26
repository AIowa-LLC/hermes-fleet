#!/usr/bin/env python3
"""Partition all requested UI suites deterministically, without dropping any.

Test-method counts are a balancing heuristic, not measured runtime estimates.
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
            text = (source / f"{name}UITests.swift").read_text()
            weights[name] = max(1, len(re.findall(r"^\s*func\s+test\w*\s*\(", text, re.M)))
        print(" ".join(partition(classes, weights, args.shards)[args.shard - 1]))
    except (OSError, ValueError) as error:
        print(f"UI partition failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
