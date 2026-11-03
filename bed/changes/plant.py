#!/usr/bin/env python3
"""plant.py: a planted change (SPEC3 F9) cut from the CURRENT repo/ (the frozen main), in the layout make_prs.sh consumes.

  python3 -I changes/plant.py NAME --service S --mechanism M [--dose D] [--replace] [--title T] [--summary TEXT]
                              [--force] [--no-compile]
  NAME  cN-plant (N: 1-2 digits). make_prs.sh opens it as a DRAFT PR labelled rbd-plant; orch/automerge.sh refuses to merge
        any rbd-plant PR (or head branch rbd/cN-plant), whatever its verdict: a planted regression is never merged.
  S     one of the five services with a plantable hook (repo/maze/spec.json's code path in parentheses):
          auth VerifyToken (verify_token), payments RiskCheck (risk_check), inventory StockCheck (stock_check):
            maze/app/internal/work/lib_v11.go (library 1.1, production's LIB=maze_v11);
          catalog Rank (rank): maze/app/internal/hot/rank.go;  pricing Quote (quote): maze/app/internal/hot/price.go.
  M and D (durations in ms, whole microseconds; the hold is the FIRST statement of the hooked function, before any cache
  lookup or early return, so every call pays it: VerifyToken's 256-entry LRU cannot damp it):
    sleep    D ms: time.Sleep(D) holds the calling worker (wall time, no CPU).                         0 < D <= 200
    spin     D ms of CPU: a dependent xorshift64 loop of a fixed iteration count per call, never a sleep. The count is
             calibrated once per process, at the first call: the fastest of 7 timed runs of 2^18 iterations (a run that
             was preempted or descheduled is slower and never the fastest), iterations = 2^18 x D / fastest. The knob is
             CPU work: on a contended CPU or under the pod's CPU quota the wall time stretches, the work does not.
                                                                                                     0 < D <= 200
    mutex    D ms: a package-level sync.Mutex held across time.Sleep(D): the pod's calls of the hook run one at a time,
             each holding the lock D ms (lock waits add to the hold).                                 0 < D <= 200
    bimodal  D = A:P:B: sleep A ms with probability P, else B ms (math/rand/v2). Mean M = P*A + (1-P)*B and the hold's
             cs2 = (P*A^2 + (1-P)*B^2 - M^2) / M^2 are recorded. Default: a hold at the top (it adds M on the mean: the
             variance twin of a 'sleep M' plant). --replace (payments only): it REPLACES RiskCheck's constant card hold
             (time.Sleep(6 * time.Millisecond) on main), and M must equal that constant: a variance-only change (T1g:
             --dose 101:0.05:1 --replace, mean 6 ms, cs2 13.19).                  0 <= A, B <= 1000, A != B, 0 < P < 1
    alloc    D MB (whole): allocate D MB per call, touch every 4 KiB page, read one byte back, drop it (lib_v15's
             pattern; the garbage collector's work runs beside the requests as much as inside them).       1 <= D <= 64
    noop     no D: one comment line at the top of the hooked function (the control: no code change).
    refactor no D: a behaviour-preserving rename of one parameter or local inside the hooked function only:
             auth arr -> derivedKey, payments method -> payMethod, inventory item -> itemID, catalog terms -> qterms,
             pricing semi -> semiAt (refused if the old name is a selector, a struct key or in a string literal there, or
             the new name is already a word of the file).
    improve  a documented speed-up at the constant itself; the edited line says what it was:
             payments: D ms = RiskCheck's new card hold (main: 6 ms; 0 < D < it; wallet calls unchanged; the 'N ms' of
             the comment just above RiskCheck follows);
             auth: D = VerifyToken's new PBKDF2 iteration count (main: 2500; 1 <= D < it; cache misses only).
             Other services have no such constant: refused.
  --title T       the PR title after the prefix 'PLANT do-not-merge: ' (always added; at most 72 characters in all)
  --summary TEXT  rhobound-change.json's summary (default: what was planted and how the dose is registered; 1..1000)
  --force         replace an existing changes/NAME (else refused)
  --no-compile    skip the compile check (tests only): the manifest says compiled: false, and make_prs.sh refuses such a
                  plant (unless PLANT_UNCOMPILED=1, its tests). Without it the patched copy of repo/ must pass
                  orch/gocheck.sh (agent_take.sh's capped, offline go build under the default tags and maze_v11 and
                  go vet -tags maze_v11).
Writes changes/NAME/ (atomically: a temporary folder renamed into place):
  change.patch          git diff against repo/maze (maze/app/*.go only: the hooked file, plus a new plant.go in its
                        package for sleep/spin/mutex/bimodal/alloc); checked with git apply --check on a fresh copy of repo/
  rhobound-change.json  rbd.change-request/v2 {schema, services: [S], summary}
  title.txt             the PR title (make_prs.sh: "NAME: TITLE")
  manifest.json         rbd.plant-change/v1: mechanism, knob, placement, intended effect, never_merge true, base_sha
                        (state/main.sha), the hooked file's sha256 on main, patch sha256, compiled; and the dose rule: the
                        REGISTERED dose is the A/B-measured own-time delta of S (dose.value_ms, filled from the A/B
                        record), never the knob, which is only the intended per-call cost.
Exit 0 written; 1 refused (anchors not found on main, NAME exists, bad dose, ...); 2 usage; 3 does not compile (the go
output is printed; nothing is written).
Env: RBD_CAPPED (passed to orch/gocheck.sh: the capped.sh to use; tests may set it to "")  GOCHECK_CACHE (the build cache)
Scratch: $RBD_SCRATCH/plant.XXXXXX (default $TMPDIR/rbd), removed at the end. python3 -I, stdlib only; runs git, gofmt.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

KIT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
REPO = os.path.join(KIT, "repo")
CHANGES = os.path.join(KIT, "changes")
PREFIX = "PLANT do-not-merge: "
WORK = "maze/app/internal/work/lib_v11.go"
HOOKS = {   # service -> (file, function, spec.json code path, package folder)
    "auth": (WORK, "VerifyToken", "verify_token"),
    "payments": (WORK, "RiskCheck", "risk_check"),
    "inventory": (WORK, "StockCheck", "stock_check"),
    "catalog": ("maze/app/internal/hot/rank.go", "Rank", "rank"),
    "pricing": ("maze/app/internal/hot/price.go", "Quote", "quote"),
}
RENAMES = {"auth": ("arr", "derivedKey"), "payments": ("method", "payMethod"), "inventory": ("item", "itemID"),
           "catalog": ("terms", "qterms"), "pricing": ("semi", "semiAt")}
MECHS = ("sleep", "spin", "mutex", "bimodal", "alloc", "noop", "refactor", "improve")
CARD_HOLD = re.compile(r"^(\t+)time\.Sleep\(([0-9]+) \* time\.Millisecond\)$")
PBKDF2 = re.compile(r"^(\t+.*pbkdf2\.Key\(.*, )([0-9]+)(, 32\).*)$")
SKIP = re.compile(r"\[\s*(?:skip\s+ci|ci\s+skip|no\s+ci|skip\s+actions|actions\s+skip)\s*\]|skip-checks\s*:\s*true", re.I)
LEAK = re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])|(?<![0-9])[0-9]{12}(?![0-9])")


class Refused(Exception):
    pass


def no(msg):
    raise Refused(msg)


def say(msg):
    print("[plant %s] %s" % (datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S"), msg), file=sys.stderr)


def fnum(x):
    """a number as the shortest plain decimal (3.0 -> '3', 1.5 -> '1.5', 0.05 -> '0.05')"""
    s = ("%.6f" % x).rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def ms_arg(text, what, lo_open, hi):
    """a duration in ms with whole microseconds, lo_open < x <= hi (lo_open None: 0 <= x)"""
    try:
        x = float(text)
    except ValueError:
        no("%s: %r is not a number of ms" % (what, text))
    if not math.isfinite(x) or (x <= lo_open if lo_open is not None else x < 0) or x > hi:
        no("%s: %s ms is out of range (want %s x <= %s ms)"
           % (what, text, "0 <" if lo_open is not None else "0 <=", fnum(hi)))
    us = round(x * 1000)
    if abs(x * 1000 - us) > 1e-6:
        no("%s: %s ms is not a whole number of microseconds" % (what, text))
    return us


def go_dur(us):
    """Go source for a duration of us microseconds: N * time.Millisecond when whole ms, else N * time.Microsecond"""
    return "%d * time.Millisecond" % (us // 1000) if us % 1000 == 0 else "%d * time.Microsecond" % us


def func_span(lines, fn, path):
    """(first, end): lines[first] is 'func FN(...) ... {', lines[end] is its closing '}' (gofmt: column 0)"""
    idx = [i for i, ln in enumerate(lines) if ln.startswith("func %s(" % fn)]
    if len(idx) != 1:
        no("%s: %d lines start 'func %s(' on main (want 1): repo/ moved, the hook is gone" % (path, len(idx), fn))
    i = idx[0]
    if not lines[i].endswith("{"):
        no("%s: 'func %s(' does not end its line with '{'" % (path, fn))
    for j in range(i + 1, len(lines)):
        if lines[j] == "}":
            return i, j
        if lines[j].startswith("func "):
            break
    no("%s: no closing '}' of %s at column 0 (not gofmt'd?)" % (path, fn))


def one(lines, i, j, rx, what, path):
    """the single line in lines[i..j] matching rx -> (index, match)"""
    hits = [(k, rx.match(lines[k])) for k in range(i, j + 1) if rx.match(lines[k])]
    if len(hits) != 1:
        no("%s: %d lines of %s on main (want exactly 1): repo/ moved" % (path, len(hits), what))
    return hits[0]


def doc_block(lines, i):
    """indices of the // comment block directly above line i"""
    k = i - 1
    out = []
    while k >= 0 and lines[k].startswith("//"):
        out.insert(0, k)
        k -= 1
    return out


