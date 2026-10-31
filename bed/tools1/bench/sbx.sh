#!/bin/bash
# sbx.sh MODE TREE TASKDIR OUTDIR   the bench sandbox (SPEC2 3, S1-S3), on rbd-tools1 as rbd (docker group). Go code a model
# wrote is compiled and run ONLY here: in docker, no network, read-only root, no capabilities, as 65532:65532.
#   MODE tests   go test -v of the task's package(s) with TREE's own *_test.go (the visible tests)
#        hidden  the same after TASKDIR/hidden/*_test.go (and hidden/testdata/**) are copied into the first writable package
#        bench   (both trees get TASKDIR/hidden/*bench*_test.go only, when the task has them)
#        bench   the task's microbenchmarks: the baseline tree (SBX_BASE_TREE [$RBD_HOME/src/main]) and TREE each compiled
#                once ('go test -c'), then 5 rounds of (baseline, candidate; the candidate first in even rounds) of
#                '-test.run ^$ -test.bench ^(NAMES)$ -test.count 1 -test.benchmem' in one container: 'go test -run ^$
#                -bench NAMES -count 5 -benchmem' on both trees, interleaved. Strictly one bench at a time on this machine:
#                flock SBX_LOCK (S1's run_bench and S3's bench of every funnel share it)
#   TREE     a folder holding kshop/app (the candidate). TASKDIR  tools1/bench/tasks/<id> (task.json: writable, bench, base,
#            optional race: true -> go test -race with cgo, tests/hidden only). OUTDIR  new or empty; gets result.json,
#            output.txt (the raw go output) and box/ (scratch, removed at the end unless SBX_KEEP=1)
# What goes into the container: a scratch module per tree with ONLY go.mod's module and go lines (no require: package hot is
# stdlib only, so GOFLAGS=-mod=mod GOPROXY=off never needs a dependency) and the task's writable package folders (*.go files
# and testdata/, regular files only). Mounted read-only at /w/{base,cand}; /out (bench only) holds the two test binaries.
# docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,nosuid,nodev,size=1536m --cap-drop ALL
#   --security-opt no-new-privileges --pids-limit 512 --memory 2g --cpus 2 --user 65532:65532 (exec on /tmp: go test runs
#   the binary it builds there; docker's tmpfs default is noexec). GOCACHE, GOTMPDIR, GOPATH and HOME under /tmp.
# Image: the golang builder BY DIGEST: the FROM line of SBX_DOCKERFILE [/opt/rbd/kshop/Dockerfile] for main (FROM ${ARG}: that
# ARG's default); a task with
# "base": KEY uses SBX_BASES [/opt/rbd/kshop/bases.json] [KEY] (a string, or an object with image|builder|ref|from) for
# the candidate (and for tests/hidden); the baseline of a bench always builds with main's image.
# result.json {"mode","ok","passed","failed","output_tail","bench": {"<name>": {"base_ns","cand_ns","delta_ms","spread_ms",
#   "base_allocs","cand_allocs"}}}: medians of the 5 rounds; delta_ms = (cand - base) / 1e6 per call; spread_ms = half the
#   range of the 5 paired (cand - base) differences. tests/hidden: passed/failed count every '--- PASS/FAIL' line (subtests
#   too); ok = go test exit 0 and no failure (and at least one test in hidden mode). bench: ok = 5 samples of every name.
# Last stdout line {"step":"sbx","ok",...}. Exit 0 ok, 1 ran but not ok (or the sandbox failed: result.json says why), 2 usage.
# Env: SBX_DOCKER [docker] (tests: a stub), SBX_BASE_TREE, SBX_LOCK [$RBD_HOME/bench/sbx-bench.lock], SBX_DOCKERFILE, SBX_BASES,
#      SBX_TIMEOUT [1800 s per container], SBX_ROUNDS [5], SBX_KEEP, RBD_HOME [/var/lib/rbd]
# shellcheck disable=SC2016  # the single-quoted scripts expand in the container's sh
set -euo pipefail
die() { echo "sbx: error: $*" >&2; exit 2; }
[[ $# -eq 4 ]] || die "usage: sbx.sh tests|hidden|bench TREE TASKDIR OUTDIR"
MODE=$1 TREE=$2 TASKDIR=$3 OUTDIR=$4
[[ $MODE =~ ^(tests|hidden|bench)$ ]] || die "MODE must be tests, hidden or bench, not $MODE"
[[ -d $TREE/kshop/app && ! -L $TREE/kshop/app ]] || die "no $TREE/kshop/app"
[[ -r $TASKDIR/task.json ]] || die "no $TASKDIR/task.json"
RBD_HOME=${RBD_HOME:-/var/lib/rbd}
DOCKER=${SBX_DOCKER:-docker}
BASE_TREE=${SBX_BASE_TREE:-$RBD_HOME/src/main}
DOCKERFILE=${SBX_DOCKERFILE:-/opt/rbd/kshop/Dockerfile}
BASES=${SBX_BASES:-/opt/rbd/kshop/bases.json}
TMO=${SBX_TIMEOUT:-1800}
ROUNDS=${SBX_ROUNDS:-5}
[[ $ROUNDS =~ ^[1-9]$ ]] || die "SBX_ROUNDS must be 1..9"
mkdir -p "$OUTDIR"
[[ -z $(ls -A "$OUTDIR") ]] || die "$OUTDIR is not empty"
OUTDIR=$(cd "$OUTDIR" && pwd -P)
BOX=$OUTDIR/box
mkdir -p "$BOX"
[[ ${SBX_KEEP:-0} == 1 ]] || trap 'rm -rf "$BOX"' EXIT

# the task (writable folders -> packages, bench names, base, race), the images, and the scratch modules
cfg=$(python3 -I - "$TASKDIR/task.json" "$DOCKERFILE" "$BASES" << 'EOF'
import json, re, sys
task, dockerfile, bases = sys.argv[1:4]
def no(m):
    sys.exit("sbx: error: " + m)
t = json.load(open(task))
pinned = re.compile(r"[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9_.-]{1,128})?@sha256:[0-9a-f]{64}")
pk = []
for w in t.get("writable") or []:
    if not isinstance(w, str) or not re.fullmatch(r"kshop/app/(?:[A-Za-z0-9_][A-Za-z0-9_.-]*/)*[A-Za-z0-9_][A-Za-z0-9_.-]*/", w) \
            or "/../" in "/" + w or "/./" in "/" + w:
        no("task.json writable %r: a folder under kshop/app/ ending in /" % (w,))
    pk.append(w[len("kshop/app/"):].rstrip("/"))
if not pk:
    no("task.json lists no writable folder")
names = t.get("bench") or []
if not all(isinstance(n, str) and re.fullmatch(r"Benchmark[A-Za-z0-9_]{0,64}", n) for n in names):
    no("task.json bench %r: names like BenchmarkRank" % (names,))
main_img = None
args = {}
for line in open(dockerfile, encoding="utf-8"):
    a = re.match(r"\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)=(\S+)\s*$", line)
    if a:
        args[a.group(1)] = a.group(2)
    m = re.match(r"\s*FROM\s+(?:--platform=\S+\s+)?(\S+)", line, re.I)
    if m:
        main_img = m.group(1)
        v = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", main_img)
        if v:   # FROM ${GO_IMAGE}: the ARG's default (SPEC2 4: the kit's Dockerfile, today's builder)
            main_img = args.get(v.group(1))
        break
if not main_img or not pinned.fullmatch(main_img):
    no("the FROM line of %s is not an image by digest: %r" % (dockerfile, main_img))
cand_img, base = main_img, t.get("base")
if base is not None:
    if not isinstance(base, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,31}", base):
        no("task.json base %r" % (base,))
    try:
        b = json.load(open(bases))
    except OSError:
        no("task.json base %r but no %s" % (base, bases))
    v = b.get(base) if isinstance(b, dict) else None
    if isinstance(v, dict):
        v = next((v[k] for k in ("image", "builder", "ref", "from") if isinstance(v.get(k), str)), None)
    if not isinstance(v, str) or not pinned.fullmatch(v):
        no("bases.json has no image by digest for %r" % base)
    cand_img = v
race = t.get("race") is True
print(json.dumps({"pkgs": pk, "bench": names, "main_img": main_img, "cand_img": cand_img, "race": race}))
EOF
) || exit 2
get() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])[sys.argv[2]]; print(" ".join(v) if isinstance(v,list) else str(v).lower() if isinstance(v,bool) else v)' "$cfg" "$1"; }
PKGS=$(get pkgs) BENCH=$(get bench) MAIN_IMG=$(get main_img) CAND_IMG=$(get cand_img) RACE=$(get race)
read -r PKG1 _ <<< "$PKGS"

