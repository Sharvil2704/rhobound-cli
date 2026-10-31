#!/usr/bin/env bash
# t_tasks.sh [--quick]   offline tests of the rbd-bench tasks (SPEC2 section 2: tools1/bench/tasks/<id>/) and kshop-hot.
#   static (always): every task.json has the shared shape (id = folder, services from repo/kshop/spec.json, base null or a
#     key of tools1/kshop/bases.json, refs' patches exist), prompt = prompt.md, hidden/*_test.go are package hot_test and
#     define every listed benchmark and test, no hidden file or oracle in repo/, every patch touches only
#     kshop/app/internal/hot/ and applies to repo/ (git apply --check), the oracle reproduces the committed goldens
#     (gen.sh --check), shellcheck.
#   proof (unless --quick; Go only through capped.sh, 2 GB, GOMAXPROCS=2): on a scratch copy of repo/kshop/app per tree,
#     today's code passes every PASS_TO_PASS test and fails every FAIL_TO_PASS test; each reference patch behaves as
#     its kind says (good/slow/latency-bad: all hidden tests pass; wrong: some fail), with -race where task.json says
#     race; microbenchmarks: T1 good >= 3x faster than today, slow faster than today but >= 10x slower than good,
#     latency-bad >= 1.3x slower than today; T3 latency-bad >= 3x slower (Rank), good within 1.5x; T2 every ref far
#     below a millisecond (the decoy). Prints the measured ns/op.
# Scratch: $SCRATCH (default $HOME/rbd-dev/tmp/kshop-hot)/t_tasks, removed unless KEEP=1. Exit 0 = all passed.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/../../.." && pwd)
TASKS=$KIT/tools1/bench/tasks
GO=${GO:-$(command -v go)}
CAPPED=${CAPPED:-$HOME/rbd-dev/capped.sh}
SCR=${SCRATCH:-$HOME/rbd-dev/tmp/kshop-hot}/t_tasks
QUICK=0
[[ ${1:-} == --quick ]] && QUICK=1
PASS=0 FAILS=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
rm -rf "$SCR"
mkdir -p "$SCR"

echo "== static"
check "shellcheck t_tasks.sh, gen.sh" shellcheck -x "$HERE/t_tasks.sh" "$KIT/tools1/bench/oracle/gen.sh"
check "task.json shape, prompts, hidden files, refs" python3 -I - "$KIT" << 'PY'
import json, pathlib, re, sys
kit = pathlib.Path(sys.argv[1]); tasks = kit / "tools1/bench/tasks"
svcs = set(json.loads((kit / "repo/kshop/spec.json").read_text())["services"])
bases = json.loads((kit / "tools1/kshop/bases.json").read_text())
keys = ["id", "category", "prompt", "services", "writable", "hidden", "bench", "refs", "k", "base", "visits_per_entry"]
bad = []
ids = sorted(p.name for p in tasks.iterdir() if p.is_dir())
if ids != ["T1-rank", "T2-round", "T3-fold", "T4-base"]:
    bad.append(f"task folders {ids}")
for tid in ids:
    d = json.loads((tasks / tid / "task.json").read_text("utf-8"))
    miss = [k for k in keys if k not in d]
    hidden = "".join(p.read_text("utf-8") for p in sorted((tasks / tid / "hidden").glob("*_test.go")))
    checks = {
        "keys": not miss, "id": d.get("id") == tid, "prompt = prompt.md": d.get("prompt") == (tasks / tid / "prompt.md").read_text("utf-8"),
        "services": 1 <= len(d["services"]) <= 3 and set(d["services"]) <= svcs,
        "writable": d["writable"] in ([], ["kshop/app/internal/hot/"]), "hidden": d["hidden"] == "hidden/",
        "k": isinstance(d["k"], int) and d["k"] >= 1, "base": d["base"] is None or d["base"] in bases,
        "visits": set(d["visits_per_entry"]) == {"storefront", "checkout"},
        "refs": all(r["kind"] in ("good", "slow", "latency-bad", "wrong") and (tasks / tid / r["patch"]).is_file()
                    and r["patch"] == f"refs/{r['name']}.patch" for r in d["refs"]),
        "package hot_test": all(p.read_text("utf-8").split("package ", 1)[1].startswith("hot_test\n")
                                for p in (tasks / tid / "hidden").glob("*_test.go")),
        "bench funcs": all(re.search(rf"^func {b}\(b \*testing\.B\)", hidden, re.M) for b in d["bench"]),
        "tests listed exist": all(re.search(rf"^func {t}\(t \*testing\.T\)", hidden, re.M)
                                  for t in d.get("fail_to_pass", []) + d.get("pass_to_pass", [])),
    }
    bad += [f"{tid}: {k}" for k, v in checks.items() if not v]
