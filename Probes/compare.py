"""Compare two RecurrenceRule probe outputs: main.tsv branch.tsv. Groups differences by kind."""
import sys, collections, datetime
from zoneinfo import ZoneInfo


def load(path):
    rows = {}
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if parts[1] in ("CRASH", "TIMEOUT"):
            rows[int(parts[0])] = ("", "", parts[1], 0.0, parts[2] if len(parts) > 2 else "")
        else:
            idx, text, start, dates, ms = parts
            rows[int(idx)] = (text, start, dates, float(ms), "")
    return rows


def fmt(zone, t):
    return datetime.datetime.fromtimestamp(int(t), ZoneInfo(zone)).strftime("%Y-%m-%d %H:%M:%S %a")


main, branch = load(sys.argv[1]), load(sys.argv[2])
show = int(sys.argv[3]) if len(sys.argv) > 3 else 3
kinds = collections.Counter()
samples = collections.defaultdict(list)
for i in sorted(set(main) | set(branch)):
    m, b = main.get(i), branch.get(i)
    if m is None or b is None:
        kinds["missing"] += 1
        continue
    text = m[0] or b[0]
    if m[2] == b[2]:
        kinds["same crash" if m[2] == "CRASH" else "same"] += 1
        continue
    if m[2] in ("CRASH", "TIMEOUT"):
        kind = f"main {m[2].lower()}, branch ok"
    elif b[2] in ("CRASH", "TIMEOUT"):
        kind = f"branch {b[2].lower()}, main ok"
    elif m[2] == "none":
        kind = "main none, branch dates"
    elif b[2] == "none":
        kind = "main dates, branch none"
    else:
        md, bd = m[2].split(","), b[2].split(",")
        if bd[: len(md)] == md or md[: len(bd)] == bd:
            kind = "one is a prefix of the other"
        elif set(md) < set(bd):
            kind = "branch has extra dates"
        elif set(bd) < set(md):
            kind = "branch misses dates"
        else:
            kind = "different dates"
    kinds[kind] += 1
    samples[kind].append((i, text, m, b))

for k, v in kinds.most_common():
    print(f"{v}\t{k}")
for kind, rows in samples.items():
    print(f"\n== {kind} ({len(rows)})")
    for i, text, m, b in rows[:show]:
        zone = text.split()[1]
        print(f"#{i} {text} start={fmt(zone, (m[1] or b[1]))}")
        for name, r in (("main", m), ("branch", b)):
            if r[2] in ("CRASH", "TIMEOUT", "none"):
                print(f"  {name}: {r[2]} {r[4]}")
            else:
                ds = r[2].split(",")
                print(f"  {name}: {len(ds)} dates: " + ", ".join(fmt(zone, d) for d in ds[:6]))
