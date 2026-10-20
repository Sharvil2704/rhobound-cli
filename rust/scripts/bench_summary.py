#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Summarize a bench.sh folder: per capture and thread count, the median wall time of `rhobound predict --json`
and `rbfast predict --json`, the speedup, user+sys, peak RSS, the other processes' busy cores, and whether the
two outputs were the same bytes.
    python3 -I bench_summary.py OUTDIR"""
import collections
import os
import re
import statistics
import sys

D = sys.argv[1]
# the sizes of the recorded runs' captures (test-bed run 3 and big8-run3; see bench.sh)
SIZE = {"RUN3": "579 MB", "RUN3GZ": "36 MB gz (579 MB)", "BIG": "4.63 GB", "BIGGZ": "gz (4.63 GB)",
        "RUN3JSON": "579 MB .json", "RUN3JSONGZ": "36 MB .json.gz", "BIGJSONGZ": "8 .json.gz (4.63 GB)"}
runs = collections.defaultdict(list)
for line in open(D + "/runs.txt"):
    m = re.match(r"RUN (go|rb) (\S+) (\d+) rep=\d+ wall=([0-9.]+) user=([0-9.]+) sys=([0-9.]+) maxrss_mib=([0-9.]+) exit=(\d+)", line)
    if m:
        runs[(m.group(1), m.group(2), int(m.group(3)))].append(tuple(float(x) for x in m.group(4, 5, 6, 7, 8)))
others = {}
for line in open(D + "/others.txt"):
    m = re.match(r"OTHERS (go|rb) (\S+) (\d+) .* others_cores=(-?[0-9.]+)", line)
    if m:
        others[(m.group(1), m.group(2), int(m.group(3)))] = float(m.group(4))
hashes = {}
for line in open(D + "/hashes.txt"):
    _, who, cap, p, h = line.split()
    hashes[(who, cap, int(p))] = h
noisy_start = any("DEADLINE" in ln for ln in open(D + "/bench.log"))

print("| capture | threads | Go wall (s) | rbfast wall (s) | speedup | Go user+sys (s) | rbfast user+sys (s) | Go / rbfast peak RSS (MiB) | others' busy cores (Go / rbfast run) | same output |")
print("|---|---|---|---|---|---|---|---|---|---|")
caps = []
for k in runs:
    if k[1] not in caps:
        caps.append(k[1])
for cap in caps:
    for p in (1, 2, 4, 8):
        g, r = runs.get(("go", cap, p)), runs.get(("rb", cap, p))
        if not g or not r:
            continue
        med = lambda xs, k: statistics.median(x[k] for x in xs)
        gw, rw = med(g, 0), med(r, 0)
        gu, ru = med(g, 1) + med(g, 2), med(r, 1) + med(r, 2)
        og, orb = others.get(("go", cap, p), float("nan")), others.get(("rb", cap, p), float("nan"))
        flag = " NOISY" if max(og, orb) > 0.3 else ""
        same = "yes" if hashes.get(("go", cap, p)) == hashes.get(("rb", cap, p)) else "NO"
        bad = [x for x in g + r if x[4] != 0]
        print(f"| {cap} ({SIZE.get(cap, '')}) | {p} | {gw:.3f} | {rw:.3f} | {gw / rw:.2f}x | {gu:.2f} | {ru:.2f} | "
              f"{max(x[3] for x in g):.0f} / {max(x[3] for x in r):.0f} | {og:.2f} / {orb:.2f}{flag} | {same}"
              + (" (a run failed)" if bad else "") + " |")
print()
print("Each cell: median of 3 timed runs after one warm-up, warm page cache"
      + (f", wrapped in `{os.environ['RBFAST_WRAP']}`." if os.environ.get("RBFAST_WRAP") else "."))
if noisy_start:
    print("The machine did not get quiet within 45 minutes: ALL numbers are noisy.")
st = collections.defaultdict(list)
try:
    for line in open(D + "/stages.txt"):
        m = re.match(r"STAGES (\S+) rbfast: times: read ([0-9.]+) s, infer ([0-9.]+) s, model ([0-9.]+) s, report ([0-9.]+) s", line)
        if m:
            st[m.group(1)].append(tuple(float(x) for x in m.group(2, 3, 4, 5)))
except FileNotFoundError:
    pass
if st:
    print()
    print("rbfast at 8 threads, inside the process (median of 3; RBFAST_TIMES=1):")
    print()
    print("| capture | read (s) | inference (s) | model (s) | report (s) |")
    print("|---|---|---|---|---|")
    for cap, xs in st.items():
        m = [statistics.median(x[k] for x in xs) for k in range(4)]
        print(f"| {cap} | {m[0]:.4f} | {m[1]:.4f} | {m[2]:.4f} | {m[3]:.4f} |")
