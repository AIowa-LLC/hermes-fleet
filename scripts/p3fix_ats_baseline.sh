#!/bin/bash
# t_eb5455f2 FIX1 baseline: verify the current built app Info.plist has NO ATS
# entry (the evidence gap this task closes). Read-only.
set -u
cd <repo-root> || exit 1

echo "=== baseline ATS scan across built app bundles ==="
found=0
for plist in $(find build -name "Info.plist" -path "*HermesFleetApp.app*" 2>/dev/null); do
  ats=$(/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$plist" 2>/dev/null || true)
  if [ -n "$ats" ]; then
    echo "  ATS PRESENT in $plist: $ats"
    found=1
  fi
done
if [ "$found" -eq 0 ]; then
  echo "  RESULT: 0 built Info.plists carry NSAppTransportSecurity (gap confirmed)"
else
  echo "  RESULT: ATS found somewhere (unexpected before the fix)"
fi

echo
echo "=== count of built app bundles scanned ==="
find build -name "Info.plist" -path "*HermesFleetApp.app*" 2>/dev/null | wc -l
echo "=== Done ==="
