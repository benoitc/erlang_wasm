#!/usr/bin/env python3
"""Paired runs for the cross-instance write-back change, by the rule in
docs/contributing/measuring.md: fresh emulator per run, both orderings, six
pairs per ordering, a null set (base against base) first, a run counts only
if the 5-minute load average was below 8 when it started and when it ended.

    pairs.py BASE_DIR CHANGE_DIR BENCH_DIR OUT_FILE arm [arm...]
"""
import json, statistics, subprocess, sys, time

base, change, bench, out = sys.argv[1:5]
arms = sys.argv[5:]
LIMIT = 8.0
PAIRS = 6
ATTEMPTS = 6

def load5():
    v = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout
    return float(v.strip("{} \n").split()[1])

def wait_quiet():
    while load5() >= LIMIT:
        time.sleep(15)

def one(side, arm):
    for attempt in range(ATTEMPTS):
        wait_quiet()
        l0 = load5()
        cmd = ("ERL_CRASH_DUMP_SECONDS=0 erl -noshell -pa %s/_build/default/lib/*/ebin -pa %s "
               "-run pathbench main %s" % (side, bench, arm))
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=side)
        l1 = load5()
        lines = [l for l in r.stdout.splitlines() if "\t" in l]
        if r.returncode != 0 or not lines:
            raise SystemExit("run failed: %s %s\n%s%s" % (side, arm, r.stdout, r.stderr))
        ns = float(lines[-1].split("\t")[1])
        if l0 < LIMIT and l1 < LIMIT:
            return {"ns": ns, "load": [l0, l1], "attempts": attempt + 1}
    raise SystemExit("gave up under the load rule: %s %s" % (side, arm))

def pairs(first, second, label):
    """PAIRS pairs per ordering; each ratio is second-side over first-side
    numbers in the X/Y sense: ratio = Y / X, where X is `first`'s side."""
    rec = {"ab": [], "ba": []}
    for _ in range(PAIRS):
        x = one(first, arm); y = one(second, arm)
        rec["ab"].append({"x": x, "y": y, "ratio": y["ns"] / x["ns"]})
        y = one(second, arm); x = one(first, arm)
        rec["ba"].append({"x": x, "y": y, "ratio": y["ns"] / x["ns"]})
    med = {k: statistics.median([p["ratio"] for p in v]) for k, v in rec.items()}
    print("%-24s %-6s median ratio ab %.3f ba %.3f" % (arm, label, med["ab"], med["ba"]), flush=True)
    return {"pairs": rec, "median": med}

results = {}
for arm in arms:
    results[arm] = {"null": pairs(base, base, "null"),
                    "change": pairs(base, change, "change")}
    with open(out, "w") as f:
        json.dump(results, f, indent=1)
print("done", flush=True)
