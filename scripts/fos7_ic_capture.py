#!/usr/bin/env python3
"""FOS-7 Increase Contrast runtime evidence via simulator AX preferences.

Writes EnhancedBackgroundContrastEnabled=1 in the simulator's
com.apple.Accessibility domain, relaunches the app, captures a screenshot,
restores the pref. Combined with the unit test pinning the HC token branch
(testAccentHighContrastVariants + testSurfacesFallBackToSystemBackground-
UnderIncreasedContrast), this provides the §21-14 Increase Contrast run.
"""
import subprocess, time

UDID = "393F1335-2DB1-48BD-96B9-A38B1EA488A4"
DOMAIN = "com.apple.Accessibility"

def defaults(*args):
    return subprocess.run(["xcrun", "simctl", "spawn", UDID, "defaults", *args],
                          capture_output=True, text=True).stdout.strip()

def launch_and_snap(name):
    subprocess.run(["xcrun " + f"simctl terminate {UDID} com.aiowa.hermesfleet"], shell=True, capture_output=True)
    time.sleep(1)
    subprocess.run(f"xcrun simctl launch {UDID} com.aiowa.hermesfleet", shell=True, capture_output=True)
    time.sleep(4)
    subprocess.run(f"xcrun simctl io {UDID} screenshot /tmp/fos7_screens/{name}.png", shell=True)
    print("captured", name)

before = defaults("read", DOMAIN, "EnhancedBackgroundContrastEnabled")
print("EnhancedBackgroundContrastEnabled before:", before)

defaults("write", DOMAIN, "EnhancedBackgroundContrastEnabled", "1")
# Bounce SpringBoard so the setting takes effect graphically.
subprocess.run(f"xcrun simctl spawn {UDID} launchctl stop com.apple.SpringBoard", shell=True, capture_output=True)
time.sleep(6)
print("pref now:", defaults("read", DOMAIN, "EnhancedBackgroundContrastEnabled"))
launch_and_snap("fos7-home-IC-light")

defaults("write", DOMAIN, "EnhancedBackgroundContrastEnabled", before or "0")
subprocess.run(f"xcrun simctl spawn {UDID} launchctl stop com.apple.SpringBoard", shell=True, capture_output=True)
time.sleep(6)
launch_and_snap("fos7-home-IC-restored")
print("done")
