#!/usr/bin/env python3
"""Cross-language resume check: Python desk runs to a midpoint and writes its state JSON, the Zig CLI
resumes from that file to the end, and the result must equal the Python run that never stopped."""
import json, os, subprocess, sys, math
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_parity as G  # noqa: E402

fx = {s["name"]: s for s in json.load(open(os.path.join(HERE, "../testdata/parity.json")))["scenarios"]}
BIN = os.path.join(HERE, "../zig-out/bin/arcis-dgb")
BARS = os.path.join(HERE, "../testdata/bars.json")

def flat(d, p=""):
    for k, v in d.items():
        if isinstance(v, dict): yield from flat(v, p + k + ".")
        else: yield p + k, v

ok = True
for name in ("S1_oos_cheapest", "S5_oos_cheapest_nohalt"):
    sc = fx[name]
    mid = sc["start_ms"] + (sc["end_ms"] - sc["start_ms"]) // 2
    mid -= mid % (2 * G.H)
    st = G.run(name + "_mid", sc["ledger"], sc["siphon_mode"], sc["halt"], sc["start_ms"], mid)["final"]
    json.dump(st, open("/tmp/resume_mid.json", "w"), indent=1)
    subprocess.run([BIN, "replay", BARS, "--ledger", sc["ledger"], "--state-in", "/tmp/resume_mid.json", "--start", str(mid + 2 * G.H),
                    "--end", str(sc["end_ms"]), "--mode", sc["siphon_mode"], "--halt", str(sc["halt"]), "--state-out", "/tmp/resume_zig.json", "--quiet"],
                   check=True, stdout=subprocess.DEVNULL)
    z = dict(flat(json.load(open("/tmp/resume_zig.json")))); p = dict(flat(sc["final"]))
    bad = [k for k in p if k not in ("source",) and not (p[k] == z.get(k) or (isinstance(p[k], float) and math.isclose(p[k], z[k], rel_tol=1e-12, abs_tol=0)))]
    print(f"{name}: resume at {mid}: {'IDENTICAL' if not bad else 'DIFF ' + str(bad)}")
    ok &= not bad
sys.exit(0 if ok else 1)
