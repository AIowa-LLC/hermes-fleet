import json, subprocess, sys

results_dir = "/tmp/hgoal/i11-repro/build/i11-runs"
runs = ["run1","run2","run3","run4","run5","run6","run7","run8",
        "S3CleartextWarningUITests","HermesFleetHappyPathUITests"]

for name in runs:
    path = f"{results_dir}/{name}.xcresult"
    try:
        out = subprocess.run(
            ["xcrun","xcresulttool","get","test-results","tests","--path",path],
            capture_output=True, text=True, timeout=120).stdout
        d = json.loads(out)
    except Exception as e:
        print(f"{name}: ERROR {e}")
        continue
    lines = []
    def walk(n, depth=0):
        node = n.get("nodeType","")
        nm = n.get("name","?")
        res = n.get("result","")
        dur = n.get("duration","")
        if node in ("Test Case","Test Suite"):
            lines.append(f"{'  '*depth}{node}: {nm} [{res}] {dur}s")
        for c in n.get("children",[]):
            walk(c, depth+1)
    for t in d.get("testNodes",[]):
        walk(t)
    print(f"=== {name} ===")
    print("\n".join(lines) if lines else "(no test nodes parsed)")
