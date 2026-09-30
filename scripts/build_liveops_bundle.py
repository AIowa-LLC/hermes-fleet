#!/usr/bin/env python3
"""Build a deterministic, versioned companion setup ZIP from an exact commit."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

VERSION = "0.3.0"
RUNTIME_FILES = ("plugin.yaml", "__init__.py", "push_store.py", "push_payload.py",
                 "push_sender.py", "dashboard/manifest.json", "dashboard/plugin_api.py",
                 "dashboard/index.js")
SETUP_FILES = ("setup.py", "Setup.command", "README.txt")


def build(source, output, read):
    entries = {}
    hashes = {}
    for name in RUNTIME_FILES:
        data = read("integrations/hermes-liveops/" + name)
        entries["plugin/" + name] = data
        hashes[name] = hashlib.sha256(data).hexdigest()
    if json.loads(entries["plugin/dashboard/manifest.json"])["version"] != VERSION:
        raise ValueError("Plugin version must match setup bundle version")
    if f"version: {VERSION}\n".encode() not in entries["plugin/plugin.yaml"]:
        raise ValueError("Plugin manifest version must match setup bundle version")
    for name in SETUP_FILES:
        entries[name] = read("integrations/hermes-liveops/setup/" + name)
    if f'VERSION = "{VERSION}"'.encode() not in entries["setup.py"]:
        raise ValueError("Installer version must match bundle version")
    guide = read("Packages/FleetUI/Sources/FleetUI/LiveOpsSetupView.swift")
    if f"fleet-liveops-v{VERSION}".encode() not in guide:
        raise ValueError("App setup link must match released bundle version")
    entries["release.json"] = (json.dumps({"version": VERSION, "source_commit": source,
        "files": hashes}, sort_keys=True, indent=2) + "\n").encode()
    output.mkdir(parents=True, exist_ok=True)
    prefix = "Fleet-Live-Reporting-" + VERSION
    archive = output / (prefix + ".zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(entries.items()):
            item = zipfile.ZipInfo(prefix + "/" + name, date_time=(2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = (0o100755 if name == "Setup.command" else 0o100644) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(item, data)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(checksum + "  " + archive.name + "\n")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True, help="Committed source revision")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    source = subprocess.check_output(["git", "rev-parse", args.sha + "^{commit}"], cwd=repo, text=True).strip()
    def read(path):
        return subprocess.check_output(["git", "show", source + ":" + path], cwd=repo)
    archive = build(source, args.output, read)
    print(archive.name + " built from " + source)


if __name__ == "__main__":
    main()
