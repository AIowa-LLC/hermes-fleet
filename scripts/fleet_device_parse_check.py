#!/usr/bin/env python3
"""Negative tests for fleet_device.sh's JSON parser: zero/multi/edge devices.

Feeds fabricated device-list JSON through the exact python filter used by
scripts/fleet_device.sh (kept in sync manually — the shell script embeds
this parser) and checks the eligibility outcomes.
"""
import json
import os
import subprocess
import sys
import tempfile

# Availability derivation mirrors the observed Xcode 26.6 CoreDevice JSON
# (see scripts/fleet_device.sh header): a device is currently available when
# connectionProperties carries a transportType ("localNetwork" observed live;
# "wired" equally valid) AND tunnelState != "unavailable". Unavailable
# devices empirically have tunnelState == "unavailable" and NO transportType.
PARSER = '''import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)
devs = data.get("result", {}).get("devices", [])
eligible = []
for d in devs:
    hp = d.get("hardwareProperties", {})
    cp = d.get("connectionProperties", {})
    transport = cp.get("transportType")
    tunnel = cp.get("tunnelState")
    if (hp.get("deviceType") == "iPhone"
            and hp.get("platform") == "iOS"
            and cp.get("pairingState") == "paired"
            and tunnel is not None and tunnel != "unavailable"
            and transport):
        eligible.append(d.get("identifier", ""))
if len(eligible) == 1:
    print(eligible[0])
elif len(eligible) == 0:
    print("NONE")
else:
    print("MULTIPLE")
'''


def run_with_json(devices):
    data = {"result": {"devices": devices}}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(data, f)
        path = f.name
    try:
        r = subprocess.run(["python3", "-", path], input=PARSER, text=True,
                           capture_output=True, check=True)
        return r.stdout.strip()
    finally:
        os.unlink(path)


# Fixtures mirror the observed Xcode 26.6 devicectl JSON availability
# encoding: available = transportType present (localNetwork/wired) +
# tunnelState != "unavailable"; unavailable = tunnelState "unavailable",
# no transportType. Both transport spellings are valid dev connections.
AVAILABLE_LAN = {"transportType": "localNetwork", "tunnelState": "disconnected"}
AVAILABLE_WIRED = {"transportType": "wired", "tunnelState": "disconnected"}
UNAVAILABLE = {"tunnelState": "unavailable"}   # transportType absent

iphone = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
          "connectionProperties": {"pairingState": "paired", **AVAILABLE_LAN}, "identifier": "ID-A"}
iphone_wired = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
                "connectionProperties": {"pairingState": "paired", **AVAILABLE_WIRED}, "identifier": "ID-B"}
iphone2 = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
           "connectionProperties": {"pairingState": "paired", **AVAILABLE_LAN}, "identifier": "ID-B2"}
unavailable_paired = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
                      "connectionProperties": {"pairingState": "paired", **UNAVAILABLE}, "identifier": "ID-U"}
unpaired = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
            "connectionProperties": {"pairingState": "unpaired", **AVAILABLE_LAN}, "identifier": "ID-C"}
watch = {"hardwareProperties": {"deviceType": "appleWatch", "platform": "watchOS"},
         "connectionProperties": {"pairingState": "paired", **AVAILABLE_LAN}, "identifier": "ID-W"}
# a device whose NAME contains spaces — the exact case the old
# awk '{print $1}' columnar parse got wrong
spacey_name = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
               "connectionProperties": {"pairingState": "paired", **AVAILABLE_LAN},
               "identifier": "ID-SPACES",
               "name": "Someone's Extra Phone"}

cases = [
    ("paired + AVAILABLE iPhone -> selected", [iphone, watch], "ID-A"),
    ("paired + WIRED-available iPhone -> also eligible", [iphone_wired, watch], "ID-B"),
    ("paired + UNAVAILABLE iPhone only -> NONE (not selectable)", [unavailable_paired, watch], "NONE"),
    ("available iPhone + unavailable paired iPhone -> select the available one, NOT MULTIPLE",
     [iphone, unavailable_paired], "ID-A"),
    ("two AVAILABLE paired iPhones -> MULTIPLE", [iphone, iphone2], "MULTIPLE"),
    ("unpaired iPhone (available transport) -> NONE", [unpaired, watch], "NONE"),
    ("zero iPhones (watch only) -> NONE", [watch], "NONE"),
    ("one iPhone + paired watch -> auto-select the iPhone", [iphone, watch], "ID-A"),
    ("spacey-named available iPhone pairs still resolve by identifier", [iphone, spacey_name], "MULTIPLE"),
]

failed = 0
for label, devices, want in cases:
    got = run_with_json(devices)
    status = "PASS" if got == want else "FAIL"
    if got != want:
        failed += 1
    print(f"{status}  {label}: got {got!r} want {want!r}")

sys.exit(1 if failed else 0)
