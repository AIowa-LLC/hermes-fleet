#!/bin/bash
# Audit required-reason API call sites in the shipping app and local package
# sources. Tests, docs, comments, and build artifacts are intentionally out of
# scope. The manifest validator then requires the declarations to equal the
# categories actually found, so adding a declaration without a call site fails.
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/privacy_manifest_validate.sh

python3 - <<'PY'
from pathlib import Path
import plistlib
import re
import sys

roots = [Path("HermesFleetApp")]
roots.extend(sorted(Path("Packages").glob("*/Sources")))
patterns = {
    "NSPrivacyAccessedAPICategoryUserDefaults": re.compile(r"\bUserDefaults\b"),
    "NSPrivacyAccessedAPICategoryFileTimestamp": re.compile(
        r"\b(?:creationDate|modificationDate|fileModificationDate|contentModificationDateKey|creationDateKey)\b"
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": re.compile(
        r"\b(?:systemUptime)\b|\bmach_absolute_time\s*\("
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": re.compile(
        r"\b(?:volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|systemFreeSize|systemSize|statfs|statvfs|fstatfs|fstatvfs)\b"
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": re.compile(r"\bactiveInputModes\b"),
}

comment = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
found = {category: [] for category in patterns}
for root in roots:
    for path in sorted(root.rglob("*.swift")):
        text = comment.sub("", path.read_text())
        for category, pattern in patterns.items():
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                found[category].append(f"{path}:{line}")

manifest_path = Path("HermesFleetApp/PrivacyInfo.xcprivacy")
with manifest_path.open("rb") as stream:
    manifest = plistlib.load(stream)
declared = {}
for entry in manifest["NSPrivacyAccessedAPITypes"]:
    declared[entry["NSPrivacyAccessedAPIType"]] = set(entry["NSPrivacyAccessedAPITypeReasons"])

detected = {category for category, hits in found.items() if hits}
if detected != set(declared):
    print("Required-reason audit FAILED: detected and declared categories differ")
    print(f"  detected: {sorted(detected)}")
    print(f"  declared: {sorted(declared)}")
    sys.exit(1)

for category, hits in found.items():
    if hits:
        print(f"  {category}: {len(hits)} production call-site/type hits")
        for hit in hits:
            print(f"    {hit}")
    else:
        print(f"  {category}: no production hits; no declaration")
print("Required-reason API audit: PASS")
PY
