import plistlib, base64, json, sys
p = "<sim-container-redacted>/Library/Preferences/com.aiowa.hermesfleet.plist"
d = plistlib.load(open(p, "rb"))
print("keys:", list(d.keys()))
raw = d.get("fleet.navigation.v1")
if raw is None:
    print("NAV KEY ABSENT")
else:
    data = raw if isinstance(raw, (bytes, bytearray)) else base64.b64decode(raw)
    obj = json.loads(data)
    print("selection:", obj.get("selection"))
    print("paths:", json.dumps(obj.get("paths"))[:300])