t4 = json.loads((tasks / "T4-base/task.json").read_text())
if not (t4["base"] == "go127" and t4["refs"] == []):
    bad.append("T4-base: base go127, no code patch")
repo_hidden = [str(p) for p in (kit / "repo").rglob("*") if re.search(r"hidden|oracle", p.name)]
if repo_hidden:
    bad.append(f"hidden/oracle files in repo/: {repo_hidden}")
for p in tasks.glob("*/refs/*.patch"):
    paths = re.findall(r"^(?:---|\+\+\+) [ab]/(\S+)", p.read_text("utf-8"), re.M)
    if not paths or any(not x.startswith("kshop/app/internal/hot/") for x in paths):
        bad.append(f"{p.name}: paths {paths}")
if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
mkdir -p "$SCR/applychk"
cp -r "$KIT/repo/kshop" "$SCR/applychk/"
cp -r "$KIT/tools1/bench/base/kshop/." "$SCR/applychk/kshop/"   # the code the tasks were written against
for p in "$TASKS"/*/refs/*.patch; do
  check "$(basename "$(dirname "$(dirname "$p")")")/$(basename "$p") applies to repo/" bash -c "cd '$SCR/applychk' && git apply --check '$p'"
done
check "the oracle reproduces the committed goldens (gen.sh --check)" bash -c "SCRATCH='$SCR' bash '$KIT/tools1/bench/oracle/gen.sh' --check > '$SCR/gen.log' 2>&1 || { cat '$SCR/gen.log'; exit 1; }"

if ((QUICK)); then
  echo "== t_tasks: $PASS passed, $FAILS failed (--quick: no proof)"
  [[ ${KEEP:-0} == 1 ]] || rm -rf "$SCR"
  [[ $FAILS -eq 0 ]]
  exit
fi

gorun() { # gorun DIR ARGS...: go in DIR/kshop/app under capped.sh
  local d=$1; shift
  (cd "$d/kshop/app" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local GOTMPDIR=${GOTMPDIR:-$HOME/rbd-dev/tmp} \
    RB_MEM_MAX=2G GOMAXPROCS=2 bash "$CAPPED" "$GO" "$@")
}
tree() { # tree TASK REF: a scratch copy of repo/kshop with REF's patch (REF=base: none) and TASK's hidden tests
  local d=$SCR/$1-$2
  rm -rf "$d"; mkdir -p "$d"
  cp -r "$KIT/repo/kshop" "$d/"
  cp -r "$KIT/tools1/bench/base/kshop/." "$d/kshop/"
  if [[ $2 != base ]]; then (cd "$d" && git apply "$TASKS/$1/refs/$2.patch") || return 1; fi
  cp "$TASKS/$1"/hidden/*_test.go "$d/kshop/app/internal/hot/"
  echo "$d"
}
jq_list() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(d[sys.argv[2]]) if isinstance(d[sys.argv[2]], list) else d[sys.argv[2]])' "$TASKS/$1/task.json" "$2"; }
# hidden TASK REF: go test -v of the hidden tests (and the visible ones) -> $SCR/TASK-REF.log; prints passed/failed names
hidden() {
  local d race=()
  d=$(tree "$1" "$2") || { echo "apply failed"; return 1; }
  [[ $(jq_list "$1" race) == True ]] && race=(-race)
  gorun "$d" test -count=1 "${race[@]}" -v ./internal/hot/ > "$SCR/$1-$2.log" 2>&1
  return 0
}
outcome() { grep -E "^--- (PASS|FAIL): $3 " "$SCR/$1-$2.log" | head -n 1 | awk '{print $2}' | tr -d :; }
compiled() { ! grep -qE '^(# kshop|FAIL\s+kshop/internal/hot \[build failed\])' "$SCR/$1-$2.log"; }

echo "== proof: today's code (base) against each task's hidden tests"
for t in T1-rank T2-round T3-fold T4-base; do
  hidden "$t" base
  for x in $(jq_list "$t" pass_to_pass); do check "$t base: PASS_TO_PASS $x passes" [ "$(outcome "$t" base "$x")" = PASS ]; done
  for x in $(jq_list "$t" fail_to_pass); do check "$t base: FAIL_TO_PASS $x fails" [ "$(outcome "$t" base "$x")" = FAIL ]; done
done
echo "== proof: the reference patches"
for t in T1-rank T2-round T3-fold; do
  for r in $(python3 -I -c 'import json,sys; print(" ".join(r["name"] for r in json.load(open(sys.argv[1]))["refs"]))' "$TASKS/$t/task.json"); do
    hidden "$t" "$r"
    if ! compiled "$t" "$r"; then bad "$t $r: does not compile"; tail -n 5 "$SCR/$t-$r.log"; continue; fi
    nfail=$(grep -cE '^--- FAIL: ' "$SCR/$t-$r.log")
    case $r in
      wrong) check "$t $r: some hidden test fails ($nfail)" [ "$nfail" -gt 0 ] ;;
      *) check "$t $r: every test passes (visible + hidden)" bash -c "[ $nfail = 0 ] && grep -q '^ok ' '$SCR/$t-$r.log'" || grep -E '^--- FAIL|^\s+hidden_test' "$SCR/$t-$r.log" | head -n 5 ;;
    esac
  done
done

echo "== proof: microbenchmarks (ns/op, median of 3)"
bench() { # bench TASK REF NAME -> median ns/op
  local d
  d=$(tree "$1" "$2") || return 1
  gorun "$d" test -count=3 -run '^$' -bench "^$3\$" -benchtime "${BENCHTIME:-300ms}" ./internal/hot/ 2> /dev/null |
    awk -v n="$3" '$1 ~ "^"n"(-[0-9]+)?$" {print $3}' | sort -n | sed -n 2p
}
ratio() { python3 -I -c 'import sys; a, b = float(sys.argv[1]), float(sys.argv[2]); print(f"{a / b:.2f}")' "$1" "$2"; }
b1=$(bench T1-rank base BenchmarkRank); g1=$(bench T1-rank good BenchmarkRank)
s1=$(bench T1-rank slow BenchmarkRank); l1=$(bench T1-rank latency-bad BenchmarkRank)
echo "  T1 Rank: base $b1, good $g1, slow $s1, latency-bad $l1"
check "T1 good is >= 3x faster than today ($(ratio "$b1" "$g1")x)" python3 -I -c "import sys; sys.exit(0 if $b1 >= 3 * $g1 else 1)"
check "T1 slow is faster than today ($(ratio "$b1" "$s1")x) but >= 10x slower than good ($(ratio "$s1" "$g1")x)" python3 -I -c "import sys; sys.exit(0 if $s1 < $b1 and $s1 >= 10 * $g1 else 1)"
check "T1 latency-bad is >= 1.3x slower than today ($(ratio "$l1" "$b1")x)" python3 -I -c "import sys; sys.exit(0 if $l1 >= 1.3 * $b1 else 1)"
b3=$(bench T3-fold base BenchmarkRank); g3=$(bench T3-fold good BenchmarkRank); l3=$(bench T3-fold latency-bad BenchmarkRank)
q3=$(bench T3-fold base BenchmarkQuote); gq3=$(bench T3-fold good BenchmarkQuote); lq3=$(bench T3-fold latency-bad BenchmarkQuote)
echo "  T3 Rank: base $b3, good $g3, latency-bad $l3; Quote: base $q3, good $gq3, latency-bad $lq3"
check "T3 latency-bad Rank is >= 3x slower than today ($(ratio "$l3" "$b3")x)" python3 -I -c "import sys; sys.exit(0 if $l3 >= 3 * $b3 else 1)"
check "T3 good Rank is within 1.5x of today ($(ratio "$g3" "$b3")x)" python3 -I -c "import sys; sys.exit(0 if $g3 <= 1.5 * $b3 else 1)"
q2=$(bench T2-round base BenchmarkQuote); g2=$(bench T2-round good BenchmarkQuote); s2=$(bench T2-round slow BenchmarkQuote)
echo "  T2 Quote: base $q2, good $g2, slow $s2 (a decoy: microseconds, latency does not separate them)"
check "T2 Quote stays far below a millisecond for every ref" python3 -I -c "import sys; sys.exit(0 if max($q2, $g2, $s2) < 1e5 else 1)"

echo "== t_tasks: $PASS passed, $FAILS failed"
[[ ${KEEP:-0} == 1 ]] || rm -rf "$SCR"
[[ $FAILS -eq 0 ]]
