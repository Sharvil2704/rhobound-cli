#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""rbfast against the Go reference (rhobound), on every input there is. Driven by parity.sh, which builds both
binaries and records the Go CLI tests' command lines first; run that, not this.

Groups (each command line runs through both binaries, with the same arguments, so paths in the output match):
  oracle   every `rhobound` line of every oracle capture's commands.txt (infer, predict --json and text, --plain,
           --patch, --workers, --max-rho refusals, GOMAXPROCS=1 runs as rbfast --threads 1), compared with the
           oracle's files AND with the fresh Go build; plus rbfast predict --json at 3 threads and with Go's
           serial sort (RBFAST_SORT=go-exact) against the oracle
  cli      every command line the Go tests in cmd/rhobound run (recorded by scripts/go/zz_record_test.go),
           replayed: Go's in-test output, the fresh Go binary and rbfast
  fail     failing and edge inputs written here (usage errors, bad flags, NaN/Inf, missing or broken captures
           and topologies, refusals, stdout on /dev/full)
  model    `model` on every inferred topology (infer.json) at three loads and a refusing one, +-plain, +-patch,
           JSON and text
  sweep    `rbfast sweep` lines against `rhobound model --json` for the same load and change (every line of a
           small grid on six topologies), sweep --capture against predict, and sweep at 1 thread vs all
  edge     the cases found when the first version was checked, written by scripts/edge_inputs.py and the Go test
           scripts/go/ties/zz_tie_captures_test.go: spans tied on (trace, start) in parallel calls to one callee (at
           1, 3 and all threads, and with Go's serial sort), `.json` streams (pretty, adjacent, cut inside a value,
           syntax errors, truncations, corrupt gzip), service and topology names with \v and \f (the tabwriter),
           paths and arguments that are not UTF-8, %q of unusual characters, RHOBOUND_ESTIMATOR values, --out
           over files, read-only folders and symlink loops, sweep's order of checks and wording, an invalid UTF-8
           port, 100,000 8-byte peer names
  big      predict --json on the large captures: every folder in the oracle's bench/ (here: 4.6 GB big8-run3,
           test-bed run 3 gzipped and big8-run3 gzipped), against bench-out/NAME/predict.json where there is one;
           the largest oracle capture (test-bed run 3) as one `.json` stream, and each gzipped bench capture's
           files as `.json.gz` streams (skipped with --quick)

