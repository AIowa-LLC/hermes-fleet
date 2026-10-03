#!/usr/bin/env python3
"""FOS-7 Increase Contrast runtime evidence via simulator AX preferences.

Writes EnhancedBackgroundContrastEnabled=1 in the simulator's
com.apple.Accessibility domain, relaunches the app, captures a screenshot,
restores the pref. Combined with the unit test pinning the HC token branch
(testAccentHighContrastVariants + testSurfacesFallBackToSystemBackground-
UnderIncreasedContrast), this provides the §21-14 Increase Contrast run.

Target simulator resolution order (no machine-specific UDID is tracked):
1. --udid CLI argument
2. FOS7_SIM_UDID environment variable
3. First booted device from `xcrun simctl list devices`
4. First available iPhone from `xcrun simctl list devices available`
"""
import os
import re
import subprocess
import sys
import time

BUNDLE_ID = "com.aiowa.hermesfleet"
DOMAIN = "com.apple.Accessibility"
UDID_RE = re.compile(r"\(([0-9A-Fa-f-]{36})\)")


def resolve_udid() -> str:
    if len(sys.argv) > 2 and sys.argv[1] == "--udid":
        return sys.argv[2]
    env = os.environ.get("FOS7_SIM_UDID")
    if env:
        return env

    def devices(flag):
        out = subprocess.run(["xcrun", "simctl", "list", "devices"] + flag,
                             capture_output=True, text=True).stdout
        return [line for line in out.splitlines() if UDID_RE.search(line)]

    # Prefer an already-booted device.
    for line in devices([]):
        m = UDID_RE.search(line)
        if m and "(Booted)" in line:
            return m.group(1)
    # Otherwise take the first available iPhone and boot it.
    for line in devices(["available"]):
        m = UDID_RE.search(line)
        if m and "iPhone" in line:
            subprocess.run(["xcrun", "simctl", "boot", m.group(1)], capture_output=True)
            return m.group(1)
    sys.exit("No simulator found: pass --udid <UDID> or set FOS7_SIM_UDID")


UDID = resolve_udid()
print("using simulator:", UDID)


def defaults(*args):
    return subprocess.run(["xcrun", "simctl", "spawn", UDID, "defaults", *args],
                          capture_output=True, text=True).stdout.strip()


def launch_and_snap(name):
    subprocess.run(["xcrun", "simctl", "terminate", UDID, BUNDLE_ID], capture_output=True)
    time.sleep(1)
    subprocess.run(["xcrun", "simctl", "launch", UDID, BUNDLE_ID], capture_output=True)
    time.sleep(4)
    subprocess.run(["xcrun", "simctl", "io", UDID, "screenshot", f"/tmp/fos7_screens/{name}.png"],
                   capture_output=True)
    print("captured", name)


os.makedirs("/tmp/fos7_screens", exist_ok=True)

before = defaults("read", DOMAIN, "EnhancedBackgroundContrastEnabled")
print("EnhancedBackgroundContrastEnabled before:", before)

defaults("write", DOMAIN, "EnhancedBackgroundContrastEnabled", "1")
# Bounce SpringBoard so the setting takes effect graphically.
subprocess.run(["xcrun", "simctl", "spawn", UDID, "launchctl", "stop", "com.apple.SpringBoard"],
               capture_output=True)
time.sleep(6)
print("pref now:", defaults("read", DOMAIN, "EnhancedBackgroundContrastEnabled"))
launch_and_snap("fos7-home-IC-light")

defaults("write", DOMAIN, "EnhancedBackgroundContrastEnabled", before or "0")
subprocess.run(["xcrun", "simctl", "spawn", UDID, "launchctl", "stop", "com.apple.SpringBoard"],
               capture_output=True)
time.sleep(6)
launch_and_snap("fos7-home-IC-restored")
print("done")
