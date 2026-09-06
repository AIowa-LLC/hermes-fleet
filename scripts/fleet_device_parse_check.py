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
    if (hp.get("deviceType") == "iPhone"
            and hp.get("platform") == "iOS"
            and cp.get("pairingState") == "paired"):
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


iphone = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
          "connectionProperties": {"pairingState": "paired"}, "identifier": "ID-A"}
iphone2 = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
           "connectionProperties": {"pairingState": "paired"}, "identifier": "ID-B"}
unpaired = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
            "connectionProperties": {"pairingState": "unpaired"}, "identifier": "ID-C"}
watch = {"hardwareProperties": {"deviceType": "appleWatch", "platform": "watchOS"},
         "connectionProperties": {"pairingState": "paired"}, "identifier": "ID-W"}
# a device whose NAME contains spaces — the exact case the old
# awk '{print $1}' columnar parse got wrong
spacey_name = {"hardwareProperties": {"deviceType": "iPhone", "platform": "iOS"},
               "connectionProperties": {"pairingState": "paired"},
               "identifier": "ID-SPACES",
               "name": "Someone's Extra Phone"}

cases = [
    ("one iPhone + paired watch -> auto-select the iPhone", [iphone, watch], "ID-A"),
    ("two paired iPhones -> MULTIPLE", [iphone, iphone2], "MULTIPLE"),
    ("zero iPhones (watch only) -> NONE", [watch], "NONE"),
    ("unpaired iPhone only -> NONE (not eligible)", [unpaired, watch], "NONE"),
    ("spacey-named iPhone pairs still resolve by identifier", [iphone, spacey_name], "MULTIPLE"),
]

failed = 0
for label, devices, want in cases:
    got = run_with_json(devices)
    status = "PASS" if got == want else "FAIL"
    if got != want:
        failed += 1
    print(f"{status}  {label}: got {got!r} want {want!r}")

sys.exit(1 if failed else 0)
