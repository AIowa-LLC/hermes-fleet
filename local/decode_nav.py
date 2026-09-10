import plistlib, base64, json, sys
p = "<sim-container-redacted>/Library/Preferences/com.aiowa.hermesfleet.plist"
d = plistlib.load(open(p, "rb"))
raw = d.get("fleet.navigation.v1")
print("raw type:", type(raw).__name__)
data = raw if isinstance(raw, (bytes, bytearray)) else base64.b64decode(raw)
obj = json.loads(data)
print(json.dumps(obj, indent=1)[:1500])
# Highlight where the app would land
def summarize(o, depth=0):
    if isinstance(o, dict):
        for k in ("tab", "selection", "version"):
            if k in o:
                print("  " * depth + f"{k}: {o[k]}")
        for v in o.values():
            summarize(v, depth + 1)
    elif isinstance(o, list):
        for v in o:
            summarize(v, depth + 1)
print("--- summary ---")
summarize(obj)
