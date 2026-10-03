#!/usr/bin/env python3
"""Create and validate exact-tree UI receipts; any uncertainty runs fresh UI.

Only a successful, same-repository PR run from the accepted CI implementation
can provide evidence. Candidate critical smoke/static/packages/units stay fresh.
This module never posts checks, changes queue policy, or retries failed tests.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

from c1_ui_case_inventory import cases
from c1_ui_partition import partition, runtime_weights
from c1_xcresult_parse import case_key, matches_requested, parse, walk

ROOT = Path(__file__).resolve().parent.parent
PARTITIONS = 12
APP_ID = 15368
VALIDATION_PATHS = (".github/", "scripts/", "HermesFleetAppUITests/", "HermesFleetAppTests/")


def check(condition, reason):
    if not condition:
        raise ValueError(reason)


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, stderr=subprocess.DEVNULL,
                                   timeout=45).decode().strip()


def git(*args):
    return command("git", *args)


def api(repository, path, binary=False):
    value = subprocess.check_output(["gh", "api", f"repos/{repository}/{path}"],
                                    stderr=subprocess.DEVNULL, timeout=45)
    return value if binary else json.loads(value)


def validation_changed(base):
    paths = git("diff", "--name-only", f"{base}...HEAD").splitlines()
    return any(path.startswith(VALIDATION_PATHS) or "/Tests/" in path for path in paths)


def environment():
    # Match the actual selected device model/runtime, never the host's UDID.
    destination = command("bash", "scripts/sim_destination.sh", "iphone")
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    runtimes = {item["identifier"]: item for item in
                json.loads(command("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]}
    options = dict(item.split("=", 1) for item in destination.split(","))
    matching = [(runtime, device) for runtime, items in devices.items() for device in items
                if (options.get("id") == device["udid"] if "id" in options
                    else options.get("name") == device["name"])]
    check(bool(matching), "selected simulator missing")
    matching.sort(key=lambda pair: tuple(int(p) for p in runtimes[pair[0]]["version"].split(".")), reverse=True)
    runtime_id, device = matching[0]
    check(sum(pair[0] == runtime_id for pair in matching) == 1, "ambiguous simulator selection")
    runtime = runtimes[runtime_id]
    locks = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
             for path in git("ls-files", "*Package.resolved").splitlines()}
    resolved = ROOT / "HermesFleetApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins = json.loads(resolved.read_text())["pins"]
    check(bool(pins) and len({item["identity"] for item in pins}) == len(pins)
          and all(re.fullmatch(r"[0-9a-f]{40}", item["state"].get("revision", "")) for item in pins),
          "dependency revision inventory missing")
    canonical = json.dumps(sorted(pins, key=lambda item: item["identity"]), sort_keys=True).encode()
    locks["xcode_resolved_pins"] = hashlib.sha256(canonical).hexdigest()
    return {
        "xcode": command("xcodebuild", "-version"),
        "swift": command("xcrun", "swift", "--version"),
        "sdk_version": command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
        "sdk_build": command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"),
        "macos": command("sw_vers", "-productVersion"),
        "macos_build": command("sw_vers", "-buildVersion"),
        "architecture": command("uname", "-m"),
        "runner_image": os.environ.get("ImageOS", "local"),
        "runner_image_version": os.environ.get("ImageVersion", "local"),
        "device_type": device["deviceTypeIdentifier"],
        "runtime": runtime_id, "runtime_version": runtime["version"],
        "runtime_build": runtime["buildversion"], "dependency_locks": locks,
        "build_policy": "HermesFleetApp/Debug/skipMacroValidation/simulator-signing/retry2/relaunch",
    }


def result_cases(results, selected):
    evidence = {}
    reusable = True
    for name in selected:
        summary = json.loads((results / f"{name}.summary.json").read_text())
        tests = json.loads((results / f"{name}.tests.json").read_text())
        expected = set(cases(ROOT, name))
        allowed = {"testIPadLandscapePreservesRootNavigation()"} if name == "U3TabNavigation" else set()
        verdict = parse(summary, tests, name + "UITests", allowed, expected)
        check(verdict[1:4] == (0, 1, 1), "incomplete or failed UI receipt")
        records = {method: [] for method in expected}
        for node in walk(tests):
            if node.get("nodeType") == "Test Case" and matches_requested(node, name + "UITests"):
                method = case_key(node, name + "UITests").split("/", 1)[1]
                check(method in records, "unexpected UI case")
                records[method].append(node.get("result"))
        # Fresh runner may explicitly report recovered retries. Retain them;
        # they never qualify as clean evidence for avoiding a candidate run.
        reusable &= all(len(attempts) == 1 for attempts in records.values())
        evidence[name] = records
    return evidence, reusable


def create(base, shard, requested, selected, results):
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    records, clean_attempts = result_cases(results, selected) if selected else ({}, True)
    try:
        fingerprint = environment() if selected else None
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        fingerprint = None  # Missing metadata only disables reuse, never invents it.
    return {
        "schema": 1, "repository": os.environ["GITHUB_REPOSITORY"],
        "repository_id": int(os.environ["GITHUB_REPOSITORY_ID"]),
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
        "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "event": os.environ["GITHUB_EVENT_NAME"],
        "source_head": event.get("pull_request", {}).get("head", {}).get("sha"),
        "checkout": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"),
        "base": git("rev-parse", base), "environment": fingerprint,
        "validation_changed": validation_changed(base),
        "clean_checkout": not git("status", "--porcelain", "--untracked-files=no"),
        "clean_attempts": bool(clean_attempts), "shard": shard, "shards": PARTITIONS,
        "requested": requested, "selected": selected, "cases": records,
    }


def validate_receipts(receipts, context):
    check(len(receipts) == PARTITIONS, "missing UI partitions")
    check({r["shard"] for r in receipts} == set(range(1, PARTITIONS + 1)), "duplicate UI partition")
    buckets = partition(context["requested"], runtime_weights(ROOT / "scripts/c1_ui_matrix.sh"), PARTITIONS)
    for receipt in receipts:
        for key in ("repository", "repository_id", "run_id", "source_head", "tree", "base", "requested"):
            check(receipt.get(key) == context[key], f"receipt {key} mismatch")
        check(receipt.get("schema") == 1 and receipt.get("shards") == PARTITIONS, "receipt schema mismatch")
        check(receipt.get("event") == "pull_request" and receipt.get("run_attempt") == 1, "untrusted receipt event/attempt")
        check(receipt.get("validation_changed") is False and receipt.get("clean_checkout") is True
              and receipt.get("clean_attempts") is True, "changed validation, dirty source or retry evidence")
        selected = buckets[receipt["shard"] - 1]
        if selected:
            check(isinstance(context["environment"], dict) and bool(context["environment"])
                  and receipt.get("environment") == context["environment"], "receipt environment mismatch")
        check(receipt.get("selected") == selected, "receipt selection mismatch")
        check(set(receipt["cases"]) == set(selected), "receipt class inventory mismatch")
        for name, records in receipt["cases"].items():
            check(set(records) == set(cases(ROOT, name)), "receipt case inventory mismatch")
            for method, attempts in records.items():
                allowed = ["Skipped"] if name == "U3TabNavigation" and method == "testIPadLandscapePreservesRootNavigation()" else None
                check(attempts in (["Passed"], ["Expected Failure"]) or attempts == allowed,
                      "failed, skipped, missing or retried case")


def validate_run(run, jobs, checks, repository, repository_id, head):
    check(run.get("event") == "pull_request" and run.get("path") == ".github/workflows/ci.yml", "untrusted workflow")
    check(run.get("head_sha") == head and run.get("head_repository", {}).get("id") == repository_id, "foreign/stale source run")
    check(run.get("status") == "completed" and run.get("conclusion") == "success" and run.get("run_attempt") == 1, "failed/incomplete/retried source run")
    age = (datetime.now(timezone.utc) - datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))).total_seconds()
    check(0 <= age <= 24 * 3600, "expired source evidence")
    for name in ["CI Gate", *[f"UI preflight {i}/12 (changed area)" for i in range(1, PARTITIONS + 1)]]:
        matching = [job for job in jobs if job.get("name") == name]
        check(len(matching) == 1 and matching[0].get("status") == "completed"
              and matching[0].get("conclusion") == "success", "missing/non-successful source job")
    prefix = f"https://github.com/{repository}/actions/runs/{run['id']}/job/"
    check(any(item.get("name") == "CI Gate" and item.get("app", {}).get("id") == APP_ID
              and item.get("head_sha") == head and item.get("status") == "completed"
              and item.get("conclusion") == "success" and item.get("details_url", "").startswith(prefix)
              for item in checks), "missing actual Actions CI Gate")


def artifact_receipt(artifact, archive, repository_id, run_id, head, shard):
    check(artifact.get("expired") is False and artifact.get("name") == f"ui-receipt-{shard}-attempt-1", "missing/expired artifact")
    origin = artifact.get("workflow_run", {})
    check(origin.get("id") == run_id and origin.get("head_sha") == head
          and origin.get("repository_id") == origin.get("head_repository_id") == repository_id, "foreign artifact")
    check(artifact.get("digest") == "sha256:" + hashlib.sha256(archive).hexdigest(), "artifact digest mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        names = bundle.namelist()
        check(names == [f"ui-receipt-{shard}.json"], "unexpected artifact contents")
        check(bundle.getinfo(names[0]).file_size <= 2_000_000, "oversized receipt")
        return json.loads(bundle.read(names[0]))


def reuse(base, shard, requested):
    check(os.environ.get("GITHUB_EVENT_NAME") == "merge_group", "fresh PR/local execution")
    check(bool(requested), "empty selection executes fresh without UI tests")
    check(not validation_changed(base), "validation implementation changed; run fresh")
    check(not git("status", "--porcelain", "--untracked-files=no"), "dirty candidate")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    ref = event["merge_group"]["head_ref"]
    match = re.fullmatch(r"(?:refs/heads/)?gh-readonly-queue/main/pr-(\d+)-[0-9a-f]{40}", ref)
    check(match is not None, "only a single-PR main merge group is supported")
    repository = os.environ["GITHUB_REPOSITORY"]
    repository_id = int(os.environ["GITHUB_REPOSITORY_ID"])
    pr = api(repository, f"pulls/{match[1]}")
    check(pr["state"] == "open" and not pr["draft"] and pr["base"]["ref"] == "main"
          and pr["head"]["repo"]["id"] == repository_id, "untrusted PR source")
    head = pr["head"]["sha"]
    candidate_base = git("rev-parse", base)
    check(git("show", "-s", "--format=%P", "HEAD").split() == [candidate_base], "unexpected candidate ancestry")
    # Resolve the candidate's own graph before comparing dependencies. The
    # repository ignores generated lockfiles; source receipts hash actual pins
    # after compilation, including exact transitive revisions. Never assume
    # floating transitive requirements resolved to the same commits.
    dependency_log = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "ui-reuse-dependencies.log"
    with dependency_log.open("wb") as log:
        resolved = subprocess.run(["xcodebuild", "-project", "HermesFleetApp.xcodeproj",
                                   "-scheme", "HermesFleetApp", "-resolvePackageDependencies",
                                   "-clonedSourcePackagesDirPath", "build/ReceiptDependencies",
                                   "-skipMacroValidation"], cwd=ROOT, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=240)
    check(resolved.returncode == 0, "candidate dependency resolution failed")
    context = {"repository": repository, "repository_id": repository_id, "source_head": head,
               "tree": git("rev-parse", "HEAD^{tree}"), "base": candidate_base,
               "environment": environment(), "requested": requested}
    runs = api(repository, f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}&status=success&per_page=20")["workflow_runs"]
    check(bool(runs), "no successful source run")
    # Prefer the most recent exact-head run. Any missing proof falls back to
    # fresh execution, rather than searching for a convenient older result.
    run = max(runs, key=lambda item: item["id"])
    context["run_id"] = run["id"]
    jobs = api(repository, f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
    checks = api(repository, f"commits/{head}/check-runs?check_name=CI%20Gate&per_page=100")["check_runs"]
    validate_run(run, jobs, checks, repository, repository_id, head)
    artifacts = api(repository, f"actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"]
    receipts, verified_artifacts = [], []
    for number in range(1, PARTITIONS + 1):
        matching = [item for item in artifacts if item["name"] == f"ui-receipt-{number}-attempt-1"]
        check(len(matching) == 1, "incomplete artifact set")
        artifact = matching[0]
        check(artifact.get("size_in_bytes", 0) <= 2_000_000, "oversized artifact")
        receipt = artifact_receipt(artifact, api(repository, f"actions/artifacts/{artifact['id']}/zip", binary=True),
                                   repository_id, run["id"], head, number)
        checkout = api(repository, f"git/commits/{receipt['checkout']}")
        parents = [item["sha"] for item in checkout["parents"]]
        check(checkout["tree"]["sha"] == context["tree"] and
              (receipt["checkout"] == head or parents == [candidate_base, head]), "source checkout ancestry/tree mismatch")
        receipts.append(receipt)
        verified_artifacts.append({"id": artifact["id"], "digest": artifact["digest"], "shard": number})
    validate_receipts(receipts, context)
    return {"schema": 1, "mode": "verified-source-reuse", "candidate": git("rev-parse", "HEAD"),
            "tree": context["tree"], "source_run": run["id"], "source_head": head, "shard": shard,
            "selected": receipts[shard - 1]["selected"], "artifacts": verified_artifacts,
            "environment": context["environment"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("create", "reuse"))
    parser.add_argument("--base", required=True)
    parser.add_argument("--shard", required=True, type=int)
    parser.add_argument("--requested", default="")
    parser.add_argument("--selected", default="")
    parser.add_argument("--results", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        check(1 <= args.shard <= PARTITIONS, "invalid receipt partition")
        if args.mode == "reuse":
            receipt = reuse(args.base, args.shard, args.requested.split())
        else:
            receipt = create(args.base, args.shard, args.requested.split(), args.selected.split(), args.results)
        args.output.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
        print(f"UI-RECEIPT: {args.mode} verified partition {args.shard}/{PARTITIONS}")
        return 0
    except (OSError, KeyError, TypeError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError):
        # Do not print exception contents: network/tool errors may include
        # private paths, credentials, or an expiring artifact download URL.
        print("UI-RECEIPT: evidence unavailable or mismatched; fresh UI required")
        return 10 if args.mode == "reuse" else 1


if __name__ == "__main__":
    raise SystemExit(main())
