#!/usr/bin/env python3
"""Prepare the normal App Lock preference on a dedicated QA simulator.

Run before Release live UI verification. This changes only the installed
Hermes Fleet app's persisted preference; Release keeps its real authentication
provider and does not honor a launch-environment bypass. Physical-device QA
must authenticate and change the same setting through Settings > Security.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], check=check, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="ID of an operator-owned, dedicated QA simulator")
    parser.add_argument("--disable-app-lock", required=True, action="store_true")
    args = parser.parse_args()
    bundle = "com.aiowa.hermesfleet"
    try:
        container = Path(run("get_app_container", args.simulator, bundle, "data").stdout.strip())
        run("terminate", args.simulator, bundle, check=False)
        directory = container / "Library" / "Preferences"
        directory.mkdir(parents=True, exist_ok=True)
        destination = directory / (bundle + ".plist")
        values = plistlib.loads(destination.read_bytes()) if destination.exists() else {}
        values["fleet.appLock.enabled"] = False
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as temporary:
            temporary.write(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
            temporary_path = temporary.name
        os.replace(temporary_path, destination)
        # Flush only this dedicated simulator's preferences daemon so the app
        # reads the new persisted setting on its next launch.
        run("spawn", args.simulator, "launchctl", "stop", "com.apple.cfprefsd.xpc.daemon")
    except (subprocess.CalledProcessError, OSError, plistlib.InvalidFileException):
        raise SystemExit("Could not prepare the dedicated simulator; ensure Hermes Fleet is installed and the simulator is booted.")
    print("Prepared the persisted App Lock preference for Release live UI verification.")


if __name__ == "__main__":
    main()
