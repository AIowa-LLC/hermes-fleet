#!/usr/bin/env python3
"""Read-only Fleet host checks. Static compatibility never grants authority to issue."""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import ssl
import stat
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit


REQUIRED = (
    "hermes_cli/fleet_pairing_cli.py",
    "hermes_cli/dashboard_auth/fleet_devices.py",
    "hermes_cli/dashboard_auth/fleet_device_provider.py",
    "hermes_cli/dashboard_auth/fleet_pairing_routes.py",
    "hermes_cli/dashboard_auth/public_paths.py",
    "hermes_cli/dashboard_auth/body_limit.py",
    "hermes_cli/dashboard_auth/registry.py",
    "hermes_cli/dashboard_auth/request_utils.py",
    "hermes_cli/dashboard_auth/routes.py",
    "hermes_cli/web_server.py",
    "gateway/session_context_security.py",
    "gateway/session.py",
    "gateway/run_turn.py",
    "gateway/run_agent_cache.py",
    "gateway/config_loader.py",
    "gateway/slash_access.py",
    "hermes_cli/config_defaults.py",
)
OBSERVED_GATES = ("phone_https_observed", "private_display_observed", "service_runtime_observed")


def digest_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalise_origin(raw: str) -> str:
    """Same HTTPS DNS-origin boundary as Fleet; private DNS resolution is allowed."""
    if not raw.isascii() or any(ord(c) <= 32 for c in raw):
        raise ValueError("invalid HTTPS DNS origin")
    parts = urlsplit(raw)
    host = parts.hostname or ""
    if (parts.scheme != "https" or parts.username is not None or parts.password is not None
            or parts.path not in ("", "/") or parts.query or parts.fragment
            or len(host.split(".")) < 2 or len(host) > 253):
        raise ValueError("invalid HTTPS DNS origin")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("IP literals are unsupported")
    if any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
           for label in host.split(".")):
        raise ValueError("invalid HTTPS DNS origin")
    port = parts.port
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("invalid HTTPS port")
    return f"https://{host.lower()}" + (f":{port}" if port and port != 443 else "")


def load_manifest(path: Path, trusted_digest: str) -> dict:
    raw = path.read_bytes()
    if not re.fullmatch(r"[a-f0-9]{64}", trusted_digest):
        raise ValueError("independently trusted manifest SHA256 required")
    if hashlib.sha256(raw).hexdigest() != trusted_digest:
        raise ValueError("release integrity failure")
    manifest = json.loads(raw)
    if manifest.get("format") != 1 or not all(p in manifest.get("paths", {}) for p in REQUIRED):
        raise ValueError("unsupported Fleet release contract")
    return manifest


def integrity(root: Path, manifest: dict) -> dict:
    """Do not import Hermes: its stores/loaders can create persistent state."""
    root = root.resolve(strict=True)
    missing, changed = [], []
    for relative in REQUIRED:
        path = root / relative
        if not path.is_file():
            missing.append(relative)
        elif path.is_symlink() or not path.resolve().is_relative_to(root):
            changed.append(relative)
        elif digest_file(path) != manifest["paths"][relative]["after_sha256"]:
            changed.append(relative)
    return {"verified": not missing and not changed, "missing": missing, "changed": changed}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def probe_https(origin: str) -> bool:
    """No credentials, cookies, redirects, disabled TLS or state-changing endpoint."""
    request = urllib.request.Request(origin + "/api/auth/providers", headers={"Accept": "application/json"})
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    try:
        with opener.open(request, timeout=5) as response:
            if response.status != 200 or response.geturl() != request.full_url:
                return False
            raw = response.read(16385)
            if len(raw) > 16384:
                return False
            data = json.loads(raw)
            providers = data.get("providers")
            return isinstance(providers, list) and any(
                isinstance(p, dict) and p.get("name") and p.get("name") != "fleet-device"
                for p in providers)
    except (OSError, ValueError, urllib.error.URLError):
        # Never include remote response bodies/errors in an authority report.
        return False


def approval_binding(home: Path, runtime: Path, origin: str, trusted_digest: str) -> dict:
    config = home / "config.yaml"
    return {"home": str(home.resolve()), "runtime_dir": str(runtime.resolve()),
            "origin": origin, "manifest_sha256": trusted_digest,
            "config_sha256": digest_file(config) if config.is_file() else None}