def helper_go(pkg, name, mech, us=0, a_us=0, p=0.0, b_us=0, mb=0, func="", stats=None):
    """the new plant.go of package pkg: the helper the hooked function calls (plantHold, or plantHoldDur for --replace)"""
    head = ["// Code planted by changes/plant.py (rhobound SPEC3 F9) for the change %s: NEVER merge it." % name,
            "// make_prs.sh opens it as a draft PR labelled rbd-plant; orch/automerge.sh refuses every rbd-plant PR.",
            "// The knob below is the intended per-call cost only: the registered dose is the A/B-measured own-time",
            "// delta of the service, not this knob.",
            "", "package " + pkg, ""]
    if mech == "sleep":
        body = ['import "time"', "",
                "// plantHoldFor: the wall time plantHold holds the calling worker, at the top of %s." % func,
                "const plantHoldFor = " + go_dur(us), "",
                "func plantHold() {", "\ttime.Sleep(plantHoldFor)", "}"]
    elif mech == "spin":
        body = ["import (", '\t"sync"', '\t"sync/atomic"', '\t"time"', ")", "",
                ("// plantSpinCPU: the CPU time plantHold burns per call, at the top of %s. It never sleeps: a "
                 "dependent") % func,
                "// xorshift64 loop runs a fixed number of iterations per call, calibrated once per process at the first",
                "// call as the fastest of 7 timed runs of plantSpinProbe iterations (a run that was preempted or",
                "// descheduled is slower, never the fastest). On a contended CPU or under the pod's CPU quota the wall",
                "// time stretches; the CPU work does not.",
                "const plantSpinCPU = " + go_dur(us), "",
                "const plantSpinProbe = 1 << 18", "",
                "var (", "\tplantSpinOnce  sync.Once", "\tplantSpinIters uint64", "\tplantSpinSink  atomic.Uint64", ")", "",
                "func plantSpinLoop(n uint64) uint64 {", "\tx := uint64(0x9e3779b97f4a7c15)",
                "\tfor i := uint64(0); i < n; i++ {", "\t\tx ^= x << 13", "\t\tx ^= x >> 7", "\t\tx ^= x << 17", "\t}",
                "\treturn x", "}", "",
                "func plantSpinCalibrate() {", "\tbest := time.Duration(-1)", "\tfor i := 0; i < 7; i++ {",
                "\t\tt0 := time.Now()", "\t\tplantSpinSink.Add(plantSpinLoop(plantSpinProbe))",
                "\t\tif d := time.Since(t0); d > 0 && (best < 0 || d < best) {", "\t\t\tbest = d", "\t\t}", "\t}",
                "\tif best <= 0 {", "\t\tbest = plantSpinProbe // 1 ns per iteration when the clock saw nothing", "\t}",
                "\tplantSpinIters = uint64(float64(plantSpinProbe) * float64(plantSpinCPU) / float64(best))", "}", "",
                "func plantHold() {", "\tplantSpinOnce.Do(plantSpinCalibrate)",
                "\tplantSpinSink.Add(plantSpinLoop(plantSpinIters))", "}"]
    elif mech == "mutex":
        body = ["import (", '\t"sync"', '\t"time"', ")", "",
                "// plantMu serialises the pod's calls of %s: each holds it across plantHoldFor of sleep." % func,
                "var plantMu sync.Mutex", "",
                "const plantHoldFor = " + go_dur(us), "",
                "func plantHold() {", "\tplantMu.Lock()", "\ttime.Sleep(plantHoldFor)", "\tplantMu.Unlock()", "}"]
    elif mech in ("bimodal", "bimodal-replace"):
        body = ["import (", '\t"math/rand/v2"', '\t"time"', ")", "",
                "// plantHoldDur: plantA with probability plantP, else plantB: mean %s ms, cs2 %s (of this hold alone)."
                % (fnum(stats["mean_ms"]), fnum(stats["cs2"])),
                "const (", "\tplantA = " + go_dur(a_us), "\tplantP = " + fnum(p), "\tplantB = " + go_dur(b_us), ")", "",
                "func plantHoldDur() time.Duration {", "\tif rand.Float64() < plantP {", "\t\treturn plantA", "\t}",
                "\treturn plantB", "}"]
        if mech == "bimodal":
            body += ["", "func plantHold() {", "\ttime.Sleep(plantHoldDur())", "}"]
    elif mech == "alloc":
        body = ['import "sync/atomic"', "",
                "// plantAllocBytes: the scratch allocation plantHold makes, touches and drops on every call of %s." % func,
                "const plantAllocBytes = %d << 20" % mb, "",
                "var plantAllocSink atomic.Uint64", "",
                "func plantHold() {", "\tbuf := make([]byte, plantAllocBytes)",
                "\tfor i := 0; i < len(buf); i += 4096 { // touch every page", "\t\tbuf[i] = byte(i >> 12)", "\t}",
                "\tplantAllocSink.Add(uint64(buf[len(buf)-4096])) // read back: the allocation is used", "}"]
    else:
        raise AssertionError(mech)
    return "\n".join(head + body) + "\n"