stage() {   # stage SRC_TREE DST [HIDDEN_DIR]: go.mod (module + go lines), the writable packages, the hidden tests
  python3 -I - "$1/kshop/app" "$2" "$PKGS" "${3:-}" << 'EOF'
import os, re, shutil, stat, sys
app, dst, pkgs, hidden = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4]
def no(m):
    sys.exit("sbx: error: " + m)
mod = open(os.path.join(app, "go.mod"), encoding="utf-8").read()
m, g = re.search(r"^module\s+(\S+)\s*$", mod, re.M), re.search(r"^go\s+([0-9][0-9.]*)\s*$", mod, re.M)
if not m or not g:
    no("%s/go.mod has no module or go line" % app)
os.makedirs(dst)
open(os.path.join(dst, "go.mod"), "w").write("module %s\n\ngo %s\n" % (m.group(1), g.group(1)))
def plain(p):
    st = os.lstat(p)
    return stat.S_ISREG(st.st_mode)
def copy_testdata(src, out):
    for d, dirs, names in os.walk(src, followlinks=False):
        dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(d, x))]
        for n in names:
            p = os.path.join(d, n)
            if plain(p):
                q = os.path.join(out, os.path.relpath(p, src))
                os.makedirs(os.path.dirname(q), exist_ok=True)
                shutil.copyfile(p, q)
