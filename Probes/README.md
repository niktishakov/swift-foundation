# Calendar search probes

Comparison probes for the `calendar-recursion-full` branch. Not for merging.

Each probe is a test that does nothing unless its environment variable is set. It writes one line per search to a file. Run it on main and on the branch, then compare the two files.

| Probe | Variables | Compare with |
|---|---|---|
| `nextDateDiffProbe` | `NEXTDATE_PROBE_OUT`, `NEXTDATE_PROBE_CASES` | `python3 Probes/probe_diff.py main.tsv branch.tsv` |
| `cal12Probe` | `CAL12_OUT`, `CAL12_CASES` | `python3 Probes/probe_diff.py main.tsv branch.tsv` |
| `recurrenceRuleDiffProbe` | `RRULE_PROBE_OUT`, `RRULE_PROBE_CASES`, `RRULE_PROBE_FROM`, `RRULE_PROBE_TO` | `python3 Probes/compare.py main.tsv branch.tsv` |
| `nearStartProbe` | `NEAR_PROBE_OUT` | `python3 Probes/near_diff.py main.tsv branch.tsv` |
| `holeProbe` | `HOLE_PROBE_OUT` | `python3 Probes/hole_diff.py main.tsv branch.tsv` |

Example:

```
NEXTDATE_PROBE_OUT=/tmp/branch.tsv NEXTDATE_PROBE_CASES=20000 swift test -c release -Xswiftc -enable-testing --filter nextDateDiffProbe
```

`recurrenceRuleDiffProbe` runs one rule per process when `RRULE_PROBE_FROM` and `RRULE_PROBE_TO` are set, because main crashes on some rules.