def plan(a, src, svc):
    """-> (edits {path: text}, knob, placement, intended_effect, intended_own_ms_per_call, title_knob)"""
    path, fn, _ = HOOKS[svc]
    pkgdir = os.path.dirname(path)
    pkg = os.path.basename(pkgdir)
    text = src[path]
    lines = text.split("\n")
    i, j = func_span(lines, fn, path)
    ind = "\t"
    top = "top of %s, before its first statement: every call (before any cache lookup or early return)" % fn
    m = a.mechanism
    helper = pkgdir + "/plant.go"
    if m in ("sleep", "spin", "mutex", "bimodal", "alloc"):
        if os.path.lexists(os.path.join(REPO, helper)):
            no("%s exists on main: a plant is already merged there?" % helper)
        taken = sorted({w for p, t in src.items() if os.path.dirname(p) == pkgdir
                        for w in re.findall(r"\bplant[A-Z]\w*", t)})
        if taken:
            no("package %s already has plant* identifiers (%s): refused" % (pkg, ", ".join(taken[:5])))
    if m in ("noop", "refactor") and a.dose is not None:
        no("%s takes no --dose" % m)
    if m not in ("noop", "refactor") and a.dose is None:
        no("%s needs --dose" % m)
    if a.replace and not (m == "bimodal" and svc == "payments"):
        no("--replace is for bimodal on payments only (it replaces RiskCheck's constant card hold)")
    edits = {}
    if m in ("sleep", "spin", "mutex"):
        us = ms_arg(a.dose, "--dose", 0, 200)
        ms = us / 1000
        edits[helper] = helper_go(pkg, a.name, m, us=us, func=fn)
        lines.insert(i + 1, ind + "plantHold() // planted (%s, SPEC3 F9): never merge" % a.name)
        if m == "sleep":
            knob = {"hold_ms": ms, "how": "time.Sleep, wall time: the worker is held, no CPU"}
            eff = "+%s ms of wall time per call of %s, the worker held (no CPU)" % (fnum(ms), fn)
            tk = "+%s ms sleep" % fnum(ms)
        elif m == "spin":
            knob = {"cpu_ms": ms, "how": "a dependent xorshift64 loop, never a sleep", "calibration":
                    "once per process at the first call: the fastest of 7 timed runs of 2^18 iterations; "
                    "iterations per call = 2^18 x cpu_ms / fastest (the first call also pays the ~7 probe runs)"}
            eff = ("+%s ms of CPU per call of %s on an idle core (more wall time on a contended CPU or under the pod's "
                   "CPU quota)" % (fnum(ms), fn))
            tk = "+%s ms CPU spin" % fnum(ms)
        else:
            knob = {"hold_ms": ms, "how": "a package-level sync.Mutex held across time.Sleep: one call at a time per pod"}
            eff = ("at least +%s ms per call of %s, plus the wait for the lock: the pod's calls are serialised (one at a "
                   "time, %s ms each), so a pod with more than one worker queues on the lock" % (fnum(ms), fn, fnum(ms)))
            tk = "+%s ms mutex-held sleep" % fnum(ms)
        own = ms
        place = top
    elif m == "bimodal":
        parts = a.dose.split(":")
        if len(parts) != 3:
            no("bimodal --dose is A:P:B (sleep A ms with probability P, else B ms), not %r" % a.dose)
        a_us = ms_arg(parts[0], "bimodal A", None, 1000)
        b_us = ms_arg(parts[2], "bimodal B", None, 1000)
        try:
            p = float(parts[1])
        except ValueError:
            no("bimodal P %r is not a number" % parts[1])
        if not (0 < p < 1) or a_us == b_us:
            no("bimodal: want 0 < P < 1 and A != B (got P %s, A %s, B %s)" % (parts[1], parts[0], parts[2]))
        if abs(round(p, 6) - p) > 1e-12:
            no("bimodal P %r has more than 6 decimals" % parts[1])
        p = round(p, 6)
        A, B = a_us / 1000, b_us / 1000
        mean = p * A + (1 - p) * B
        if mean <= 0:
            no("bimodal: the mean is 0")
        cs2 = (p * A * A + (1 - p) * B * B - mean * mean) / (mean * mean)
        stats = {"mean_ms": round(mean, 9), "cs2": round(cs2, 6)}
        knob = {"a_ms": A, "p": p, "b_ms": B, "mean_ms": stats["mean_ms"], "cs2": stats["cs2"],
                "how": "time.Sleep(A) with probability P, else time.Sleep(B) (math/rand/v2)", "replaces": None}
        if a.replace:
            k, mt = one(lines, i, j, CARD_HOLD, "time.Sleep(N * time.Millisecond) in RiskCheck (the card hold)", path)
            const = int(mt.group(2))
            if abs(mean - const) > 1e-9:
                no("bimodal --replace: the mean P*A + (1-P)*B = %s ms must equal the card hold it replaces (%d ms on "
                   "main): a variance-only change" % (fnum(mean), const))
            edits[helper] = helper_go(pkg, a.name, "bimodal-replace", a_us=a_us, p=p, b_us=b_us, stats=stats, func=fn)
            knob["replaces"] = {"line": lines[k].strip(), "const_ms": const, "const_cs2": 0}
            lines[k] = mt.group(1) + "time.Sleep(plantHoldDur()) // planted (%s, SPEC3 F9): never merge" % a.name
            place = "replaces RiskCheck's constant card hold (card calls only; wallet calls unchanged)"
            eff = ("mean unchanged (variance only): each card call's hold becomes %s ms w.p. %s else %s ms (mean %s ms, "
                   "cs2 %s), was a constant %d ms (cs2 0)" % (fnum(A), fnum(p), fnum(B), fnum(mean), fnum(cs2), const))
            own = 0.0
            tk = "card hold -> %s/%s ms p=%s" % (fnum(A), fnum(B), fnum(p))
        else:
            edits[helper] = helper_go(pkg, a.name, "bimodal", a_us=a_us, p=p, b_us=b_us, stats=stats, func=fn)
            lines.insert(i + 1, ind + "plantHold() // planted (%s, SPEC3 F9): never merge" % a.name)
            place = top
            eff = ("+%s ms mean of wall time per call of %s with cs2 %s (the variance twin of a 'sleep %s' plant: same "
                   "mean, cs2 0)" % (fnum(mean), fn, fnum(cs2), fnum(mean)))
            own = round(mean, 9)
            tk = "bimodal %s/%s ms p=%s" % (fnum(A), fnum(B), fnum(p))
    elif m == "alloc":
        if not re.fullmatch(r"[0-9]{1,2}", a.dose.strip()) or not 1 <= int(a.dose) <= 64:
            no("alloc --dose is whole MB, 1..64 (got %r)" % a.dose)
        mb = int(a.dose)
        edits[helper] = helper_go(pkg, a.name, "alloc", mb=mb, func=fn)
        lines.insert(i + 1, ind + "plantHold() // planted (%s, SPEC3 F9): never merge" % a.name)
        knob = {"alloc_mb": mb, "how": "make([]byte, N MB), one byte written per 4 KiB page, one read back, dropped "
                "(lib_v15's pattern)"}
        place = top
        eff = ("%d MB of garbage per call of %s: allocation, zeroing and page touches inside the call, collector work "
               "beside it (background marking, the scavenger) under the pod's CPU limit; no wall-time hold" % (mb, fn))
        own = None
        tk = "%d MB alloc per call" % mb
    elif m == "noop":
        lines.insert(i + 1, ind + "// %s (planted, SPEC3 F9): a comment-only control; no code changes." % a.name)
        knob = {}
        place = "a comment line at the top of %s" % fn
        eff = "none: comment-only (the control); the image differs only in line tables"
        own = 0.0
        tk = "comment-only control"
    elif m == "refactor":
        old, new = RENAMES[svc]
        if re.search(r"\b%s\b" % new, text):
            no("refactor: %r is already a word of %s: refused (it could shadow)" % (new, path))
        span = lines[i:j + 1]
        hits = sum(len(re.findall(r"\b%s\b" % old, ln)) for ln in span)
        if hits < 2:
            no("refactor: %r occurs %d time(s) in %s on main (want >= 2): repo/ moved" % (old, hits, fn))
        for ln in span:
            code = ln.split("//", 1)[0]
            if re.search(r"\.%s\b|\b%s\s*:(?!=)" % (old, old), code):
                no("refactor: %r is a selector or a struct key in %s: refused" % (old, fn))
            for s in re.findall(r'"(?:[^"\\]|\\.)*"|`[^`]*`', code):
                if re.search(r"\b%s\b" % old, s):
                    no("refactor: %r is inside a string literal in %s: refused" % (old, fn))
        lines[i:j + 1] = [re.sub(r"\b%s\b" % old, new, ln) for ln in span]
        knob = {"rename": [old, new], "scope": "%s only (%d occurrences)" % (fn, hits)}
        place = "inside %s" % fn
        eff = "none: a behaviour-preserving rename (the image differs only in debug names and line tables)"
        own = 0.0
        tk = "rename %s -> %s" % (old, new)
    elif m == "improve":
        if svc == "payments":
            k, mt = one(lines, i, j, CARD_HOLD, "time.Sleep(N * time.Millisecond) in RiskCheck (the card hold)", path)
            const = int(mt.group(2))
            us = ms_arg(a.dose, "improve --dose (payments: the new card hold)", 0, const)
            if us >= const * 1000:
                no("improve: payments' card hold is %d ms on main; --dose %s ms is not a speed-up" % (const, a.dose))
            new = us / 1000
            lines[k] = mt.group(1) + "time.Sleep(%s) // planted (%s, SPEC3 F9): was %d ms" % (go_dur(us), a.name, const)
            doc = [d for d in doc_block(lines, i) if re.search(r"\b%d ms\b" % const, lines[d])]
            for d in doc:
                lines[d] = re.sub(r"\b%d ms\b" % const, "%s ms" % fnum(new), lines[d])
            knob = {"card_hold_ms": [const, new], "doc_updated": bool(doc)}
            place = "RiskCheck's card hold constant (card calls only)"
            eff = "-%s ms of wall time per card call of RiskCheck (wallet calls unchanged): queue relief" % fnum(const - new)
            own = None
            tk = "card hold %d -> %s ms" % (const, fnum(new))
        elif svc == "auth":
            k, mt = one(lines, i, j, PBKDF2, "pbkdf2.Key(..., N, 32) in VerifyToken", path)
            cur = int(mt.group(2))
            if not re.fullmatch(r"[0-9]{1,6}", a.dose.strip()) or not 1 <= int(a.dose) < cur:
                no("improve: auth --dose is the new PBKDF2 iteration count, 1..%d (main: %d), not %r"
                   % (cur - 1, cur, a.dose))
            n = int(a.dose)
            if "//" in mt.group(3):
                no("%s: the pbkdf2.Key line already carries a comment: repo/ moved" % path)
            lines[k] = mt.group(1) + str(n) + mt.group(3) + " // planted (%s, SPEC3 F9): was %d iterations" % (a.name, cur)
            knob = {"pbkdf2_iterations": [cur, n], "doc_updated": False,
                    "doc_note": "the comments above VerifyToken still give main's %d iterations and ~3 ms; the edited "
                                "line says 'was %d iterations'" % (cur, cur)}
            place = "VerifyToken's PBKDF2 iteration count (cache misses only)"
            eff = ("VerifyToken's CPU per cache miss scaled by about %d/%d (the 256-entry LRU's hits are unchanged)"
                   % (n, cur))
            own = None
            tk = "PBKDF2 %d -> %d iterations" % (cur, n)
        else:
            no("improve: only payments (the card hold) and auth (PBKDF2 iterations) have a documented speed-up "
               "constant; %s has none" % svc)
    else:
        raise AssertionError(m)
    edits[path] = "\n".join(lines)
    return edits, knob, place, eff, own, tk


