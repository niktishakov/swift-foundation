import sys, collections, datetime
from zoneinfo import ZoneInfo

def load(path):
    rows = {}
    for line in open(path):
        idx, zone, start, comps, d, pol, res, m = line.rstrip("\n").split("\t")
        rows[(idx, d, pol)] = (zone, int(start), comps, res, m)
    return rows

def valid(start, d, res, m):
    if res == "nil" or m != "1":
        return False
    r = int(res)
    return r < start if d == "back" else r > start

def fmt(zone, t):
    if t == "nil":
        return "nil"
    return datetime.datetime.fromtimestamp(int(t), ZoneInfo(zone)).strftime("%Y-%m-%d %H:%M:%S")

base, fix = load(sys.argv[1]), load(sys.argv[2])
assert base.keys() == fix.keys()
# Cases skipped in either run (known slow paths) are left out of the comparison.
for k in [k for k in base if base[k][3] == 'skipped' or fix[k][3] == 'skipped']:
    del base[k]; del fix[k]
kinds = collections.Counter()
by_template = collections.defaultdict(collections.Counter)
samples = collections.defaultdict(list)
for key in sorted(base, key=lambda k: (int(k[0]), k[1], k[2])):
    zone, start, comps, rb, mb = base[key]
    _, _, _, rf, mf = fix[key]
    if rb == rf:
        continue
    _, d, pol = key
    vb, vf = valid(start, d, rb, mb), valid(start, d, rf, mf)
    if vb and not vf:
        kind = "REGRESSION (main ok, branch wrong)"
    elif vf and not vb:
        kind = "fixed (main wrong, branch ok)"
    elif vb and vf:
        closer_fix = abs(int(rf) - start) < abs(int(rb) - start)
        kind = "both valid, branch closer" if closer_fix else "both valid, main closer"
    else:
        kind = "both wrong"
    template = ",".join(c.split("=")[0] for c in comps.split(","))
    kinds[kind] += 1
    by_template[kind][(template, d, pol)] += 1
    if len(samples[(kind, template, d)]) < 3:
        samples[(kind, template, d)].append(f"  {zone} start={fmt(zone.replace("iso:",""), start)} {comps} {pol}: main={fmt(zone.replace("iso:",""), rb)} branch={fmt(zone.replace("iso:",""), rf)}")

print("total cases:", len(base), "differ:", sum(kinds.values()))
for kind, n in kinds.most_common():
    print(f"\n== {kind}: {n}")
    for (template, d, pol), c in by_template[kind].most_common(12):
        print(f"  {c:5d}  {template:35s} {d:4s} {pol}")
for kind in ["REGRESSION (main ok, branch wrong)", "both valid, main closer", "both wrong"]:
    keys = [k for k in samples if k[0] == kind]
    if keys:
        print(f"\n## samples: {kind}")
        for k in keys[:15]:
            print(f"{k[1]} {k[2]}")
            print("\n".join(samples[k]))