A comparison is `identical` (stdout, stderr and the exit code are the same bytes, after the program name at the
start of an error line: rbfast prints `rbfast: `, Go `rhobound: `), `equal` (exit codes equal and the JSON
stdout structurally equal, every number within --tol relative), or a DIFF (printed). The usage text, `help`
and `version` are rbfast's own: only their exit codes are compared.
"""
import argparse
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

P = argparse.ArgumentParser()
P.add_argument("--go", required=True)
P.add_argument("--rbfast", required=True)
P.add_argument("--oracle", required=True)
P.add_argument("--cases", required=True)
P.add_argument("--fixture", required=True)
P.add_argument("--examples", required=True)
P.add_argument("--work", required=True)
P.add_argument("--edge", default="", help="edge inputs (scripts/edge_inputs.py)")
P.add_argument("--edge-go", default="", help="tie captures recorded by scripts/go/ties/zz_tie_captures_test.go")
P.add_argument("--tol", type=float, default=1e-9)
P.add_argument("--quick", action="store_true")
P.add_argument("--only", default="", help="comma list of groups")
A = P.parse_args()

os.makedirs(A.work, exist_ok=True)
RESULTS = []  # (group, name, verdict, detail)
MAXREL = {"value": 0.0, "where": ""}


def run(binary, args, env=None, stdout_path=None, timeout=1800):
    e = dict(os.environ)
    if env:
        e.update(env)
    out_f = open(stdout_path, "wb") if stdout_path else subprocess.PIPE
    try:
        p = subprocess.run([binary] + args, stdout=out_f, stderr=subprocess.PIPE, env=e, timeout=timeout)
    finally:
        if stdout_path:
            out_f.close()
    return p.returncode, (p.stdout if not stdout_path else b""), p.stderr


def norm_err(b):
    s = b.decode("utf-8", "replace") if isinstance(b, bytes) else b
    return re.sub(r"(?m)^rbfast: ", "rhobound: ", s)


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def jcmp(a, b, path, diffs):
    if is_num(a) and is_num(b):
        if a == b:
            return
        fa, fb = float(a), float(b)
        rel = abs(fa - fb) / max(abs(fa), abs(fb), 1e-300)
        if rel > MAXREL["value"]:
            MAXREL["value"], MAXREL["where"] = rel, path
        if rel > A.tol:
            diffs.append(f"{path}: {a!r} vs {b!r} (rel {rel:.3g})")
        return
    if type(a) is not type(b):
        diffs.append(f"{path}: type {type(a).__name__} vs {type(b).__name__}")
        return
    if isinstance(a, dict):
        if list(a.keys()) != list(b.keys()):
            diffs.append(f"{path}: keys {list(a.keys())} vs {list(b.keys())}")
            return
        for k in a:
            jcmp(a[k], b[k], f"{path}.{k}", diffs)
    elif isinstance(a, list):
        if len(a) != len(b):
            diffs.append(f"{path}: length {len(a)} vs {len(b)}")
            return
        for i, (x, y) in enumerate(zip(a, b)):
            jcmp(x, y, f"{path}[{i}]", diffs)
    elif a != b:
        diffs.append(f"{path}: {str(a)[:200]!r} vs {str(b)[:200]!r}")


def as_json(b):
    try:
        return json.loads(b)
    except Exception:
        return None


def compare(group, name, want, got, codes_only=False, known=None):
    """want, got: (code, stdout bytes, stderr bytes); the first is the reference. `known`: the reason a stderr
    difference is expected (exit codes and stdout must still be equal); such a case is counted as `known`."""
    wc, wo, we = want
    gc, go, ge = got
    if codes_only:
        v = "identical" if wc == gc else "DIFF"
        RESULTS.append((group, name, v, "" if v != "DIFF" else f"exit {wc} vs {gc}"))
        return v
    if wc == gc and wo == go and norm_err(we) == norm_err(ge):
        RESULTS.append((group, name, "identical", ""))
        return "identical"
    detail = []
    if wc != gc:
        detail.append(f"exit {wc} vs {gc}")
    if norm_err(we) != norm_err(ge):
        detail.append(f"stderr {norm_err(we)[:300]!r} vs {norm_err(ge)[:300]!r}")
    if wo != go:
        ja, jb = as_json(wo), as_json(go)
        if ja is not None and jb is not None:
            d = []
            jcmp(ja, jb, "$", d)
            if d:
                detail.append("json: " + "; ".join(d[:8]))
        else:
            # first differing line
            la, lb = wo.decode("utf-8", "replace").split("\n"), go.decode("utf-8", "replace").split("\n")
            for i in range(max(len(la), len(lb))):
                x = la[i] if i < len(la) else "<none>"
                y = lb[i] if i < len(lb) else "<none>"
                if x != y:
                    detail.append(f"stdout line {i + 1}: {x[:200]!r} vs {y[:200]!r}")
                    break
    v = "equal" if not detail else "DIFF"
    if v == "DIFF" and known and wc == gc and wo == go:
        v = "known"
        detail.append(f"(known: {known})")
    RESULTS.append((group, name, v, "; ".join(detail)))
    return v


def groups():
    return set(A.only.split(",")) if A.only else {"oracle", "cli", "fail", "model", "sweep", "edge", "big"}


CMD_RE = re.compile(r"^(?:(GOMAXPROCS=\d+)\s+)?(\S+/rhobound)\s+(.*?)\s+>\s+(\S+)\s+2>\s+(\S+)\s+#\s+exit\s+(\d+)")


def oracle_dirs():
    out = []
    for d in sorted(os.listdir(A.oracle)):
        if os.path.isfile(os.path.join(A.oracle, d, "commands.txt")):
            out.append(d)
    return out


def read_or_empty(p):
    try:
        with open(p, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def group_oracle():
    for d in oracle_dirs():
        od = os.path.join(A.oracle, d)
        lines = open(os.path.join(od, "commands.txt")).read().splitlines()
        first_predict = None
        for ln in lines:
            m = CMD_RE.match(ln)
            if not m:
                continue
            env_go, _, argtext, outf, errf, code = m.groups()
            args = shlex.split(argtext)
            outp = os.path.join(od, outf)
            if outf == "predict.gomaxprocs1.json" and not os.path.exists(outp):
                # the oracle checked it byte-identical to predict.json (commands.txt says so) and kept only that one
                outp = os.path.join(od, "predict.json") if int(code) == 0 else outp
            want = (int(code), read_or_empty(outp), read_or_empty(os.path.join(od, errf)))
            env_rb = {"RBFAST_THREADS": "1"} if env_go == "GOMAXPROCS=1" else {}
            env_g = {"GOMAXPROCS": "1"} if env_go == "GOMAXPROCS=1" else {}
            rb = run(A.rbfast, args, env=env_rb)
            g = run(A.go, args, env=env_g)
            label = f"{d} {outf}"
            compare("oracle", label + " rbfast-vs-oracle", want, rb)
            compare("oracle", label + " go-vs-oracle", want, g)
            compare("oracle", label + " rbfast-vs-go", g, rb)
            if outf == "predict.json":
                first_predict = (args, want)
        if first_predict:
            args, want = first_predict
            compare("oracle", f"{d} predict.json rbfast-3-threads", want, run(A.rbfast, args, env={"RBFAST_THREADS": "3"}))
            compare("oracle", f"{d} predict.json rbfast-go-exact-sort", want, run(A.rbfast, args, env={"RBFAST_SORT": "go-exact"}))


def subst(a, case_dir, out_dir):
    a = a.replace("@FIXTURE@", A.fixture)
    a = a.replace("@IN@", os.path.join(case_dir, "in"))
    return a.replace("@OUT@", out_dir)


def tree_bytes(d):
    out = {}
    if not os.path.isdir(d):
        return out
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            out[os.path.relpath(p, d)] = open(p, "rb").read()
    return out


def group_cli():
    cases = sorted(os.listdir(A.cases)) if os.path.isdir(A.cases) else []
    if not cases:
        RESULTS.append(("cli", "recorded cases", "DIFF", f"no recorded cases in {A.cases}"))
        return
    for c in cases:
        cd = os.path.join(A.cases, c)
        doc = json.load(open(os.path.join(cd, "case.json")))
        outs = {}
        res = {}
        for who, binary in (("go", A.go), ("rb", A.rbfast)):
            od = os.path.join(A.work, "cli-out", c, who)
            shutil.rmtree(od, ignore_errors=True)
            args = [subst(a, cd, od) for a in doc["args"]]
            code, so, se = run(binary, args)
            # the --out folder's path is the binary's own: put the placeholder back for the comparison
            so = so.replace(od.encode(), b"@OUT@")
            se = se.replace(od.encode(), b"@OUT@")
            res[who] = (code, so, se)
            outs[who] = tree_bytes(od)
        name = f"{c} {doc['test']} {' '.join(doc['args'])[:120]}"
        codes_only = doc["args"][:1] in ([], ["version"], ["help"], ["--help"], ["-h"], ["-v"], ["--version"]) or \
            (doc["code"] == 2)
        # Go's in-test output has the case's temporary paths replaced by placeholders; put the replay's back
        inproc = (doc["code"], subst(doc["stdout"], cd, "@OUT@").encode(), subst(doc["stderr"], cd, "@OUT@").encode())
        compare("cli", name + " go-binary-vs-go-test", inproc, res["go"], codes_only)
        compare("cli", name + " rbfast-vs-go", res["go"], res["rb"], codes_only)
        if outs["go"] or outs["rb"]:
            same = outs["go"].keys() == outs["rb"].keys() and all(outs["go"][k] == outs["rb"][k] for k in outs["go"])
            if not same:
                # JSON reports may still be equal structurally
                detail = []
                for k in sorted(set(outs["go"]) | set(outs["rb"])):
                    a, b = outs["go"].get(k), outs["rb"].get(k)
                    if a != b:
                        ja, jb = (as_json(a), as_json(b)) if a and b else (None, None)
                        dd = []
                        if ja is not None and jb is not None:
                            jcmp(ja, jb, k, dd)
                            if not dd:
                                continue
                        detail.append(f"{k} differs {dd[:3]}")
                RESULTS.append(("cli", name + " --out files", "equal" if not detail else "DIFF", "; ".join(detail)))
            else:
                RESULTS.append(("cli", name + " --out files", "identical", ""))


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(s)
    return p


def group_fail():
    w = os.path.join(A.work, "fail")
    shutil.rmtree(w, ignore_errors=True)
    fx = A.fixture
    topo2 = write(f"{w}/topo2.json", '{"name":"m","entry":{"a":1},"services":[{"name":"a","s":5,"children":["b"]},{"name":"b","s":10}]}')
    glue = write(f"{w}/glue.json", '{"entry":{"a":1},"services":[{"name":"a","s":0,"glue":2}]}')
    shares = write(f"{w}/shares.json", '{"name":"s","entry":{"a":1},"services":[{"name":"a","s":2,"children":["b"]},{"name":"b","s":10,"routing":"random","shares":[0.7,0.3]}]}')
    bad_syntax = write(f"{w}/bad_syntax.json", '{"services": [}')
    bad_child = write(f"{w}/bad_child.json", '{"entry":{"a":1},"services":[{"name":"a","s":1,"children":["zz"]}]}')
    bad_entry = write(f"{w}/bad_entry.json", '{"entry":{"q":1},"services":[{"name":"a","s":1}]}')
    neg = write(f"{w}/neg.json", '{"entry":{"a":1},"services":[{"name":"a","s":-1}]}')
    cyc = write(f"{w}/cycle.json", '{"entry":{"a":1},"services":[{"name":"a","s":1,"children":["b"]},{"name":"b","s":1,"children":["a"]}]}')
    pooled_w = write(f"{w}/pooledw.json", '{"entry":{"a":1},"services":[{"name":"a","s":1,"workers":2}]}')
    held = write(f"{w}/held.json", '{"entry":{"a":1},"services":[{"name":"a","s":1,"hold":true}]}')
    json_cases = {
        "type_name": '{"services":[{"name":1}]}',
        "type_s": '{"entry":{"a":1},"services":[{"name":"a","s":"x"}]}',
        "type_entry": '{"entry":{"a":"x"},"services":[{"name":"a","s":1}]}',
        "type_servers": '{"entry":{"a":1},"services":[{"name":"a","s":1,"servers":1.5}]}',
        "range_s": '{"entry":{"a":1},"services":[{"name":"a","s":1e999}]}',
        "top_array": '[]',
        "empty": '',
        "trailing": '{"entry":{"a":1},"services":[{"name":"a","s":1}]} x',
        "child_number": '{"entry":{"a":1},"services":[{"name":"a","s":1,"children":[5]}]}',
        "child_obj": '{"entry":{"a":1},"services":[{"name":"a","s":1,"children":[{"name":"b","p":0.5}]},{"name":"b","s":2}]}',
        "dup": '{"entry":{"a":1},"services":[{"name":"a","s":1},{"name":"a","s":2}]}',
        "no_services": '{"name":"x","services":[],"entry":{}}',
        "case_fold": '{"ENTRY":{"a":1},"Services":[{"NAME":"a","S":3}]}',
        "nan_like": '{"entry":{"a":1},"services":[{"name":"a","s":NaN}]}',
        "unicode": '{"entry":{"\u00e9<b>":1},"services":[{"name":"\u00e9<b>","s":1}]}',
    }
    json_files = {k: write(f"{w}/j_{k}.json", v) for k, v in json_cases.items()}
    os.makedirs(f"{w}/empty-capture/traces", exist_ok=True)
    os.makedirs(f"{w}/a-dir.json", exist_ok=True)
    write(f"{w}/broken-line/traces/spans.jsonl", '{"resourceSpans":[{"resource":{}}]}\n{"resourceSpans": [\n')
    write(f"{w}/not-otlp/traces/spans.jsonl", '{"resourceSpans": 5}\n')
    with open(f"{w}/bad-gz.jsonl.gz", "wb") as f:
        f.write(b"\x1f\x8b\x08\x00garbage")
    cases = [
        ([], True), (["frobnicate"], True), (["help"], True), (["version"], True),
        (["predict"], False), (["predict", fx, fx], False), (["predict", "/no/such/capture"], False),
        (["predict", fx, "--max-rho", "0.2"], False), (["predict", fx, "--max-rho", "2"], False),
        (["predict", fx, "--max-rho", "NaN", "--workers", "b=1"], False), (["predict", fx, "--max-rho", "0"], False),
        (["predict", fx, "--max-rho"], False), (["predict", fx, "--patch", "b=+500ms"], False),
        (["predict", fx, "--patch", "nosuch=+1ms"], False), (["predict", fx, "--patch", "b=banana"], False),
        (["predict", fx, "--patch", "b"], False), (["predict", fx, "--patch", "b=NaNms", "--json"], False),
        (["predict", fx, "--patch", "b=Inf%"], False), (["predict", fx, "--patch", "b=-1000ms"], False),
        (["predict", fx, "--patch", "b=-100%", "--json"], False), (["predict", fx, "--patch", ",", "--json"], False),
        (["predict", fx, "--patch", "b=0x1p-2ms", "--json"], False), (["predict", fx, "--patch", "b=1_0%", "--json"], False),
        (["predict", fx, "--kept-share", "NaN"], False), (["predict", fx, "--kept-share", "0"], False),
        (["predict", fx, "--kept-share", "1.5"], False), (["predict", fx, "--kept-share", "0.5", "--json"], False),
        (["predict", fx, "--workers", "b=0"], False), (["predict", fx, "--workers", "b"], False),
        (["predict", fx, "--workers", "nosuch=3", "--json"], False), (["predict", fx, "--workers", "a=1,b=2", "--json"], False),
        (["predict", fx, "--nosuch"], False), (["predict", fx, "-h"], False), (["predict", fx, "--json=maybe"], False),
        (["predict", fx, "--json=false"], False), (["predict", "--json", fx], False), (["predict", "-json", fx, "-plain"], False),
        (["predict", "--", fx, "--json"], False), (["predict", fx, "--json", "--"], False), (["predict", "-", "--json"], False),
        (["predict", f"{w}/empty-capture"], False), (["predict", f"{w}/broken-line"], False),
        (["predict", f"{w}/not-otlp"], False), (["predict", f"{w}/bad-gz.jsonl.gz"], False),
        (["infer"], False), (["infer", "/no/such"], False), (["infer", fx, "--workers", "a=x"], False),
        (["infer", fx, "--workers", "a=3"], False), (["infer", fx, "--kept-share", "0.25"], False),
        (["model"], False), (["model", topo2], False), (["model", topo2, "--rps", "0"], False),
        (["model", topo2, "--rps", "-1"], False), (["model", topo2, "--rps", "Inf"], False),
        (["model", topo2, "--rps", "NaN"], False), (["model", topo2, "--rps", "1e400"], False),
        (["model", topo2, "--rps", "90"], False), (["model", topo2, "--rps", "90", "--max-rho", "0.95"], False),
        (["model", topo2, "--rps", "80", "--patch", "b=+1ms"], False), (["model", topo2, "--rps", "20", "--max-rho", "2"], False),
        (["model", topo2, "--rps", "20", "--workers", "b=2"], False), (["model", topo2, "--rps", "20", "--kept-share", "0.5"], False),
        (["model", topo2, "--rps", "20", "--workers", "b=2", "--kept-share", "0.5"], False),
        (["model", topo2, "--rps", "100000"], False), (["model", topo2, "--rps", "20", "--patch", "a=+1ms,b=-5%", "--json"], False),
        (["model", topo2, "--rps", "20", "--patch", "c=+1ms"], False), (["model", topo2, "--rps", "1e-300", "--json"], False),
        (["model", topo2, "--rps", "0x1p4", "--json"], False),
        (["model", glue, "--rps", "10", "--patch", "a=-150%"], False), (["model", glue, "--rps", "10", "--patch", "a=+50%"], False),
        (["model", shares, "--rps", "60", "--patch", "b=+1ms"], False), (["model", shares, "--rps", "150"], False),
        (["model", "/no/such.json", "--rps", "10"], False), (["model", f"{w}/a-dir.json", "--rps", "10"], False),
        (["model", bad_syntax, "--rps", "10"], False), (["model", bad_child, "--rps", "10"], False),
        (["model", bad_entry, "--rps", "10"], False), (["model", neg, "--rps", "10"], False),
        (["model", cyc, "--rps", "10"], False), (["model", pooled_w, "--rps", "10"], False), (["model", held, "--rps", "10"], False),
    ] + [(["model", f, "--rps", "10", "--json"], False) for f in json_files.values()]
    # No difference is expected on any of these. (compare() can mark a stderr-only difference as `known` with a
    # reason; none is listed now: the topology type-error texts that once differed match Go's since rbfast-math's
    # own topology reader.)
    for args, codes_only in cases:
        name = " ".join(a.replace(w, "W").replace(fx, "FIXTURE") for a in args) or "(no arguments)"
        compare("fail", name, run(A.go, args), run(A.rbfast, args), codes_only)
    # stdout on a full device: the report writers' errors (infer ignores its write error, as Go does)
    for args in (["predict", fx], ["predict", fx, "--json"], ["infer", fx], ["model", topo2, "--rps", "20"],
                 ["model", topo2, "--rps", "20", "--json"]):
        g = run(A.go, args, stdout_path="/dev/full")
        r = run(A.rbfast, args, stdout_path="/dev/full")
        compare("fail", " ".join(a.replace(w, "W").replace(fx, "FIXTURE") for a in args) + " > /dev/full", g, r)
    # --out: both write report.txt and report.json, with the same contents
    for who, binary in (("go", A.go), ("rb", A.rbfast)):
        shutil.rmtree(f"{w}/out-{who}", ignore_errors=True)
    g = run(A.go, ["predict", fx, "--out", f"{w}/out-go/r", "--patch", "b=+1ms"])
    r = run(A.rbfast, ["predict", fx, "--out", f"{w}/out-rb/r", "--patch", "b=+1ms"])
    same = tree_bytes(f"{w}/out-go") == tree_bytes(f"{w}/out-rb") and g[0] == r[0] and g[1] == r[1]
    RESULTS.append(("fail", "predict --out DIR (files and stdout)", "identical" if same else "DIFF", ""))


def patch_of(od):
    for ln in open(os.path.join(od, "commands.txt")):
        m = re.match(r"# patch chosen: (\S+)", ln)
        if m:
            return m.group(1)
    return None


def group_model():
    for d in oracle_dirs():
        od = os.path.join(A.oracle, d)
        topo = os.path.join(od, "infer.json")
        pj = as_json(read_or_empty(os.path.join(od, "predict.json")))
        if not os.path.isfile(topo) or pj is None:
            continue
        rps = pj["external_rps"]
        patch = patch_of(od)
        for f in (1.0, 0.5, 1.3, 3.0):
            r = repr(rps * f)
            for extra in [[], ["--plain"]] + (([["--patch", patch], ["--patch", patch, "--plain"]]) if patch else []):
                for fmt in (["--json"], []):
                    args = ["model", topo, "--rps", r] + extra + fmt
                    name = f"{d} rps={r} {' '.join(extra + fmt)}"
                    compare("model", name, run(A.go, args), run(A.rbfast, args))


def span_count(od):
    try:
        return json.load(open(os.path.join(od, "counters.json")))["spans"]
    except (OSError, ValueError, KeyError):
        return 0


def largest_capture():
    """The oracle capture with the most spans (the largest test-bed capture), by its counters.json."""
    ds = [d for d in oracle_dirs() if span_count(os.path.join(A.oracle, d)) > 0]
    return max(ds, key=lambda d: span_count(os.path.join(A.oracle, d))) if ds else None


def capture_source(d):
    """The capture folder an oracle capture was made from (the `# capture: PATH` line of its commands.txt)."""
    for ln in open(os.path.join(A.oracle, d, "commands.txt")):
        if ln.startswith("# capture: "):
            return ln[len("# capture: "):].strip()
    return None


def sweep_topologies():
    out = []
    names = ["capture-chain", largest_capture(), "sim-row30-fanout-b-default", "sim-row39-uneven-default", "sim-async"]
    for d in names:
        if d is None or not os.path.isfile(os.path.join(A.oracle, d, "predict.json")):
            RESULTS.append(("sweep", f"topology {d}", "DIFF", "not in the oracle"))
            continue
        od = os.path.join(A.oracle, d)
        pj = as_json(read_or_empty(os.path.join(od, "predict.json")))
        rows = pj["services"]
        busiest = pj["busiest_service"]
        internal = [x for x in rows if not x.get("external") and not x.get("stage") and x["name"] != busiest]
        second = max(internal, key=lambda x: x["own_ms"])["name"] if internal else busiest
        out.append((d, os.path.join(od, "infer.json"), pj["external_rps"], busiest, second))
    ex = os.path.join(A.examples, "fanout-topology.json")
    if os.path.isfile(ex):
        doc = json.load(open(ex))
        names = [s["name"] for s in doc["services"]]
        out.append(("examples-fanout", ex, 40.0, names[-1], names[0]))
    return out


def group_sweep():
    for d, topo, rps, busiest, second in sweep_topologies():
        lo, step = rps * 0.5, rps * 0.25
        rspec = f"{lo!r}:{rps * 1.5!r}:{step!r},{rps * 2.5!r}"
        grid = f"{busiest}=0:10:5%;{second}=+0.5ms|+2ms;{busiest}=-5%,{second}=+1ms"
        args = ["sweep", topo, "--rps", rspec, "--patch-grid", grid, "--both"]
        code, so, se = run(A.rbfast, args)
        if code != 0:
            RESULTS.append(("sweep", f"{d} sweep", "DIFF", f"exit {code}: {se[:300]!r}"))
            continue
        lines = [json.loads(x) for x in so.decode().splitlines()]
        c1 = run(A.rbfast, args + ["--threads", "1"])
        RESULTS.append(("sweep", f"{d} sweep at 1 thread vs all", "identical" if c1[1] == so else "DIFF", ""))
        bad = 0
        for ln in lines:
            gargs = ["model", topo, "--rps", repr(ln["rps"]), "--json"]
            if ln["model"] == "basic":
                gargs.append("--plain")
            if ln["patch"] is not None:
                gargs += ["--patch", ln["patch"]]
            gc, go, ge = run(A.go, gargs)
            name = f"{d} rps={ln['rps']!r} {ln['model']} patch={ln['patch']}"
            if ln["status"] != "ok":
                msg = norm_err(ge).strip()
                want = "rhobound: " + ln["message"]
                v = "identical" if gc == 1 and msg == want else "DIFF"
                RESULTS.append(("sweep", name, v, "" if v == "identical" else f"go exit {gc} {msg[:300]!r} vs {want[:300]!r}"))
                bad += v == "DIFF"
                continue
            if gc != 0:
                RESULTS.append(("sweep", name, "DIFF", f"go exit {gc}: {ge[:300]!r}"))
                bad += 1
                continue
            rep = json.loads(go)
            want = {"max_utilization": rep["max_utilization"], "busiest_service": rep["busiest_service"],
                    "services": [{k: s[k] for k in ("name", "utilization", "model_ms", "after_ms", "change_ms", "change_pct") if k in s}
                                 for s in rep["services"]]}
            got = {"max_utilization": ln["max_utilization"], "busiest_service": ln["busiest_service"],
                   "services": [{k: s[k] for k in ("name", "utilization", "model_ms", "after_ms", "change_ms", "change_pct") if k in s}
                                for s in ln["services"]]}
            diffs = []
            jcmp(want, got, "$", diffs)
            exact = json.dumps(want) == json.dumps(got)
            v = "identical" if exact else ("equal" if not diffs else "DIFF")
            RESULTS.append(("sweep", name, v, "; ".join(diffs[:5])))
    # sweep --capture at the observed load: the base line is predict's rows
    for d in ("capture-chain", "sim-row39-uneven-default"):
        od = os.path.join(A.oracle, d)
        cap = os.path.join(A.oracle, "captures", d)
        pj = as_json(read_or_empty(os.path.join(od, "predict.json")))
        code, so, se = run(A.rbfast, ["sweep", cap, "--capture"])
        if code != 0:
            RESULTS.append(("sweep", f"{d} sweep --capture", "DIFF", f"exit {code} {se[:200]!r}"))
            continue
        ln = json.loads(so.decode().splitlines()[0])
        want = [{"name": s["name"], "utilization": s["utilization"], "model_ms": s["model_ms"]} for s in pj["services"]]
        got = [{k: s[k] for k in ("name", "utilization", "model_ms")} for s in ln["services"]]
        RESULTS.append(("sweep", f"{d} sweep --capture base line vs predict.json", "identical" if want == got and
                        ln["max_utilization"] == pj["max_utilization"] else "DIFF", ""))


def bname(a):
    """A readable name for an argument that may be bytes (not UTF-8)."""
    if isinstance(a, bytes):
        return a.decode("utf-8", "backslashreplace")
    return a


def group_edge():
    E = A.edge
    if not E or not os.path.isdir(E):
        RESULTS.append(("edge", "edge inputs", "DIFF", f"no edge inputs at {E!r} (run parity.sh)"))
        return
    short = lambda a: bname(a).replace(E, "E")

    def both(args, env=None, codes_only=False, label=None, first_line=False):
        g, r = run(A.go, args, env=env), run(A.rbfast, args, env=env)
        if first_line:  # the usage text after it is each program's own
            g = (g[0], g[1], g[2].split(b"\n")[0])
            r = (r[0], r[1], r[2].split(b"\n")[0])
        name = label or " ".join(short(a) for a in args)
        if env:
            name = " ".join(f"{k}={bname(v)!r}" for k, v in env.items()) + " " + name
        compare("edge", name, g, r, codes_only)

    # 1. ties on (trace, start): Go's sort order, at any thread count, and Go's serial sort port
    tie_caps = []
    for root in (os.path.join(E, "ties"), A.edge_go):
        if root and os.path.isdir(root):
            tie_caps += [os.path.join(root, d) for d in sorted(os.listdir(root))]
    for cap in tie_caps:
        for cmd in (["predict", cap, "--json"], ["predict", cap], ["infer", cap]):
            g = run(A.go, cmd)
            for env in ({}, {"RBFAST_THREADS": "1"}, {"RBFAST_THREADS": "3"}, {"RBFAST_SORT": "go-exact"}):
                tag = " ".join(f"{k}={v}" for k, v in env.items()) or "default threads"
                compare("edge", f"{' '.join(short(a) for a in cmd)} [{tag}]", g, run(A.rbfast, cmd, env=env))
    # 2. .json streams, names for the tabwriter, misc captures
    for sub in ("json", "names", "misc"):
        root = os.path.join(E, sub)
        for d in sorted(os.listdir(root)):
            cap = os.path.join(root, d)
            for cmd in (["predict", cap, "--json"], ["predict", cap], ["infer", cap]):
                both(cmd)
            both(["predict", cap, "--json"], env={"RBFAST_THREADS": "2"})
    for t in sorted(os.listdir(os.path.join(E, "topo"))):
        tp = os.path.join(E, "topo", t)
        both(["model", tp, "--rps", "50"])
        both(["model", tp, "--rps", "50", "--json"])
    # 3. paths and arguments that are not UTF-8; %q of unusual characters
    nb = os.path.join(os.fsencode(E), b"nonutf8")
    cap = os.path.join(nb, b"cap\xffdir")
    capx = os.path.join(nb, b"capx")
    fx = os.path.join(E, "names", "cjk-nbsp")
    for cmd in (["predict", cap], ["predict", cap, "--json"], ["infer", cap], ["predict", capx, "--json"],
                ["predict", os.path.join(nb, b"no\xffsuch")], ["model", os.path.join(nb, b"no\xffsuch.json"), "--rps", "1"],
                ["predict", A.fixture, "--patch", b"\xff=+1ms"], ["predict", A.fixture, "--patch", "b=+1\u00a0ms"],
                ["predict", A.fixture, "--patch", "a\u0378b=+1ms"], ["predict", A.fixture, "--patch", "b=\u0600"],
                ["predict", A.fixture, "--workers", "a\u00a0=x"], ["predict", A.fixture, "--workers", "a\u0085=x"],
                ["predict", A.fixture, "--workers", "a\u00ad=x"], ["predict", A.fixture, "--workers", b"\xff=x"],
                ["predict", A.fixture, "--workers", b"\xff=2", "--json"], ["predict", A.fixture, "--workers", "\U0010ffff=y"],
                ["predict", fx, "--patch", "\u65e5\u672c=+1ms", "--json"], ["predict", fx, "--patch", "b\u00a0b=+5%"]):
        both(cmd)
    for e in (b"\xff", b"ri\xffse", b"\xc3", b"Rise", "\u00e9\u200b".encode(), b"rise", b"fifo", b"", b"\x7f"):
        both(["predict", A.fixture, "--json"], env={"RHOBOUND_ESTIMATOR": e})
    for c in (b"\xff", "fr\u00a0ob".encode(), b"pre\x00dict"[:3] + b"x"):
        both([c], first_line=True)
    # 4. --out: an existing file, below a file, a read-only folder, a symlink loop (the error names the path Go's
    #    os.MkdirAll names); and a new folder whose name is not UTF-8 (each binary its own, the files compared)
    od = os.path.join(E, "out")
    for o in ("afile", "afile/sub", "afile/sub/deeper", "ro/x", "ro/x/y", "loop1", "loop1/x", "afile/"):
        p = os.path.join(od, o)
        both(["predict", A.fixture, "--out", p])
        both(["model", os.path.join(E, "topo", "two.json"), "--rps", "20", "--out", p, "--json"])
    trees = {}
    for who, binary in (("go", A.go), ("rb", A.rbfast)):
        base = os.path.join(os.fsencode(A.work), b"edge-out", who.encode())
        shutil.rmtree(base, ignore_errors=True)
        p = os.path.join(base, b"new\xffdir", b"sub//")
        code, so, se = run(binary, ["predict", A.fixture, "--out", p, "--patch", "b=+1ms"])
        trees[who] = (code, so, se.replace(base, b"@BASE@"), tree_bytes(base))
    same = trees["go"][:3] == trees["rb"][:3] and trees["go"][3].keys() == trees["rb"][3].keys() and \
        all(trees["go"][3][k] == trees["rb"][3][k] for k in trees["go"][3])
    RESULTS.append(("edge", "predict --out NEW\\xffDIR/sub// (files, stdout, stderr)", "identical" if same else "DIFF",
                    "" if same else f"{trees['go'][:3]!r} vs {trees['rb'][:3]!r}"))
    # 5. sweep's order of checks: a refused (or failing) base comes before a change that does not parse; the
    #    wording at a capture's observed load is predict's
    two = os.path.join(E, "topo", "two.json")
    for rps, extra in (("95", []), ("50", ["--max-rho", "0.3"]), ("20", [])):
        code, so, se = run(A.rbfast, ["sweep", two, "--rps", rps, "--patch-grid", "zz=+1ms;a=NaN%;a=banana;b=+1ms"] + extra)
        for ln in so.decode().splitlines():
            ln = json.loads(ln)
            gargs = ["model", two, "--rps", rps, "--json"] + extra + (["--patch", ln["patch"]] if ln["patch"] else [])
            gc, go, ge = run(A.go, gargs)
            want = "rhobound: " + ln["message"] if ln["status"] != "ok" else ""
            ok = (gc == 1 and norm_err(ge).strip() == want) if ln["status"] != "ok" else gc == 0
            RESULTS.append(("edge", f"sweep two.json rps={rps} {' '.join(extra)} patch={ln['patch']}", "identical" if ok else "DIFF",
                            "" if ok else f"go exit {gc} {norm_err(ge)[:300]!r} vs {ln}"))
    for d in ("sim-row39-uneven-default", "sim-async", "capture-chain"):
        capd = os.path.join(A.oracle, "captures", d)
        if not os.path.isdir(capd):
            continue
        code, so, se = run(A.rbfast, ["sweep", capd, "--capture", "--max-rho", "0.3"])
        ln = json.loads(so.decode().splitlines()[0])
        gc, go, ge = run(A.go, ["predict", capd, "--max-rho", "0.3"])
        ok = (ln["status"] == "refused" and gc == 1 and norm_err(ge).strip() == "rhobound: " + ln["message"]) or \
             (ln["status"] == "ok" and gc == 0)
        RESULTS.append(("edge", f"sweep {d} --capture --max-rho 0.3 vs predict", "identical" if ok else "DIFF",
                        "" if ok else f"{norm_err(ge)[:200]!r} vs {ln.get('message', '')[:200]!r}"))


def group_big():
    bench = os.path.join(A.oracle, "bench")
    names = sorted(os.listdir(bench)) if os.path.isdir(bench) else []
    for name in names:
        cap = os.path.join(bench, name)
        if not os.path.isdir(os.path.join(cap, "traces")):
            continue
        args = ["predict", cap, "--json"]
        t0 = time.time()
        rb = run(A.rbfast, args)
        t1 = time.time()
        g = run(A.go, args)
        t2 = time.time()
        compare("big", f"{name} predict --json rbfast-vs-go (rbfast {t1 - t0:.1f} s, go {t2 - t1:.1f} s)", g, rb)
        ref = os.path.join(A.oracle, "bench-out", name, "predict.json")
        if os.path.isfile(ref):
            compare("big", f"{name} predict --json rbfast-vs-oracle", (0, read_or_empty(ref), read_or_empty(ref[:-4] + "stderr")), rb)
    # the same bytes as `.json` streams (a file of one value per line is a stream of values): links named *.json
    # to the largest oracle capture's .jsonl files, and *.json.gz to each gzipped bench capture's .jsonl.gz files
    links = os.path.join(A.work, "json-links")
    shutil.rmtree(links, ignore_errors=True)
    streams = []
    big = largest_capture()
    src = capture_source(big) if big else None
    if src and os.path.isdir(os.path.join(src, "traces")):
        t = os.path.join(src, "traces")
        fs = sorted(f for f in os.listdir(t) if f.endswith(".jsonl"))
        if fs:
            streams.append((big + "-json", [(os.path.join(t, f), f[:-1]) for f in fs]))
    for name in names:
        t = os.path.join(bench, name, "traces")
        fs = sorted(os.listdir(t)) if os.path.isdir(t) else []
        if fs and all(f.endswith(".jsonl.gz") for f in fs):
            streams.append((name + "-json-gz", [(os.path.join(t, f), f[:-len(".jsonl.gz")] + ".json.gz") for f in fs]))
    for name, srcs in streams:
        if not all(os.path.isfile(s) for s, _ in srcs):
            continue
        d = os.path.join(links, name, "traces")
        os.makedirs(d)
        for s_, n in srcs:
            os.symlink(s_, os.path.join(d, n))
        args = ["predict", os.path.join(links, name), "--json"]
        t0 = time.time()
        rb = run(A.rbfast, args)
        t1 = time.time()
        g = run(A.go, args)
        t2 = time.time()
        compare("big", f"{name} predict --json rbfast-vs-go (rbfast {t1 - t0:.1f} s, go {t2 - t1:.1f} s)", g, rb)


def main():
    t0 = time.time()
    gs = groups()
    for g, f in (("oracle", group_oracle), ("cli", group_cli), ("fail", group_fail), ("model", group_model),
                 ("sweep", group_sweep), ("edge", group_edge), ("big", group_big)):
        if g in gs and not (g == "big" and A.quick):
            t = time.time()
            f()
            print(f"group {g}: done in {time.time() - t:.0f} s", flush=True)
    print()
    summary = {}
    for g, name, v, detail in RESULTS:
        summary.setdefault(g, {}).setdefault(v, 0)
        summary[g][v] += 1
        if v in ("DIFF", "known"):
            print(f"{v} [{g}] {name}: {detail}")
    print()
    print(f"{'group':8} {'identical':>10} {'equal':>8} {'known':>6} {'DIFF':>6}")
    for g in ("oracle", "cli", "fail", "model", "sweep", "edge", "big"):
        if g in summary:
            s = summary[g]
            print(f"{g:8} {s.get('identical', 0):10d} {s.get('equal', 0):8d} {s.get('known', 0):6d} {s.get('DIFF', 0):6d}")
    print(f"largest relative difference of any number compared: {MAXREL['value']:.3g} {MAXREL['where']}")
    print(f"total {len(RESULTS)} comparisons in {time.time() - t0:.0f} s")
    with open(os.path.join(A.work, "results.json"), "w") as f:
        json.dump([{"group": g, "name": n, "verdict": v, "detail": d} for g, n, v, d in RESULTS], f, indent=1)
    sys.exit(1 if any(v == "DIFF" for _, _, v, _ in RESULTS) else 0)


main()