for pk in pkgs:
    src, out = os.path.join(app, pk), os.path.join(dst, pk)
    os.makedirs(out, exist_ok=True)
    if os.path.isdir(src) and not os.path.islink(src):
        for n in sorted(os.listdir(src)):
            p = os.path.join(src, n)
            if n.endswith(".go") and plain(p):
                shutil.copyfile(p, os.path.join(out, n))
        if os.path.isdir(os.path.join(src, "testdata")) and not os.path.islink(os.path.join(src, "testdata")):
            copy_testdata(os.path.join(src, "testdata"), os.path.join(out, "testdata"))
if hidden:
    out = os.path.join(dst, pkgs[0])
    got = 0
    for n in sorted(os.listdir(hidden)):
        p = os.path.join(hidden, n)
        if n.endswith("_test.go") and plain(p):
            shutil.copyfile(p, os.path.join(out, n)); got += 1
    if os.path.isdir(os.path.join(hidden, "testdata")):
        copy_testdata(os.path.join(hidden, "testdata"), os.path.join(out, "testdata"))
    if not got:
        no("no *_test.go in %s" % hidden)
EOF
}

HID=""
if [[ $MODE == hidden ]]; then
  HID=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hidden") or "hidden/")' "$TASKDIR/task.json")
  [[ $HID =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/?$ ]] || die "task.json hidden $HID: a folder of TASKDIR"
  HID=$TASKDIR/${HID%/}
  [[ -d $HID ]] || die "no hidden tests at $HID"
