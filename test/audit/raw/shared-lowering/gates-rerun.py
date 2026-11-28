#!/usr/bin/env python3
"""The shared-lowering gates, short form agreed with the maintainer: three
pairs per ordering, a null set (base against base) first, fresh emulator per
run, a run counts only if the 5-minute load average is below 8 at both ends.

    gates.py ROOT OUT
"""
import json, re, statistics, subprocess, sys, time

root, out = sys.argv[1:3]
PAIRS, LIMIT, ATTEMPTS = 3, 8.0, 6
ERL = "/opt/homebrew/bin/erl"
UKB = root + "/ukb"
BASE, CHANGE = root + "/ew-base", root + "/ew-change"

def load5():
    v = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout
    return float(v.strip("{} \n").split()[1])

def boot(ew, variant):
    return ("cd %s && ERL_CRASH_DUMP_SECONDS=0 %s -noshell -pa _build/default/lib/*/ebin "
            "-pa %s -run ukg main x %s %s" % (UKB, ERL, root, ew, variant))

def path(ew, arm):
    return ("cd %s && ERL_CRASH_DUMP_SECONDS=0 %s -noshell -pa _build/default/lib/*/ebin "
            "-pa %s/pathbench -run pathbench main %s | sed 's/^/RESULT ns=/; s/\\t/ v=/'" % (ew, ERL, root, arm))

def shared(ew, arm):
    return ("cd %s && ERL_CRASH_DUMP_SECONDS=0 %s -noshell -pa _build/default/lib/*/ebin "
            "-pa %s/sharedbench -run sharedbench main %s" % (ew, ERL, root, arm))

def run(cmd):
    for attempt in range(ATTEMPTS):
        while load5() >= LIMIT:
            time.sleep(15)
        l0 = load5()
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        l1 = load5()
        line = [l for l in r.stdout.splitlines() if l.startswith("RESULT")]
        if r.returncode != 0 or not line:
            raise SystemExit("run failed: %s\n%s%s" % (cmd, r.stdout[-2000:], r.stderr[-2000:]))
        rec = dict(re.findall(r"(\w+)=(\S+)", line[-1]))
        rec["attempts"] = attempt + 1
        if l0 < LIMIT and l1 < LIMIT:
            return rec
    raise SystemExit("gave up under the load rule: " + cmd)

def pairs(name, x_cmd, y_cmd, metric):
    rec = {"ab": [], "ba": []}
    for _ in range(PAIRS):
        x = run(x_cmd); y = run(y_cmd)
        rec["ab"].append({"x": x, "y": y, "ratio": float(y[metric]) / float(x[metric])})
        y = run(y_cmd); x = run(x_cmd)
        rec["ba"].append({"x": x, "y": y, "ratio": float(y[metric]) / float(x[metric])})
    med = {k: statistics.median([p["ratio"] for p in v]) for k, v in rec.items()}
    print("%-28s median %s ratio ab %.3f ba %.3f" % (name, metric, med["ab"], med["ba"]), flush=True)
    return {"pairs": rec, "median": med}

results = {}
def gate(name, base_cmd, change_cmd, metric):
    results[name] = {"null": pairs(name + " null", base_cmd, base_cmd, metric),
                     "change": pairs(name, base_cmd, change_cmd, metric)}
    with open(out, "w") as f:
        json.dump(results, f, indent=1)

gate("sharedbench p1 rerun", shared(BASE, "p1"), shared(CHANGE, "p1"), "steady_us")
gate("pathbench inst_small", path(BASE, "inst_small"), path(CHANGE, "inst_small"), "v")
print("done", flush=True)
