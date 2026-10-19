#!/usr/bin/env python3
"""Rebuild the pinned offline Fleet overlay from an existing local Hermes git object database."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tempfile

BASE = "46d7718a52ff33accb15dc0501736fbdb6833cab"
TARGET = "1bffff90b482dba75aeb9c55a5fb704c74c75841"
BASE_OVERLAY = "ecd22716c35c6993797808cfd9c05feb8fa0193f"
REQUIRED_COMMITS = [
    "cbf5026597", "7d2c3ea5dc", "b1e250c71c", "4b98998c5a",
    "c4475eed69", "be9e48928a", "ecd22716c3",
]
ALLOWLIST = sorted("""
docs/fleet-device-pairing.md
gateway/config_loader.py
gateway/run_agent_cache.py
gateway/run_turn.py
gateway/session.py
gateway/session_context_security.py
gateway/slash_access.py
hermes_cli/config_defaults.py
hermes_cli/dashboard_auth/audit.py
hermes_cli/dashboard_auth/body_limit.py
hermes_cli/dashboard_auth/fleet_device_provider.py
hermes_cli/dashboard_auth/fleet_devices.py
hermes_cli/dashboard_auth/fleet_pairing_routes.py
hermes_cli/dashboard_auth/public_paths.py
hermes_cli/dashboard_auth/registry.py
hermes_cli/dashboard_auth/request_utils.py
hermes_cli/dashboard_auth/routes.py
hermes_cli/fleet_pairing_cli.py
hermes_cli/web_server.py
scripts/fleet_pairing_dev_server.py
tests/gateway/test_prompt_tail_freeze.py
tests/gateway/test_slash_access.py
tests/gateway/test_telegram_pairing_owner_context.py
tests/hermes_cli/test_dashboard_auth_body_limit.py
tests/hermes_cli/test_fleet_device_pairing_http.py
tests/hermes_cli/test_fleet_device_pairing_network.py
tests/hermes_cli/test_fleet_device_pairing_store.py
tests/hermes_cli/test_fleet_pairing_cli.py
website/docs/user-guide/messaging/telegram.md
""".split())
REQUIRED_ASSETS = ["README.md", "installer.py", "build_release.py", "readiness.py", "record_observations.py",
                   "qr_display.py", "tests/test_installer.py", "tests/test_readiness_display.py",
                   "owner_control/__init__.py", "owner_control/plugin.yaml",
                   "owner_control/readiness.py", "owner_control/qr_display.py",
                   "owner_control/tests/test_owner_control.py",
                   "owner_control/tests/test_registration_integration.py"]
PLUGIN_FILES = ["__init__.py", "plugin.yaml", "readiness.py", "qr_display.py",
                "tests/test_owner_control.py", "tests/test_registration_integration.py"]


def run(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def file_at(repo: Path, revision: str, rel: str) -> bytes | None:
    result = subprocess.run(["git", "-C", str(repo), "show", f"{revision}:{rel}"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        message = result.stderr.decode(errors="replace")
        if "does not exist in" in message or "exists on disk, but not in" in message:
            return None
        raise RuntimeError(message.strip())
    return result.stdout


def sync_plugin_helpers(host_tools: Path) -> None:
    """Keep the standalone plugin's packaged helpers identical to their maintained sources."""
    package = host_tools / "owner_control"
    if package.is_symlink() or not package.is_dir():
        raise RuntimeError("owner-control package is missing or symlinked")
    pairs = [(host_tools / name, package / name) for name in ("readiness.py", "qr_display.py")]
    if any(source.is_symlink() or not source.is_file() or target.is_symlink() for source, target in pairs):
        raise RuntimeError("helper source or package target is missing or symlinked")
    for source, target in pairs:
        data = source.read_bytes()
        if not target.is_file() or target.read_bytes() != data:
            target.write_bytes(data)