fi
if [[ $MODE == bench ]]; then   # the task's benchmarks (hidden/*bench*_test.go, self-contained) go into BOTH trees; no other
  # hidden test file, so a candidate that breaks the API never shows hidden test code to the model through run_bench
  HID=$BOX/benchonly; mkdir -p "$HID"
  for f in "$TASKDIR"/hidden/*bench*_test.go; do [[ -f $f ]] && cp "$f" "$HID/"; done
  compgen -G "$HID/*_test.go" > /dev/null || HID=""   # stand-in tasks keep their benchmarks in the tree's own tests
fi
stage "$TREE" "$BOX/w/cand" "$HID" || die "cannot stage the candidate"
if [[ $MODE == bench ]]; then
  [[ -n $BENCH ]] || die "task.json lists no bench"
  [[ -d $BASE_TREE/kshop/app ]] || die "no baseline tree $BASE_TREE/kshop/app (SBX_BASE_TREE)"
  stage "$BASE_TREE" "$BOX/w/base" "$HID" || die "cannot stage the baseline"
  mkdir -p "$BOX/out"; chmod 0777 "$BOX/out"   # the container's user (65532) writes the two test binaries here
fi
chmod -R a+rX "$BOX/w"

TMPFS=/tmp:rw,exec,nosuid,nodev,size=1536m
ISO=(--rm --network none --read-only --tmpfs "$TMPFS" --cap-drop ALL
  --security-opt no-new-privileges --pids-limit 512 --memory 2g --cpus 2 --user 65532:65532)
GOENV=(-e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOTMPDIR=/tmp -e GOPATH=/tmp/gopath -e GOMODCACHE=/tmp/gopath/pkg/mod
  -e "GOFLAGS=-mod=mod -buildvcs=false" -e GOPROXY=off -e GOTOOLCHAIN=local -e GOTELEMETRY=off)
box() {   # box STEP IMAGE SCRIPT [extra docker args]: one container; its stdout+stderr appended to output.txt
  local step=$1 img=$2 script=$3; shift 3
  local name rc=0
  name=sbx-$step-$$-$RANDOM
  timeout --signal=KILL "$TMO" "$DOCKER" run --name "$name" "${ISO[@]}" "${GOENV[@]}" -e "SBX_STEP=$step" -e "SBX_MODE=$MODE" \
    -v "$BOX/w:/w:ro" "$@" "$img" sh -c "$script" >> "$OUTDIR/output.txt" 2>&1 || rc=$?
  if (( rc == 137 )); then "$DOCKER" rm -f "$name" > /dev/null 2>&1 || true; fi
  return "$rc"
}

: > "$OUTDIR/output.txt"
rc=0
if [[ $MODE != bench ]]; then
  cgo=0 race=""
  [[ $RACE != true ]] || cgo=1 race=-race
  pk=""
  for p in $PKGS; do pk="$pk ./$p/"; done
  box test "$CAND_IMG" 'cd /w/cand && exec go test -v -count=1 -timeout 600s $SBX_RACE $SBX_PKGS' \
    -e "CGO_ENABLED=$cgo" -e "SBX_RACE=$race" -e "SBX_PKGS=$pk" || rc=$?
else
  LOCK=${SBX_LOCK:-$RBD_HOME/bench/sbx-bench.lock}
  mkdir -p "$(dirname "$LOCK")"
  exec 8>> "$LOCK"
  flock -w 7200 8 || die "the bench lock $LOCK is held for 2 h"
  echo "== sbx lock $(date +%s.%N) taken" >> "$OUTDIR/output.txt"
  re="^($(tr ' ' '|' <<< "$BENCH"))\$"
  benv=(-e CGO_ENABLED=0 -e "SBX_PKG=./$PKG1/" -e "SBX_PKGDIR=$PKG1" -e "SBX_BENCH=$re" -e "SBX_ROUNDS=$ROUNDS" -v "$BOX/out:/out")
  build_one='cd /w/$1 && go test -c -o /out/$1.test $SBX_PKG'
  if [[ $CAND_IMG == "$MAIN_IMG" ]]; then
    box build "$MAIN_IMG" "set -e; for t in base cand; do (set -- \$t; $build_one); done" "${benv[@]}" || rc=$?
  else
    box build "$MAIN_IMG" "set -e; set -- base; $build_one" "${benv[@]}" || rc=$?
    (( rc != 0 )) || box build "$CAND_IMG" "set -e; set -- cand; $build_one" "${benv[@]}" || rc=$?
  fi
  if (( rc == 0 )); then
    box run "$CAND_IMG" 'i=1; while [ $i -le $SBX_ROUNDS ]; do o="base cand"; [ $((i % 2)) -eq 1 ] || o="cand base"; for t in $o; do echo "== sbx $t $i";
      (cd /w/$t/$SBX_PKGDIR && /out/$t.test -test.run "^$" -test.bench "$SBX_BENCH" -test.count 1 -test.benchmem) || exit 1;
      done; i=$((i+1)); done' "${benv[@]}" || rc=$?
  fi
  echo "== sbx lock $(date +%s.%N) released" >> "$OUTDIR/output.txt"
  exec 8>&-
fi

python3 -I - "$MODE" "$rc" "$OUTDIR" "$BENCH" "$ROUNDS" << 'EOF'
import json, re, statistics, sys
mode, rc, out, names, rounds = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4].split(), int(sys.argv[5])
text = open(out + "/output.txt", encoding="utf-8", errors="replace").read()
res = {"mode": mode, "ok": False, "passed": 0, "failed": 0, "output_tail": "", "bench": {}}
if mode != "bench":
    res["passed"] = len(re.findall(r"^\s*--- PASS: ", text, re.M))
    res["failed"] = len(re.findall(r"^\s*--- FAIL: ", text, re.M))
    res["ok"] = rc == 0 and res["failed"] == 0 and (res["passed"] > 0 or mode == "tests")
else:
    arm, rnd, s = None, 0, {}
    line_re = re.compile(r"^(Benchmark[A-Za-z0-9_]+?)(?:-\d+)?\s+\d+\s+([0-9.]+) ns/op(?:\s+[0-9.]+ B/op)?(?:\s+([0-9]+) allocs/op)?")
    for line in text.splitlines():
        m = re.match(r"^== sbx (base|cand) (\d+)$", line)
        if m:
            arm, rnd = m.group(1), int(m.group(2))
            continue
        m = line_re.match(line)
        if m and arm and m.group(1) in names:
            s.setdefault(m.group(1), {}).setdefault(arm, {})[rnd] = (float(m.group(2)), int(m.group(3) or 0))
    complete = rc == 0
    for n in names:
        b, c = s.get(n, {}).get("base", {}), s.get(n, {}).get("cand", {})
        pairs = [(b[i], c[i]) for i in sorted(set(b) & set(c))]
        if len(pairs) < rounds:
            complete = False
            continue
        d = [(y[0] - x[0]) for x, y in pairs]
        bn, cn = statistics.median(x[0] for x, _ in pairs), statistics.median(y[0] for _, y in pairs)
        res["bench"][n] = {"base_ns": bn, "cand_ns": cn, "delta_ms": round((cn - bn) / 1e6, 6),
                           "spread_ms": round((max(d) - min(d)) / 2e6, 6),
                           "base_allocs": int(statistics.median(x[1] for x, _ in pairs)),
                           "cand_allocs": int(statistics.median(y[1] for _, y in pairs))}
    res["ok"] = complete and len(res["bench"]) == len(names)
lines = [ln for ln in text.splitlines() if not ln.startswith("== sbx lock")]
res["output_tail"] = "\n".join(lines)[-3000:]
if rc and not res["ok"]:
    res["output_tail"] = (res["output_tail"] + "\n(sandbox exit %d%s)" % (rc, ": killed (timeout or memory)" if rc == 137 else ""))[-3000:]
json.dump(res, open(out + "/result.json", "w"), indent=1)
print(json.dumps({"step": "sbx", "ok": res["ok"], "mode": mode, "passed": res["passed"], "failed": res["failed"],
                  "bench": {k: v["delta_ms"] for k, v in res["bench"].items()}}))
sys.exit(0 if res["ok"] else 1)
EOF
