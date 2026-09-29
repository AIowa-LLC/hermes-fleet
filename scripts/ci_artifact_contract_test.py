#!/usr/bin/env python3
"""Check diagnostic artifact identity across attempts and matrix producers.

Artifacts are immutable within a workflow run. A failed-job rerun must retain
its previous evidence and upload under a new attempt identity. These contracts
read the actual CI/deep workflow templates; they do not invoke GitHub or Xcode.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Upload:
    workflow: str
    job: str
    template: str
    shards: tuple[int | None, ...] = (None,)


def read_uploads(path: Path) -> list[Upload]:
    text = path.read_text()
    jobs = text.split("\njobs:\n", 1)[1]
    headers = list(re.finditer(r"^  ([a-z][a-z0-9_-]*):\n", jobs, re.M))
    uploads = []
    for index, header in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(jobs)
        body = jobs[header.end():end]
        shard = re.search(r"^\s+shard: \[([0-9, ]+)\]", body, re.M)
        shards = tuple(int(value.strip()) for value in shard[1].split(",")) if shard else (None,)
        blocks = re.split(r"^\s+- (?:name:|uses:)", body, flags=re.M)
        for block in blocks:
            if "actions/upload-artifact@" not in block:
                continue
            name = re.search(r"^\s+name: (.+)$", block, re.M)
            if name is None:
                raise ValueError(f"{path.name}/{header[1]} upload has no explicit name")
            if re.search(r"^\s+overwrite: true\s*$", block, re.M):
                raise ValueError("diagnostic evidence must not overwrite a previous attempt")
            uploads.append(Upload(path.name, header[1], name[1].strip(), shards))
    return uploads


def validate(uploads: list[Upload]) -> None:
    identities = set()
    for upload in uploads:
        if "${{ github.run_attempt }}" not in upload.template:
            raise ValueError(f"{upload.workflow}/{upload.job} lacks attempt identity")
        for attempt in (1, 2, 3):
            for shard in upload.shards:
                name = upload.template.replace("${{ github.run_attempt }}", str(attempt))
                if shard is not None:
                    name = name.replace("${{ matrix.shard }}", str(shard))
                if "${{" in name:
                    raise ValueError("unsupported or unresolved artifact-name expression")
                identity = (upload.workflow, name)
                if identity in identities:
                    raise ValueError(f"artifact identity collision: {identity}")
                identities.add(identity)


class ArtifactContracts(unittest.TestCase):
    def test_actual_workflows_preserve_every_producer_and_attempt(self):
        ci = read_uploads(ROOT / ".github/workflows/ci.yml")
        deep = read_uploads(ROOT / ".github/workflows/ui-regression.yml")
        self.assertEqual({upload.job for upload in ci}, {"packages", "units", "critical-smoke", "ui-preflight"})
        self.assertEqual({upload.job for upload in deep}, {"ui-shard"})
        self.assertEqual(next(upload.shards for upload in ci if upload.job == "ui-preflight"), tuple(range(1, 13)))
        self.assertEqual(deep[0].shards, tuple(range(1, 6)))
        validate(ci + deep)

    def test_prior_evidence_cannot_be_overwritten(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        source = source.replace("retention-days: 14", "overwrite: true\n          retention-days: 14", 1)
        with tempfile.TemporaryDirectory(prefix="fleet-artifact-contract-") as directory:
            path = Path(directory) / "ci.yml"
            path.write_text(source)
            with self.assertRaises(ValueError):
                read_uploads(path)

    def test_rerun_without_attempt_identity_is_rejected(self):
        with self.assertRaises(ValueError):
            validate([Upload("ci", "packages", "package-diagnostics")])

    def test_matrix_without_shard_identity_is_rejected(self):
        with self.assertRaises(ValueError):
            validate([Upload("ci", "ui", "ui-attempt-${{ github.run_attempt }}", (1, 2))])

    def test_two_jobs_cannot_claim_same_identity(self):
        upload = Upload("ci", "packages", "diagnostics-attempt-${{ github.run_attempt }}")
        with self.assertRaises(ValueError):
            validate([upload, replace(upload, job="units")])

    def test_unknown_expression_cannot_hide_a_collision(self):
        with self.assertRaises(ValueError):
            validate([Upload("ci", "units", "${{ unknown }}-${{ github.run_attempt }}")])

    def test_workflows_have_independent_run_namespaces(self):
        upload = Upload("ci", "units", "units-attempt-${{ github.run_attempt }}")
        validate([upload, replace(upload, workflow="deep")])


if __name__ == "__main__":
    unittest.main(verbosity=2)