def git(cwd, *args, inp=None):
    r = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=plant", "-c", "user.email=plant@localhost",
                        "-c", "color.ui=never", *args], cwd=cwd, input=inp, capture_output=True)
    if r.returncode != 0:
        no("git %s in %s: %s" % (" ".join(args[:2]), cwd, r.stderr.decode(errors="replace").strip()[-300:]))
    return r.stdout


def text_ok(what, t, cap):
    if not isinstance(t, str) or not 1 <= len(t) <= cap or not all(c.isprintable() or (c == "\n" and cap > 72) for c in t):
        no("%s: 1..%d printable characters" % (what, cap))
    if SKIP.search(t):
        no("%s holds a CI-skip token (%r): the gate would not run" % (what, SKIP.search(t).group()))
    if LEAK.search(t):
        no("%s holds an IPv4 address or a 12-digit number (%s): refused" % (what, LEAK.search(t).group()))


def main(argv):
    ap = argparse.ArgumentParser(prog="plant.py", description="a planted change (SPEC3 F9): see the module docstring")
    ap.add_argument("name")
    ap.add_argument("--service", required=True)
    ap.add_argument("--mechanism", required=True, choices=MECHS)
    ap.add_argument("--dose")
    ap.add_argument("--replace", action="store_true")
    ap.add_argument("--title")
    ap.add_argument("--summary")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-compile", action="store_true")
    a = ap.parse_args(argv)
    if not re.fullmatch(r"c[0-9]{1,2}-plant", a.name):
        no("NAME must be cN-plant (N: 1-2 digits; make_prs.sh labels it rbd-plant), not %r" % a.name)
    out = os.path.join(CHANGES, a.name)
    if os.path.lexists(out) and not a.force:
        no("changes/%s exists (--force replaces it)" % a.name)
    spec = json.load(open(os.path.join(REPO, "maze", "spec.json")))["services"]
    if a.service not in HOOKS:
        no("service %r has no plantable hook (%s)" % (a.service, ", ".join("%s %s" % (s, h[1]) for s, h in HOOKS.items())))
    path, fn, cp = HOOKS[a.service]
    if cp not in (spec.get(a.service) or {}).get("code_paths", []):
        no("%s does not run code path %s in repo/maze/spec.json: %s would never be called" % (a.service, cp, fn))
    msha = os.path.join(KIT, "state", "main.sha")
    base = open(msha).read(64).strip() if os.path.isfile(msha) else ""
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        no("no 40-hex state/main.sha (orch/publish_main.sh writes it): repo/ is that commit")
    pkgdir = os.path.join(REPO, os.path.dirname(path))
    src = {}
    for n in sorted(os.listdir(pkgdir)):
        if n.endswith(".go"):
            src[os.path.dirname(path) + "/" + n] = open(os.path.join(pkgdir, n), encoding="utf-8").read()
    if path not in src:
        no("%s is not on main (repo/)" % path)
    edits, knob, place, eff, own, tk = plan(a, src, a.service)

    if a.title is not None:
        title = a.title.strip()
        title = title if title.startswith(PREFIX) else PREFIX + title
    else:
        title = PREFIX + "%s %s %s" % (a.service, fn, tk)
        if len(title) > 72:
            title = PREFIX + "%s %s %s" % (a.service, fn, a.mechanism)
    text_ok("the title", title, 72)
    summary = a.summary if a.summary is not None else (
        "Planted change %s (SPEC3 F9; never merged: orch/automerge.sh refuses rbd-plant PRs): %s %s: %s (mechanism %s; "
        "placement: %s). Intended effect: %s. The registered dose is the A/B-measured own-time delta of %s, not this knob."
        % (a.name, a.service, fn, tk, a.mechanism, place, eff, a.service))
    text_ok("the summary", summary, 1000)

    scr = os.environ.get("RBD_SCRATCH") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "rbd")
    os.makedirs(scr, exist_ok=True)
    W = tempfile.mkdtemp(prefix="plant.", dir=scr)
    try:
        G, A = os.path.join(W, "g"), os.path.join(W, "a")
        for d in (G, A):
            os.makedirs(d)
            shutil.copytree(os.path.join(REPO, "maze"), os.path.join(d, "maze"), symlinks=True)
        git(G, "init", "-q", "-b", "main")
        git(A, "init", "-q", "-b", "main")   # git apply in A works on A, never on a repository around the scratch
        git(G, "add", "-A")
        git(G, "commit", "-q", "-m", "main (repo/)")
        for p, t in edits.items():
            with open(os.path.join(G, p), "w", encoding="utf-8") as f:
                f.write(t)
        git(G, "add", "-A")
        names = git(G, "diff", "--cached", "--name-only", "--no-renames").decode().split()
        if not names:
            no("the change is empty against repo/")
        bad = [n for n in names if not re.fullmatch(r"maze/app/[A-Za-z0-9_./-]+\.go", n)]
        if bad:
            no("the change touches paths outside maze/app/*.go: %s" % bad)
        patch = git(G, "diff", "--cached", "--no-ext-diff", "--no-renames", "--no-color")
        with open(os.path.join(W, "change.patch"), "wb") as f:
            f.write(patch)
        git(A, "apply", "--check", os.path.join(W, "change.patch"))   # a fresh copy of repo/: the frozen main
        git(A, "apply", os.path.join(W, "change.patch"))
        gobin = shutil.which("go")
        gofmt = shutil.which("gofmt") or (gobin and os.path.join(os.path.dirname(os.path.realpath(gobin)), "gofmt"))
        if gofmt and os.access(gofmt, os.X_OK):
            r = subprocess.run([gofmt, "-l", *names], cwd=A, capture_output=True, text=True)
            if r.returncode != 0 or r.stdout.strip():
                no("gofmt would reformat the generated code (a plant.py bug): %s %s"
                   % (r.stdout.strip(), r.stderr.strip()[-200:]))
        else:
            say("gofmt not found: the format check is skipped")
        compiled, comp = False, None
        if a.no_compile:
            say("--no-compile: NOT compiled here (manifest compiled: false); the CI build is the first compile")
        else:
            log = os.path.join(W, "compile.txt")
            rc = subprocess.run(["bash", os.path.join(KIT, "orch", "gocheck.sh"), A, log, *names]).returncode
            if rc == 3:
                print("plant: error: the planted change does not compile (above): nothing written", file=sys.stderr)
                return 3
            if rc != 0:
                no("orch/gocheck.sh refused (exit %d, above)" % rc)
            gv = subprocess.run(["go", "version"], capture_output=True, text=True).stdout.strip()
            compiled, comp = True, {"check": "orch/gocheck.sh", "go": gv, "build_tags": ["", "maze_v11"],
                                    "vet_tags": "maze_v11", "goos_goarch": "linux/amd64"}
        hooked = src[path].encode("utf-8")
        man = {
            "schema": "rbd.plant-change/v1", "name": a.name, "service": a.service, "function": fn, "file": path,
            "code_path": cp, "helper": next((p for p in edits if p.endswith("/plant.go")), None),
            "lib": "maze_v11 (production's LIB)" if path == WORK else "untagged (every library version)",
            "mechanism": a.mechanism, "knob": knob, "placement": place, "intended_effect": eff,
            "intended_own_ms_per_call": own,
            "dose": {"registered": "ab_own_time_delta_ms", "value_ms": None,
                     "rule": "The registered dose of this plant is the A/B-measured own-time delta of %s (the gate's A/B of "
                             "this image against production), never the knob: the knob is the intended per-call cost "
                             "only. value_ms is filled from the A/B record." % a.service},
            "never_merge": True,
            "never_merge_how": "make_prs.sh: a draft PR labelled rbd-plant; orch/automerge.sh refuses every rbd-plant PR "
                               "and every head branch rbd/cN-plant, whatever the verdict",
            "base_sha": base, "main_file_sha256": hashlib.sha256(hooked).hexdigest(),
            "patch_sha256": hashlib.sha256(patch).hexdigest(), "files": names, "compiled": compiled, "compile": comp,
            "title": title, "summary": summary,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generator": "changes/plant.py " + " ".join(argv),
        }
        req = {"schema": "rbd.change-request/v2", "services": [a.service], "summary": summary}
        tmp = tempfile.mkdtemp(prefix="." + a.name + ".", dir=CHANGES)
        try:
            shutil.copyfile(os.path.join(W, "change.patch"), os.path.join(tmp, "change.patch"))
            with open(os.path.join(tmp, "rhobound-change.json"), "w") as f:
                f.write(json.dumps(req) + "\n")
            with open(os.path.join(tmp, "title.txt"), "w") as f:
                f.write(title + "\n")
            with open(os.path.join(tmp, "manifest.json"), "w") as f:
                f.write(json.dumps(man, indent=1) + "\n")
            os.chmod(tmp, 0o755)
            old = None
            if os.path.lexists(out):
                old = out + ".old-" + os.path.basename(tmp)
                os.rename(out, old)
            os.rename(tmp, out)
            tmp = None
            if old:
                shutil.rmtree(old)
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)
    finally:
        shutil.rmtree(W, ignore_errors=True)
    say("changes/%s written (%s, %s %s: %s; %s); next: bash changes/make_prs.sh %s"
        % (a.name, a.mechanism, a.service, fn, tk, "compiled" if compiled else "NOT compiled", a.name))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as e:
        print("plant: refused: %s" % e, file=sys.stderr)
        sys.exit(1)
