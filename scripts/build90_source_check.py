#!/usr/bin/env python3
"""Compare recorded release source with an integration commit or Git tree.

Only infrastructure/documentation paths may differ. This is a source-preservation
check, not proof of archive provenance, physical-device acceptance, or test health.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys


def infrastructure(path: str) -> bool:
    return path in {'AGENTS.md', 'RELEASES.md'} or path.startswith(('.github/', 'docs/', 'scripts/'))


def source_tree(repo: Path, ref: str) -> dict[str, tuple[str, str, str]]:
    # Resolve before using a value in a Git command, rejecting revision options.
    resolved = subprocess.check_output(
        ['git', 'rev-parse', '--verify', '--end-of-options', f'{ref}^{{tree}}'],
        cwd=repo, text=True, stderr=subprocess.PIPE,
    ).strip()
    raw = subprocess.check_output(['git', 'ls-tree', '-r', '-z', resolved], cwd=repo)
    entries: dict[str, tuple[str, str, str]] = {}
    for entry in raw.split(b'\0'):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b'\t', 1)
        path = path_bytes.decode('utf-8', errors='surrogateescape')
        if infrastructure(path):
            continue
        mode, kind, sha = metadata.decode('ascii').split()
        entries[path] = (mode, kind, sha)
    return entries


def differences(source: dict, target: dict) -> list[str]:
    return [path for path in sorted(source.keys() | target.keys()) if source.get(path) != target.get(path)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='recorded release commit')
    parser.add_argument('--target', default='HEAD', help='integration commit or resolved Git tree')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    try:
        source = source_tree(repo, args.source)
        target = source_tree(repo, args.target)
        if not source or not target:
            raise ValueError('source and target must have non-infrastructure tracked entries')
        changed = differences(source, target)
        if changed:
            print('FAIL: non-infrastructure source differs:', file=sys.stderr)
            print('\n'.join(changed), file=sys.stderr)
            return 1
        print(f'PASS: {len(source)} non-infrastructure entries match exactly (Git object, mode, and type).')
        print('Includes app source, resources, dependencies, generated project, build configuration, and product tests.')
        print('Archive provenance and behavioral acceptance remain separate checks.')
        return 0
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f'Source comparison incomplete: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
