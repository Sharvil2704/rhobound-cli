#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Runs a command N times and prints, for each run, its wall time (fork to wait4), user and sys CPU time and peak
RSS (from wait4's rusage), then the median wall time, in the form bench.sh and bench_sweep.sh read:

    python3 -I scripts/timer.py [-n N] [-o STDOUT_FILE] [-label LABEL] -- CMD ARGS...

    RUN LABEL rep=I wall=S user=S sys=S maxrss_mib=M exit=C
    MEDIAN LABEL n=N wall=S min=S max=S

The command's stdout goes to STDOUT_FILE (rewritten each run) or is discarded; its stderr is passed through. The
peak RSS is the kernel's figure for the child, which starts from the forking process's own size (about 10 MiB for
this script), so it is a floor for small commands.
The runs recorded in results/ were timed by a small Go program with this interface and output (not published).
"""
import argparse
import os
import subprocess
import sys
import time

P = argparse.ArgumentParser()
P.add_argument("-n", type=int, default=1, help="repetitions")
P.add_argument("-o", default="", help="write the command's stdout here (default: discard)")
P.add_argument("-label", default="", help="label printed with each line")
P.add_argument("cmd", nargs=argparse.REMAINDER)
A = P.parse_args()
cmd = A.cmd[1:] if A.cmd[:1] == ["--"] else A.cmd
if not cmd:
    P.error("no command")

walls = []
for i in range(A.n):
    out = open(A.o, "wb") if A.o else subprocess.DEVNULL
    try:
        t0 = time.monotonic()
        proc = subprocess.Popen(cmd, stdout=out)
        _, status, ru = os.wait4(proc.pid, 0)
        wall = time.monotonic() - t0
        proc.returncode = os.waitstatus_to_exitcode(status)
    finally:
        if A.o:
            out.close()
    print(f"RUN {A.label} rep={i} wall={wall:.3f} user={ru.ru_utime:.3f} sys={ru.ru_stime:.3f} "
          f"maxrss_mib={ru.ru_maxrss / 1024:.1f} exit={proc.returncode}", flush=True)
    walls.append(wall)
walls.sort()
print(f"MEDIAN {A.label} n={len(walls)} wall={walls[len(walls) // 2]:.3f} min={walls[0]:.3f} max={walls[-1]:.3f}")
sys.exit(0)