def effective_origin(home: Path, runtime: Path) -> str | None:
    """Use the selected Hermes runtime's read-only loader and actual profile scope."""
    try:
        from hermes_constants import get_hermes_home
        from hermes_cli import config
        if (Path(get_hermes_home()).resolve() != home.resolve()
                or Path(config.__file__).resolve() != (runtime / "hermes_cli/config.py").resolve()):
            return None
        cfg = config.load_config_readonly()
        raw = os.environ.get("HERMES_DASHBOARD_PUBLIC_URL", "").strip()
        if not raw:
            raw = cfg.get("dashboard", {}).get("public_url", "")
        return normalise_origin(raw)
    except (ImportError, OSError, ValueError, TypeError, AttributeError):
        return None


def read_approval(path: Path, binding: dict, *, now: float | None = None) -> dict:
    """Owner observations are explicit, short-lived and scoped; no approval is inferred."""
    now = time.time() if now is None else now
    try:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.getuid() or info.st_size > 8192):
            return {}
        record = json.loads(path.read_bytes())
        created, expires = record["created_at"], record["expires_at"]
        if (not isinstance(created, (int, float)) or not isinstance(expires, (int, float))
                or isinstance(created, bool) or isinstance(expires, bool)
                or not created <= now < expires or not 0 < expires - created <= 600
                or record.get("binding") != binding):
            return {}
        return {gate: record.get(gate) is True for gate in OBSERVED_GATES}
    except (OSError, ValueError, TypeError, KeyError):
        return {}


def inspect_readiness(home: Path, runtime_dir: Path, *, source: Path, manifest: Path,
                      trusted_digest: str, origin: str, approval: Path | None = None,
                      network_probe=probe_https, origin_reader=effective_origin) -> dict:
    release = load_manifest(manifest, trusted_digest)
    code = integrity(source, release)
    runtime = integrity(runtime_dir, release)
    home = home.resolve(strict=True)
    runtime_dir = runtime_dir.resolve(strict=True)
    origin = normalise_origin(origin)
    configured_origin = origin_reader(home, runtime_dir)
    home_verified = configured_origin == origin and (home / "config.yaml").is_file()
    binding = approval_binding(home, runtime_dir, origin, trusted_digest)
    observations = read_approval(approval, binding) if approval else {}
    # This only proves the host's trusted route, never phone membership/trust or loaded server code.
    tls = network_probe(origin) if code["verified"] and runtime["verified"] and home_verified else False
    report = {
        "issuer_ready": code["verified"], "home_matches": home_verified,
        "runtime_matches": runtime["verified"], "https_origin_verified": tls,
        "system_tls_trusted": tls, "phone_reachability_verified": observations.get("phone_https_observed", False),
        "local_display_ready": observations.get("private_display_observed", False),
        "service_runtime_verified": observations.get("service_runtime_observed", False),
        "origin": origin, "release_id": trusted_digest, "home": str(home),
        "runtime_dir": str(runtime_dir), "source_integrity": code, "runtime_integrity": runtime,
        "blockers": [], "can_issue": False,
    }
    for key in ("issuer_ready", "home_matches", "runtime_matches", "https_origin_verified",
                "phone_reachability_verified", "local_display_ready", "service_runtime_verified"):
        if not report[key]:
            report["blockers"].append(key)
    report["blockers"].append("actual_private_numeric_owner_event_and_explicit_issue_request")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--runtime-source", required=True, type=Path)
    parser.add_argument("--hermes-home", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--trusted-manifest-sha256", required=True)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--approval", type=Path)
    parser.add_argument("--probe-https", action="store_true", help="optional read-only trusted HTTPS provider probe")
    args = parser.parse_args()
    try:
        report = inspect_readiness(args.hermes_home, args.runtime_source, source=args.source,
                                  manifest=args.manifest, trusted_digest=args.trusted_manifest_sha256,
                                  origin=args.origin, approval=args.approval,
                                  network_probe=probe_https if args.probe_https else lambda _: False)
    except (OSError, ValueError, TypeError, KeyError):
        print(json.dumps({"can_issue": False, "blockers": ["invalid_or_untrusted_release_or_selection"]}))
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["issuer_ready"] and report["runtime_matches"] and report["home_matches"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