def make_plugin_bundle(host_tools: Path, output: Path) -> tuple[str, str]:
    """Build a reproducible, self-contained local Git bundle for Hermes' supported plugin installer."""
    with tempfile.TemporaryDirectory(prefix="fleet-owner-plugin-build-") as temporary:
        repo = Path(temporary) / "owner-control"
        repo.mkdir()
        env = os.environ.copy()
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Fleet Offline Release",
                    "GIT_AUTHOR_EMAIL": "fleet-release@example.invalid",
                    "GIT_COMMITTER_NAME": "Fleet Offline Release",
                    "GIT_COMMITTER_EMAIL": "fleet-release@example.invalid",
                    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
                    "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000",
                    "LC_ALL": "C"})
        def git(*args: str) -> bytes:
            result = subprocess.run(["git", "-C", str(repo), *args], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError(result.stderr.decode(errors="replace").strip())
            return result.stdout
        init = subprocess.run(["git", "init", "--quiet", "--initial-branch=main", str(repo)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if init.returncode:
            raise RuntimeError(init.stderr.decode(errors="replace").strip())
        for rel in PLUGIN_FILES:
            source = host_tools / "owner_control" / rel
            if not source.is_file() or source.is_symlink():
                raise RuntimeError(f"plugin bundle asset is missing or symlinked: {rel}")
            target = repo / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            target.chmod(0o644)
        git("config", "user.name", "Fleet Offline Release")
        git("config", "user.email", "fleet-release@example.invalid")
        git("add", "--all")
        git("commit", "--quiet", "-m", "Fleet owner-control offline release")
        commit = git("rev-parse", "HEAD").decode().strip()
        git("bundle", "create", str(output), "refs/heads/main")
        git("bundle", "verify", str(output))
        return commit, hashlib.sha256(output.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="local Hermes git checkout; no network access")
    parser.add_argument("--target", default=TARGET,
                        help="reviewed target commit, for example a later safety-text commit")
    parser.add_argument("--base-overlay", default=BASE_OVERLAY,
                        help="known previously shipped overlay commit used for upgrade.patch")
    args = parser.parse_args()
    repo = Path(args.repo).expanduser().resolve()
    base = run(repo, "rev-parse", BASE).decode().strip()
    target = run(repo, "rev-parse", args.target).decode().strip()
    overlay_base = run(repo, "rev-parse", args.base_overlay).decode().strip()
    if base != BASE:
        raise RuntimeError("base commit did not resolve to the pinned full object id")
    run(repo, "merge-base", "--is-ancestor", base, target)
    run(repo, "merge-base", "--is-ancestor", overlay_base, target)
    changed = sorted(run(repo, "diff", "--name-only", "-z", base, target).decode().split("\0"))
    changed = [item for item in changed if item]
    if changed != ALLOWLIST:
        unexpected = sorted(set(changed) - set(ALLOWLIST))
        missing = sorted(set(ALLOWLIST) - set(changed))
        raise RuntimeError(f"changed-path allowlist mismatch; unexpected={unexpected}; missing={missing}")
    payload = run(repo, "diff", "--binary", "--full-index", base, target, "--", *ALLOWLIST)
    upgrade_changed = sorted(run(repo, "diff", "--name-only", "-z", overlay_base, target)
                             .decode().split("\0"))
    upgrade_changed = [item for item in upgrade_changed if item]
    if sorted(set(upgrade_changed) - set(ALLOWLIST)):
        raise RuntimeError("upgrade delta contains paths outside the reviewed overlay allowlist")
    upgrade_payload = (run(repo, "diff", "--binary", "--full-index", overlay_base, target,
                           "--", *upgrade_changed) if upgrade_changed else b"")
    hashes = {}
    supported_preimages = {}
    upgrade_paths = {}
    for rel in ALLOWLIST:
        PurePosixPath(rel)
        before = file_at(repo, base, rel)
        after = file_at(repo, target, rel)
        earlier = file_at(repo, overlay_base, rel)
        hashes[rel] = {"before_sha256": hashlib.sha256(before).hexdigest() if before is not None else None,
                       "after_sha256": hashlib.sha256(after).hexdigest() if after is not None else None}
        prior_digest = hashlib.sha256(earlier).hexdigest() if earlier is not None else None
        supported_preimages[rel] = {"sha256": prior_digest}
        if rel in upgrade_changed:
            upgrade_paths[rel] = {"before_sha256": prior_digest,
                                  "after_sha256": hashes[rel]["after_sha256"]}
    history = run(repo, "rev-list", "--reverse", f"{base}..{target}").decode().splitlines()
    commit_rows = []
    for full in history:
        short = full[:10]
        commit_rows.append({"short": short, "full": full,
                            "subject": run(repo, "show", "-s", "--format=%s", full).decode().strip()})
    if [row["short"] for row in commit_rows[:len(REQUIRED_COMMITS)]] != REQUIRED_COMMITS:
        raise RuntimeError("target history does not begin with the seven pinned Fleet commits")
    host_tools = Path(__file__).resolve().parent
    sync_plugin_helpers(host_tools)
    support_files = {}
    support_inventory = REQUIRED_ASSETS
    for rel in support_inventory:
        asset = host_tools / rel
        if not asset.is_file() or asset.is_symlink():
            raise RuntimeError(f"required offline distribution asset is missing or symlinked: {rel}")
        support_files[rel] = hashlib.sha256(asset.read_bytes()).hexdigest()
    manifest = {"format": 1, "base_commit": BASE, "target_commit": target,
                "supported_overlay_commit": overlay_base,
                "commits": commit_rows, "changed_paths": ALLOWLIST, "paths": hashes,
                "supported_preimages": supported_preimages, "upgrade_paths": upgrade_paths,
                "upgrade_patch_sha256": hashlib.sha256(upgrade_payload).hexdigest(),
                "support_files": support_files,
                "patch_sha256": hashlib.sha256(payload).hexdigest(),
                "release_scope": "offline Fleet pairing source overlay; no runtime or home files"}
    release = Path(__file__).resolve().parent / "release"
    release.mkdir(parents=True, exist_ok=True)
    (release / "overlay.patch").write_bytes(payload)
    (release / "upgrade.patch").write_bytes(upgrade_payload)
    plugin_commit, plugin_bundle_sha = make_plugin_bundle(host_tools, release / "owner-control.bundle")
    manifest["plugin_commit"] = plugin_commit
    manifest["plugin_bundle_sha256"] = plugin_bundle_sha
    (release / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    bundle_inventory = sorted(set(support_inventory + ["release/manifest.json", "release/overlay.patch",
                                                        "release/upgrade.patch", "release/owner-control.bundle"]))
    sum_lines = []
    for rel in bundle_inventory:
        path = host_tools / rel
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"bundle inventory file is missing or symlinked: {rel}")
        sum_lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {rel}\n")
    sums = "".join(sum_lines).encode()
    (release / "SHA256SUMS").write_bytes(sums)
    outer_sha = hashlib.sha256(sums).hexdigest()
    (release / "OUTER_SHA256").write_text(outer_sha + "\n", encoding="ascii")
    print(f"Wrote {len(ALLOWLIST)} allowlisted paths from {BASE} through {target}")
    print(f"patch_sha256={manifest['patch_sha256']}")
    print(f"upgrade_patch_sha256={manifest['upgrade_patch_sha256']}")
    print(f"plugin_commit={plugin_commit}")
    print(f"plugin_bundle_sha256={plugin_bundle_sha}")
    print(f"manifest_sha256={hashlib.sha256((release / 'manifest.json').read_bytes()).hexdigest()}")
    print(f"outer_sha256={outer_sha}")
    print("Obtain both SHA256 pins independently before running installer.py.")


if __name__ == "__main__":
    main()
