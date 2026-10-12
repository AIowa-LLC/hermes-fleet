#!/usr/bin/env python3
"""Offline candidate installer for the reviewed Hermes Fleet source overlay.

All source writes target an explicit checkout. User homes, PM runtimes, credentials,
database files, settings, and services are outside this tool's mutation surface.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent
RELEASE = ROOT / "release"
MANIFEST = RELEASE / "manifest.json"
PATCH = RELEASE / "overlay.patch"
UPGRADE_PATCH = RELEASE / "upgrade.patch"
PLUGIN_BUNDLE = RELEASE / "owner-control.bundle"
BASE = "46d7718a52ff33accb15dc0501736fbdb6833cab"
SUPPORTED_OVERLAY = "ecd22716c35c6993797808cfd9c05feb8fa0193f"
SUPPORTED_TARGET = "1bffff90b482dba75aeb9c55a5fb704c74c75841"
REQUIRED_COMMITS = (
    "cbf5026597", "7d2c3ea5dc", "b1e250c71c", "4b98998c5a",
    "c4475eed69", "be9e48928a", "ecd22716c3",
)
REQUIRED_SUPPORT_FILES = {
    "README.md", "installer.py", "build_release.py", "readiness.py", "record_observations.py",
    "qr_display.py", "tests/test_installer.py",
    "owner_control/__init__.py", "owner_control/plugin.yaml",
    "owner_control/readiness.py", "owner_control/qr_display.py",
    "owner_control/tests/test_owner_control.py",
    "owner_control/tests/test_registration_integration.py",
}
TEST_PATHS = (
    "tests/gateway/test_prompt_tail_freeze.py",
    "tests/gateway/test_slash_access.py",
    "tests/gateway/test_telegram_pairing_owner_context.py",
    "tests/hermes_cli/test_dashboard_auth_body_limit.py",
    "tests/hermes_cli/test_fleet_device_pairing_http.py",
    "tests/hermes_cli/test_fleet_device_pairing_network.py",
    "tests/hermes_cli/test_fleet_device_pairing_store.py",
    "tests/hermes_cli/test_fleet_pairing_cli.py",
)


class Refusal(RuntimeError):
    """A fail-closed compatibility or integrity result."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_release(trusted_manifest_sha256: str) -> tuple[dict, bytes, str]:
    manifest_raw = MANIFEST.read_bytes()
    manifest_sha = digest(manifest_raw)
    if not secrets.compare_digest(manifest_sha, trusted_manifest_sha256.lower()):
        raise Refusal("manifest differs from the independently supplied trusted SHA256")
    manifest = json.loads(manifest_raw)
    patch = PATCH.read_bytes()
    upgrade_patch = UPGRADE_PATCH.read_bytes()
    if manifest.get("patch_sha256") != digest(patch):
        raise Refusal("patch digest does not match the trusted manifest")
    if manifest.get("upgrade_patch_sha256") != digest(upgrade_patch):
        raise Refusal("upgrade patch digest does not match the trusted manifest")
    plugin_bundle = PLUGIN_BUNDLE.read_bytes()
    if manifest.get("plugin_bundle_sha256") != digest(plugin_bundle):
        raise Refusal("owner-control bundle digest does not match the trusted manifest")
    plugin_commit = manifest.get("plugin_commit")
    if not isinstance(plugin_commit, str) or len(plugin_commit) != 40:
        raise Refusal("manifest has no immutable owner-control plugin commit")
    refs = subprocess.run(["git", "bundle", "list-heads", str(PLUGIN_BUNDLE)],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if refs.returncode or f"{plugin_commit} refs/heads/main" not in refs.stdout.splitlines():
        raise Refusal("owner-control bundle main ref differs from its manifest commit")
    commits = manifest.get("commits")
    if (manifest.get("base_commit") != BASE or not isinstance(commits, list)
            or tuple(row.get("short") for row in commits[:len(REQUIRED_COMMITS)]) != REQUIRED_COMMITS
            or not commits or commits[-1].get("full") != manifest.get("target_commit")
            or manifest.get("target_commit") != SUPPORTED_TARGET
            or len(commits) != len(REQUIRED_COMMITS) + 1
            or commits[-1].get("short") != SUPPORTED_TARGET[:10]):
        raise Refusal("manifest commit provenance differs from this reviewed installer")
    if manifest.get("supported_overlay_commit") != SUPPORTED_OVERLAY:
        raise Refusal("manifest does not identify the supported earlier Fleet overlay")
    paths = manifest.get("paths")
    if not isinstance(paths, dict) or not paths:
        raise Refusal("manifest has no changed-file digest map")
    if sorted(paths) != manifest.get("changed_paths"):
        raise Refusal("manifest changed-path list and digest map differ")
    for rel, hashes in paths.items():
        p = PurePosixPath(rel)
        if p.is_absolute() or not p.parts or ".." in p.parts or "\\" in rel:
            raise Refusal(f"unsafe manifest path: {rel!r}")
        if set(hashes) != {"before_sha256", "after_sha256"}:
            raise Refusal(f"invalid digest record: {rel}")
        for sha in hashes.values():
            if sha is not None and (not isinstance(sha, str) or len(sha) != 64):
                raise Refusal(f"invalid SHA256 record: {rel}")
    supported = manifest.get("supported_preimages")
    upgrade_paths = manifest.get("upgrade_paths")
    if not isinstance(supported, dict) or set(supported) != set(paths):
        raise Refusal("manifest lacks a complete prior-overlay preimage map")
    if not isinstance(upgrade_paths, dict) or not set(upgrade_paths).issubset(paths):
        raise Refusal("manifest has an invalid upgrade path map")
    support = manifest.get("support_files")
    if not isinstance(support, dict) or not REQUIRED_SUPPORT_FILES.issubset(support):
        raise Refusal("manifest does not inventory the offline installer and helper assets")
    for rel, expected in support.items():
        path = safe_file(ROOT, rel)
        if len(expected) != 64 or file_hash(path) != expected:
            raise Refusal(f"offline support file changed or is missing: {rel}")
    return manifest, patch, manifest_sha


def git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise Refusal(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def source_state(root: Path) -> tuple[str, list[str]]:
    if not root.is_dir():
        raise Refusal(f"source checkout not found: {root}")
    return (git(root, "rev-parse", "HEAD"),
            git(root, "status", "--porcelain", "--untracked-files=all").splitlines())


def safe_file(root: Path, rel: str) -> Path:
    p = PurePosixPath(rel)
    if p.is_absolute() or ".." in p.parts or "\\" in rel:
        raise Refusal(f"unsafe path: {rel}")
    result = root.joinpath(*p.parts)
    cursor = root
    for part in p.parts:
        cursor /= part
        if cursor.is_symlink():
            raise Refusal(f"symlink in overlay path: {rel}")
    if not result.resolve().is_relative_to(root.resolve()):
        raise Refusal(f"path escapes checkout: {rel}")
    return result


def file_hash(path: Path) -> str | None:
    return digest(path.read_bytes()) if path.is_file() else None


def verify_files(root: Path, manifest: dict, side: str) -> None:
    key = f"{side}_sha256"
    for rel, record in manifest["paths"].items():
        actual = file_hash(safe_file(root, rel))
        if actual != record[key]:
            raise Refusal(f"capability digest mismatch for {rel}: expected {record[key]}, got {actual}")


def source_kind(root: Path, manifest: dict) -> str:
    if all(file_hash(safe_file(root, rel)) == hashes["after_sha256"]
           for rel, hashes in manifest["paths"].items()):
        return "present"
    try:
        verify_files(root, manifest, "before")
        return "base"
    except Refusal:
        for rel, expected in manifest["supported_preimages"].items():
            actual = file_hash(safe_file(root, rel))
            if actual != expected:
                raise Refusal(f"capability digest mismatch for supported preimage {rel}")
        return "upgrade"


def patch_for(manifest: dict, mode: str, full_patch: bytes) -> bytes:
    if mode == "base":
        return full_patch
    if mode == "upgrade":
        return UPGRADE_PATCH.read_bytes()
    return b""


def mode_paths(manifest: dict, mode: str) -> dict:
    return manifest["paths"] if mode == "base" else manifest["upgrade_paths"]


def tree_fingerprint(root: Path) -> str:
    data = subprocess.run(["git", "-C", str(root), "diff", "--binary", "--full-index", "HEAD"],
                          check=True, stdout=subprocess.PIPE).stdout
    return digest(data)


def reject_untracked_candidate_files(root: Path, manifest: dict) -> None:
    allowed = {".fleet-overlay-candidate.json", ".fleet-overlay-test-receipt.json"}
    allowed.update(rel for rel, hashes in manifest["paths"].items()
                   if hashes["before_sha256"] is None and file_hash(safe_file(root, rel)) == hashes["after_sha256"])
    files = git(root, "ls-files", "--others", "--exclude-standard").splitlines()
    unexpected = sorted(set(files) - allowed)
    if unexpected:
        raise Refusal("candidate contains unexpected untracked files: " + ", ".join(unexpected[:10]))


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    with temporary.open("rb") as stream:
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def plan(args: argparse.Namespace) -> None:
    manifest, _, _ = load_release(args.trusted_manifest_sha256)
    source = Path(args.source).expanduser().resolve()
    head, dirty = source_state(source)
    if dirty:
        print(f"Source: {source}\nHEAD: {head}\nStatus: BLOCKED (dirty; {len(dirty)} entries)")
        for entry in dirty[:20]:
            print(f"  {entry}")
        return
    try:
        kind = source_kind(source, manifest)
    except Refusal as exc:
        print(f"Source: {source}\nHEAD: {head}\nStatus: BLOCKED ({exc})")
        return
    status = ("clean stock source; candidate staging is eligible" if kind == "base"
              else "clean ECD overlay; safety-upgrade candidate staging is eligible" if kind == "upgrade"
              else "final overlay capabilities already present and verified")
    print(f"Source: {source}\nHEAD: {head}\nStatus: {status}")


def candidate(args: argparse.Namespace) -> None:
    manifest, patch, manifest_sha = load_release(args.trusted_manifest_sha256)
    source = Path(args.source).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    if output == source or output.is_relative_to(source):
        raise Refusal("candidate directory must be outside the Hermes source checkout")
    head, dirty = source_state(source)
    if dirty:
        raise Refusal("candidate source is dirty; inspect and preserve local edits before retrying")
    mode = source_kind(source, manifest)
    if output.exists():
        raise Refusal(f"candidate destination already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    clone = subprocess.run(["git", "clone", "--no-hardlinks", "--local", str(source), str(output)],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if clone.returncode:
        raise Refusal(clone.stderr.strip() or "could not create isolated source candidate")
    selected_patch = patch_for(manifest, mode, patch)
    if mode in {"base", "upgrade"}:
        patch_path = PATCH if mode == "base" else UPGRADE_PATCH
        check = subprocess.run(["git", "-C", str(output), "apply", "--check", str(patch_path)],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check.returncode:
            shutil.rmtree(output, ignore_errors=True)
            raise Refusal("overlay conflicts with candidate source: " + check.stderr.strip())
        applied = subprocess.run(["git", "-C", str(output), "apply", str(patch_path)],
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if applied.returncode:
            shutil.rmtree(output, ignore_errors=True)
            raise Refusal("candidate patch failed: " + applied.stderr.strip())
    verify_files(output, manifest, "after")
    write_json(output / ".fleet-overlay-candidate.json", {
        "source": str(source), "source_head": head, "source_tree": git(source, "rev-parse", "HEAD^{tree}"),
        "candidate": str(output),
        "candidate_head": git(output, "rev-parse", "HEAD"), "install_mode": mode,
        "patch_sha256": digest(selected_patch), "release_patch_sha256": digest(patch),
        "manifest_sha256": manifest_sha, "candidate_tree": tree_fingerprint(output),
        "already_present": mode == "present"})
    if mode == "present":
        print("Capabilities already present and verified; no candidate patch was needed.")
        return
    print(f"Isolated candidate staged: {output}")


def candidate_record(path: Path, trusted_manifest_sha256: str) -> tuple[dict, dict, bytes]:
    record_path = path / ".fleet-overlay-candidate.json"
    if not record_path.is_file():
        raise Refusal("candidate metadata is missing")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    manifest, patch, manifest_sha = load_release(trusted_manifest_sha256)
    selected_patch = patch_for(manifest, record.get("install_mode", ""), patch)
    if (record.get("patch_sha256") != digest(selected_patch)
            or record.get("release_patch_sha256") != digest(patch)
            or record.get("manifest_sha256") != manifest_sha):
        raise Refusal("candidate is bound to another release")
    if record.get("candidate_tree") != tree_fingerprint(path):
        raise Refusal("candidate source changed after staging")
    reject_untracked_candidate_files(path, manifest)
    verify_files(path, manifest, "after")
    return record, manifest, selected_patch


def validate(args: argparse.Namespace) -> None:
    """Execute the fixed Hermes test selection under temporary HOME/runtime and bind a receipt."""
    candidate_path = Path(args.candidate).expanduser().resolve()
    record, _manifest, patch = candidate_record(candidate_path, args.trusted_manifest_sha256)
    if record.get("already_present"):
        raise Refusal("source already has capabilities; there is no staged candidate to test")
    # Preserve the venv's executable symlink: resolving it selects the base Python,
    # which may not have the approved Hermes test environment's pytest/runtime deps.
    interpreter = Path(args.python).expanduser().absolute()
    if not interpreter.is_file() or not os.access(interpreter, os.X_OK):
        raise Refusal("approved test interpreter is missing or not executable")
    probe = subprocess.run([str(interpreter), "-c", "import pytest"], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE)
    if probe.returncode:
        raise Refusal("approved test interpreter is unavailable or lacks pytest")
    with tempfile.TemporaryDirectory(prefix="fleet-overlay-validation-") as work:
        isolation = Path(work)
        home = isolation / "home"
        (home / ".hermes").mkdir(parents=True)
        runtime = isolation / "runtime"
        runtime.mkdir()
        log_path = isolation / "run_tests.log"
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
               "HERMES_HOME": str(home / ".hermes"), "HERMES_RUNTIME_DIR": str(runtime),
               "HERMES_PYTHON": str(interpreter), "HERMES_TEST_WORKERS": "1",
               "TZ": "UTC", "LANG": "C.UTF-8"}
        command = ["bash", "scripts/run_tests.sh", *TEST_PATHS]
        with log_path.open("wb") as log:
            result = subprocess.run(command, cwd=candidate_path, env=env, stdout=log,
                                    stderr=subprocess.STDOUT)
        output = log_path.read_bytes()
        external_log = Path(args.log).expanduser().resolve()
        if external_log.exists() or external_log.is_symlink():
            raise Refusal(f"validation log already exists; refusing overwrite: {external_log}")
        source_path = Path(record["source"]).resolve()
        if (external_log == candidate_path or external_log.is_relative_to(candidate_path)
                or external_log == source_path or external_log.is_relative_to(source_path)):
            raise Refusal("validation log must be stored outside the candidate and source checkout")
        external_log.parent.mkdir(parents=True, exist_ok=True)
        external_log.write_bytes(output)
        output_sha = digest(output)
        if result.returncode:
            tail = output.decode(encoding="utf-8", errors="replace")[-2000:]
            raise Refusal(f"scripts/run_tests.sh exited {result.returncode}; full log saved to {external_log}; tail:\n{tail}")
    write_json(candidate_path / ".fleet-overlay-test-receipt.json", {
        "candidate": str(candidate_path), "source": record["source"],
        "source_head": record["source_head"], "source_tree": record["source_tree"],
        "candidate_tree": record["candidate_tree"],
        "patch_sha256": digest(patch), "manifest_sha256": record["manifest_sha256"],
        "test_command": command, "test_interpreter": str(interpreter),
        "test_log_path": str(external_log),
        "test_output_sha256": output_sha, "passed": True,
        "exit_code": result.returncode, "test_exit_code": result.returncode})
    print(f"Canonical focused Hermes tests passed; bound receipt recorded. Full log: {external_log}")


def require_receipt(path: Path, source: Path, head: str, record: dict) -> None:
    receipt_path = path / ".fleet-overlay-test-receipt.json"
    if not receipt_path.is_file():
        raise Refusal("candidate has no successful validate receipt")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    expected = {"candidate": str(path), "source": str(source), "source_head": head,
                "source_tree": record["source_tree"],
                "candidate_tree": record["candidate_tree"], "patch_sha256": record["patch_sha256"],
                "manifest_sha256": record["manifest_sha256"], "passed": True, "exit_code": 0}
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise Refusal("test receipt is stale or bound to another source, candidate, or release")
    if receipt.get("test_command") != ["bash", "scripts/run_tests.sh", *TEST_PATHS]:
        raise Refusal("test receipt does not identify the fixed canonical test selection")
    if receipt.get("test_exit_code") != 0:
        raise Refusal("test receipt does not record a successful runner exit")
    interpreter = receipt.get("test_interpreter")
    if not isinstance(interpreter, str) or not Path(interpreter).is_absolute():
        raise Refusal("test receipt does not identify its approved interpreter")
    log_path = Path(receipt.get("test_log_path", "")).expanduser().resolve()
    if not log_path.is_file() or file_hash(log_path) != receipt.get("test_output_sha256"):
        raise Refusal("full test log is missing or differs from its receipt digest")


def apply(args: argparse.Namespace) -> None:
    source = Path(args.source).expanduser().resolve()
    candidate_path = Path(args.candidate).expanduser().resolve()
    record, manifest, selected_patch = candidate_record(candidate_path, args.trusted_manifest_sha256)
    head, dirty = source_state(source)
    if dirty:
        raise Refusal("apply target is dirty; no files changed")
    if (record.get("source") != str(source) or record.get("source_head") != head
            or record.get("source_tree") != git(source, "rev-parse", "HEAD^{tree}")):
        raise Refusal("candidate was staged against another source path or revision")
    if source_kind(source, manifest) == "present":
        print("Capabilities already present; no source files changed.")
        return
    if source_kind(source, manifest) != record.get("install_mode"):
        raise Refusal("candidate install mode differs from current source capabilities")
    require_receipt(candidate_path, source, head, record)
    if record["install_mode"] == "base":
        verify_files(source, manifest, "before")
    else:
        for rel, expected in manifest["supported_preimages"].items():
            if file_hash(safe_file(source, rel)) != expected:
                raise Refusal(f"upgrade preimage changed for {rel}")
    state_root = Path(args.state).expanduser().resolve()
    if state_root == source or state_root.is_relative_to(source):
        raise Refusal("transaction state must be outside the Hermes source checkout")
    state_root.mkdir(parents=True, exist_ok=True)
    txn = state_root / ("txn-" + uuid.uuid4().hex)
    backups = txn / "backup"
    transaction_paths = mode_paths(manifest, record["install_mode"])
    backup_modes = {}
    for rel in transaction_paths:
        target = safe_file(source, rel)
        backup = safe_file(backups, rel)
        backup.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            shutil.copy2(target, backup)
            backup_modes[rel] = stat.S_IMODE(backup.stat().st_mode)
        else:
            backup_modes[rel] = None
    journal = {"state": "prepared", "source": str(source), "head": head,
               "patch_sha256": digest(selected_patch), "manifest_sha256": record["manifest_sha256"],
               "install_mode": record["install_mode"],
               "backup_dir": str(backups), "paths": transaction_paths,
               "backup_modes": backup_modes}
    write_json(txn / "journal.json", journal)
    patch_path = PATCH if record["install_mode"] == "base" else UPGRADE_PATCH
    result = subprocess.run(["git", "-C", str(source), "apply", str(patch_path)],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise Refusal(f"apply interrupted or failed; recovery journal {txn / 'journal.json'}: {result.stderr.strip()}")
    verify_files(source, manifest, "after")
    journal["state"] = "applied"
    write_json(txn / "journal.json", journal)
    print(f"Overlay source files applied. Recovery journal: {txn / 'journal.json'}")
    print("PM environment refresh and service activation remain separate operator actions.")


def atomic_restore(target: Path, backup: Path, mode: int) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".fleet-restore-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(backup.read_bytes())
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, mode)
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def rollback(args: argparse.Namespace) -> None:
    journal_path = Path(args.journal).expanduser().resolve()
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    manifest, full_patch, manifest_sha = load_release(args.trusted_manifest_sha256)
    source = Path(journal["source"]).resolve()
    head, _dirty = source_state(source)
    if head != journal["head"] or journal.get("manifest_sha256") != manifest_sha:
        raise Refusal("source revision or trusted release differs from apply journal")
    mode = journal.get("install_mode")
    selected_patch = patch_for(manifest, mode, full_patch)
    if (journal["patch_sha256"] != digest(selected_patch)
            or journal["paths"] != mode_paths(manifest, mode)):
        raise Refusal("journal provenance or path map differs from trusted release")
    backup_dir = Path(journal["backup_dir"]).resolve()
    if backup_dir != (journal_path.parent / "backup").resolve():
        raise Refusal("journal backup directory is not bound to its transaction folder")
    transaction_paths = journal["paths"]
    backup_modes = journal.get("backup_modes")
    if not isinstance(backup_modes, dict) or set(backup_modes) != set(transaction_paths):
        raise Refusal("journal has no complete backup mode map")
    for rel, hashes in transaction_paths.items():
        target, backup = safe_file(source, rel), safe_file(backup_dir, rel)
        if file_hash(target) not in {hashes["before_sha256"], hashes["after_sha256"]}:
            raise Refusal(f"{rel} changed after apply; preserving it and refusing rollback")
        if file_hash(backup) != hashes["before_sha256"]:
            raise Refusal(f"backup digest mismatch for {rel}")
        expected_mode = backup_modes[rel]
        actual_mode = stat.S_IMODE(backup.stat().st_mode) if backup.exists() else None
        if actual_mode != expected_mode:
            raise Refusal(f"backup mode mismatch for {rel}")
    for rel in transaction_paths:
        backup = safe_file(backup_dir, rel)
        target = safe_file(source, rel)
        if backup.exists():
            atomic_restore(target, backup, backup_modes[rel])
        else:
            target.unlink(missing_ok=True)
    if mode not in {"base", "upgrade"}:
        raise Refusal("unknown install mode in rollback journal")
    for rel, hashes in transaction_paths.items():
        if file_hash(safe_file(source, rel)) != hashes["before_sha256"]:
            raise Refusal(f"rollback did not restore transaction preimage {rel}")
    journal["state"] = "rolled_back"
    write_json(journal_path, journal)
    print("Overlay source files rolled back; unrelated paths, PM runtime, and services were untouched.")


def add_trust(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--trusted-manifest-sha256", required=True,
                        help="independently pinned SHA256 of release/manifest.json")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    actions = root.add_subparsers(dest="action", required=True)
    p = actions.add_parser("plan", help="read-only source status")
    p.add_argument("--source", required=True)
    add_trust(p)
    p.set_defaults(run=plan)
    p = actions.add_parser("candidate", help="stage an isolated source candidate")
    p.add_argument("--source", required=True)
    p.add_argument("--output", required=True)
    add_trust(p)
    p.set_defaults(run=candidate)
    p = actions.add_parser("validate", help="run fixed focused tests and record a bound receipt")
    p.add_argument("--candidate", required=True)
    p.add_argument("--python", required=True, help="approved test interpreter with pytest")
    p.add_argument("--log", required=True, help="new full test-log file outside the candidate")
    add_trust(p)
    p.set_defaults(run=validate)
    p = actions.add_parser("apply", help="apply the validated source overlay")
    p.add_argument("--source", required=True)
    p.add_argument("--candidate", required=True)
    p.add_argument("--state", required=True, help="transaction directory outside the Hermes checkout")
    add_trust(p)
    p.set_defaults(run=apply)
    p = actions.add_parser("rollback", help="restore changed source files from a transaction journal")
    p.add_argument("--journal", required=True)
    add_trust(p)
    p.set_defaults(run=rollback)
    return root


def main() -> int:
    try:
        args = parser().parse_args()
        args.run(args)
    except (Refusal, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
