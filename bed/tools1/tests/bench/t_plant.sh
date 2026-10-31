#!/usr/bin/env bash
# t_plant.sh: changes/plant.py (SPEC3 F9) in a copy of the kit holding the CURRENT repo/ (the frozen main): every mechanism
# (sleep spin mutex bimodal alloc noop refactor improve) writes changes/cN-plant in make_prs.sh's layout, its patch applies to
# a fresh copy of repo/ (git apply --check) and compiles through orch/gocheck.sh (capped, offline: go build under the default
# tags and kshop_v11, go vet -tags kshop_v11); what each patch does (the hold is the hooked function's FIRST statement, spin
# never sleeps, mutex holds a package-level lock across the sleep, bimodal's mean and cs2, noop is comments only, refactor is
# exactly a rename, improve edits the constant); the manifest (rbd.plant-change/v1: knob, intended effect, the dose rule,
# never_merge); refusals before any compile, nothing written; gocheck.sh refuses a change that does not compile (exit 3) and
# keeps agent_take.sh's go environment and commands. One compile per mechanism (Go through capped.sh, offline; the build cache
# GOCHECK_CACHE [agent_take's], so a warm run takes ~2 s per compile).
# shellcheck disable=SC2016  # regex, awk and grep literals are single-quoted on purpose
set -uo pipefail
# shellcheck source=tools1/tests/bench/s8lib.sh
. "$(dirname "$0")/s8lib.sh"
echo "== plant.py: planted changes (SPEC3 F9)"
mkenv8 plant
export GOCHECK_CACHE=${GOCHECK_CACHE:-$HOME/rbd-dev/tmp/agent-gocache}
mkkit() { # mkkit DIR: a kit copy with changes/plant.py, orch/gocheck.sh, the current repo/ and a state/main.sha
  mkdir -p "$1/changes" "$1/orch" "$1/state"
  cp "$KIT/changes/plant.py" "$KIT/changes/make_prs.sh" "$1/changes/"
  cp "$KIT/orch/gocheck.sh" "$1/orch/"
  cp -r "$KIT/repo" "$1/repo"
  printf '%040d\n' 7 > "$1/state/main.sha"
}
K=$T/kit
mkkit "$K"
pl() { python3 -I "$K/changes/plant.py" "$@" > "$T/pl.out" 2> "$T/pl.err"; echo $?; }
man() { jq1 "$K/changes/$1/manifest.json" "$2"; }
fresh() { # a fresh copy of the real repo/ (the frozen main) in $T/a, the patch of change $1 applied
  rm -rf "$T/a"; mkdir -p "$T/a"; cp -r "$KIT/repo/kshop" "$T/a/"; git -C "$T/a" init -q -b main
  git -C "$T/a" apply --check "$K/changes/$1/change.patch" && git -C "$T/a" apply "$K/changes/$1/change.patch"
}
first() { awk -v f="$2" 'index($0, "func " f "(") == 1 {getline; print; exit}' "$T/a/$1"; }   # FILE FUNC: its first body line
W=kshop/app/internal/work
HOLD() { printf '\tplantHold() // planted (%s, SPEC3 F9): never merge' "$1"; }

# name service mechanism dose extra...
CASES=(
  "c30-plant payments sleep 3"
  "c31-plant catalog spin 6"
  "c32-plant pricing mutex 1.5"
  "c33-plant payments bimodal 101:0.05:1 --replace"
  "c34-plant inventory alloc 2"
  "c35-plant auth noop -"
  "c36-plant payments refactor -"
  "c37-plant payments improve 2"
  "c38-plant auth improve 1000"
  "c39-plant pricing bimodal 9:0.5:1"
  "c40-plant auth sleep 0.25"
)
for c in "${CASES[@]}"; do
  read -r n s m d x <<< "$c"
  args=("$n" --service "$s" --mechanism "$m")
  [[ $d == - ]] || args+=(--dose "$d")
  [[ -z ${x:-} ]] || args+=("$x")
  rc=$(pl "${args[@]}")
  check "$n ($m on $s): generated and compiled through orch/gocheck.sh (exit $rc)" bash -c "[ $rc -eq 0 ] && grep -q 'compiles: go build (default, kshop_v11) and go vet' '$T/pl.err'"
  check "...make_prs.sh's layout: change.patch, rhobound-change.json, title.txt, manifest.json" bash -c "for f in change.patch rhobound-change.json title.txt manifest.json; do [ -s '$K/changes/$n/'\$f ] || exit 1; done"
  check "...the patch applies to a fresh copy of repo/ (git apply --check) and touches kshop/app/*.go only" bash -c "$(declare -f fresh); T='$T' K='$K' KIT='$KIT' fresh $n > /dev/null 2>&1 &&
    ! git -C '$T/a' apply --numstat -R '$K/changes/$n/change.patch' | awk '{print \$3}' | grep -Ev '^kshop/app/.+\.go\$' | grep -q ."
  fresh "$n" > /dev/null 2>&1
  check "...gofmt-clean after applying" bash -c "cd '$T/a' && [ -z \"\$(gofmt -l kshop/app/internal)\" ]"
  check "...rhobound-change.json: rbd.change-request/v2, services [$s], the manifest's summary" python3 -I -c '
import json, sys
r, m = json.load(open(sys.argv[1] + "/rhobound-change.json")), json.load(open(sys.argv[1] + "/manifest.json"))
sys.exit(0 if r == {"schema": "rbd.change-request/v2", "services": [sys.argv[2]], "summary": m["summary"]} else 1)' "$K/changes/$n" "$s"
  check "...title.txt starts 'PLANT do-not-merge: ' (<= 72) and is the manifest's" bash -c "t=\$(cat '$K/changes/$n/title.txt'); [[ \$t == 'PLANT do-not-merge: '* && \${#t} -le 72 && \$t == '$(man "$n" title)' ]]"
  check "...manifest: rbd.plant-change/v1, mechanism $m, never_merge, compiled, base_sha = state/main.sha, the dose rule" python3 -I -c '
import hashlib, json, sys
d, n, m, s = sys.argv[1:5]
x = json.load(open(d + "/manifest.json"))
ok = x["schema"] == "rbd.plant-change/v1" and x["name"] == n and x["mechanism"] == m and x["service"] == s
ok = ok and x["never_merge"] is True and x["compiled"] is True and x["compile"]["check"] == "orch/gocheck.sh"
ok = ok and x["base_sha"] == "%040d" % 7 and x["patch_sha256"] == hashlib.sha256(open(d + "/change.patch", "rb").read()).hexdigest()
ok = ok and x["dose"]["registered"] == "ab_own_time_delta_ms" and x["dose"]["value_ms"] is None and "never the knob" in x["dose"]["rule"]
ok = ok and isinstance(x["knob"], dict) and x["intended_effect"] and x["placement"]
ok = ok and "registered dose is the A/B-measured own-time delta" in x["summary"]
sys.exit(0 if ok else 1)' "$K/changes/$n" "$n" "$m" "$s"
done

# what each patch does (in $T/a, the applied tree)
fresh c30-plant > /dev/null
check "sleep: plantHold() is RiskCheck's first statement; plant.go: time.Sleep of 3 ms" bash -c "[ \"\$(printf '%s' \"$(first $W/lib_v11.go RiskCheck)\")\" = \"$(HOLD c30-plant)\" ] &&
  grep -qx 'const plantHoldFor = 3 \* time.Millisecond' '$T/a/$W/plant.go' && grep -qxF '	time.Sleep(plantHoldFor)' '$T/a/$W/plant.go'"
check "...the knob: hold_ms 3, intended own +3 ms per call" test "$(man c30-plant knob.hold_ms) $(man c30-plant intended_own_ms_per_call)" = "3.0 3.0"
fresh c31-plant > /dev/null
check "spin: plantHold() is Rank's first statement (before queryTerms and its early return)" test "$(first kshop/app/internal/hot/rank.go Rank)" = "$(HOLD c31-plant)"
check "...plant.go never sleeps: a calibrated loop of 6 ms of CPU (sync.Once, fastest of 7 probes, an atomic sink)" bash -c "f='$T/a/kshop/app/internal/hot/plant.go'; ! grep -q 'Sleep' \$f &&
  grep -qx 'const plantSpinCPU = 6 \* time.Millisecond' \$f && grep -qF 'plantSpinOnce.Do(plantSpinCalibrate)' \$f && grep -qF 'for i := 0; i < 7; i++ {' \$f && grep -qF 'plantSpinSink.Add(plantSpinLoop(plantSpinIters))' \$f"
check "...the manifest documents the calibration (cpu_ms 6)" bash -c "[ '$(man c31-plant knob.cpu_ms)' = 6.0 ] && grep -q 'fastest of 7 timed runs' '$K/changes/c31-plant/manifest.json'"
fresh c32-plant > /dev/null
check "mutex: Quote's first statement; a package-level sync.Mutex held across a 1500 us sleep" bash -c "[ \"\$(printf '%s' \"$(first kshop/app/internal/hot/price.go Quote)\")\" = \"$(HOLD c32-plant)\" ] &&
  f='$T/a/kshop/app/internal/hot/plant.go' && grep -qx 'var plantMu sync.Mutex' \$f && grep -qx 'const plantHoldFor = 1500 \* time.Microsecond' \$f &&
  [ \"\$(grep -A3 '^func plantHold() {' \$f | tr -d '\t' | tr '\n' '|')\" = 'func plantHold() {|plantMu.Lock()|time.Sleep(plantHoldFor)|plantMu.Unlock()|' ]"
fresh c33-plant > /dev/null
check "bimodal --replace: RiskCheck's card hold line becomes time.Sleep(plantHoldDur()); no constant 6 ms hold left; no top hold" bash -c "f='$T/a/$W/lib_v11.go';
  grep -qxF '		time.Sleep(plantHoldDur()) // planted (c33-plant, SPEC3 F9): never merge' \$f && ! grep -qF 'time.Sleep(6 * time.Millisecond)' \$f && ! grep -q 'plantHold()' \$f"
check "...plant.go: 101 ms w.p. 0.05 else 1 ms (math/rand/v2)" bash -c "f='$T/a/$W/plant.go'; grep -qx '	plantA = 101 \* time.Millisecond' \$f && grep -qx '	plantP = 0.05' \$f && grep -qx '	plantB = 1 \* time.Millisecond' \$f && grep -qF '\"math/rand/v2\"' \$f"
check "...manifest: mean 6 ms (= the replaced constant), cs2 13.194444, intended own delta 0 (variance only)" test \
  "$(man c33-plant knob.mean_ms) $(man c33-plant knob.cs2) $(man c33-plant knob.replaces.const_ms) $(man c33-plant intended_own_ms_per_call)" = "6.0 13.194444 6 0.0"
fresh c39-plant > /dev/null
check "bimodal at the top (pricing): Quote's first statement; mean 5 ms, cs2 0.64, intended +5 ms" bash -c "[ \"\$(printf '%s' \"$(first kshop/app/internal/hot/price.go Quote)\")\" = \"$(HOLD c39-plant)\" ] &&
  [ '$(man c39-plant knob.mean_ms) $(man c39-plant knob.cs2) $(man c39-plant intended_own_ms_per_call)' = '5.0 0.64 5.0' ]"
fresh c34-plant > /dev/null
check "alloc: StockCheck's first statement; 2 MB per call, every 4 KiB page touched, read back" bash -c "[ \"\$(printf '%s' \"$(first $W/lib_v11.go StockCheck)\")\" = \"$(HOLD c34-plant)\" ] &&
  f='$T/a/$W/plant.go' && grep -qx 'const plantAllocBytes = 2 << 20' \$f && grep -qF 'i += 4096 { // touch every page' \$f && grep -qF 'plantAllocSink.Add(uint64(buf[len(buf)-4096]))' \$f"
check "noop: every changed line of the patch is a comment" bash -c "p='$K/changes/c35-plant/change.patch'; [ \$(grep -cE '^[-+][^-+]' \$p) -ge 1 ] && ! grep -E '^[-+][^-+]' \$p | grep -vE '^[-+][[:space:]]*//' | grep -q ."
fresh c35-plant > /dev/null
check "...the comment is the first line of VerifyToken, before the cache lookup" bash -c "grep -q '^	// c35-plant (planted, SPEC3 F9): a comment-only control' <<< '$(first $W/lib_v11.go VerifyToken)'"
check "refactor: exactly a rename (method -> payMethod): the + lines with payMethod -> method are the - lines" bash -c "p='$K/changes/c36-plant/change.patch';
  [ \"\$(grep -E '^\+[^+]' \$p | cut -c2- | sed 's/\bpayMethod\b/method/g')\" = \"\$(grep -E '^-[^-]' \$p | cut -c2-)\" ] && [ \$(grep -cE '^\+[^+]' \$p) -eq 3 ]"
fresh c37-plant > /dev/null
check "improve (payments): the card hold 6 -> 2 ms at the constant, the doc comment follows" bash -c "f='$T/a/$W/lib_v11.go';
  grep -qxF '		time.Sleep(2 * time.Millisecond) // planted (c37-plant, SPEC3 F9): was 6 ms' \$f && grep -q '^// RiskCheck (1.1) adds a mandatory 2 ms synchronous hold' \$f && [ '$(man c37-plant knob.card_hold_ms)' = '[6, 2.0]' ]"
fresh c38-plant > /dev/null
check "improve (auth): PBKDF2 2500 -> 1000 iterations at the call" bash -c "grep -qF '[]byte(\"kshop-session-salt\"), 1000, 32) // planted (c38-plant, SPEC3 F9): was 2500 iterations' '$T/a/$W/lib_v11.go'"
fresh c40-plant > /dev/null
check "sleep 0.25 ms on auth: VerifyToken's first statement (before the 256-entry LRU lookup), 250 us" bash -c "[ \"\$(printf '%s' \"$(first $W/lib_v11.go VerifyToken)\")\" = \"$(HOLD c40-plant)\" ] &&
  grep -qx 'const plantHoldFor = 250 \* time.Microsecond' '$T/a/$W/plant.go'"

# refusals: before any compile, nothing written
lsch() { find "$K/changes" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }
before=$(lsch)
ref() { # WANT-IN-ERROR ARGS...
  local want=$1 rc
  shift
  rc=$(pl "$@")
  check "refused ($*): exit 1, '$want'" bash -c "[ $rc -eq 1 ] && grep -qF -- '$want' '$T/pl.err'"
}
ref "NAME must be cN-plant" c50-bench --service payments --mechanism sleep --dose 3
ref "no plantable hook" c50-plant --service cart --mechanism sleep --dose 3
ref "takes no --dose" c50-plant --service auth --mechanism noop --dose 1
ref "needs --dose" c50-plant --service auth --mechanism sleep
ref "out of range" c50-plant --service auth --mechanism sleep --dose 0
ref "out of range" c50-plant --service auth --mechanism spin --dose 500
ref "whole number of microseconds" c50-plant --service auth --mechanism sleep --dose 1.0005
ref "is not a number" c50-plant --service auth --mechanism mutex --dose 3ms
ref "must equal the card hold it replaces (6 ms on main)" c50-plant --service payments --mechanism bimodal --dose 50:0.1:1 --replace
ref "bimodal --dose is A:P:B" c50-plant --service pricing --mechanism bimodal --dose 9:1
ref "want 0 < P < 1 and A != B" c50-plant --service pricing --mechanism bimodal --dose 9:1.5:1
ref "--replace is for bimodal on payments only" c50-plant --service catalog --mechanism bimodal --dose 9:0.5:1 --replace
ref "only payments (the card hold) and auth (PBKDF2 iterations)" c50-plant --service catalog --mechanism improve --dose 1
ref "is not a speed-up" c50-plant --service payments --mechanism improve --dose 6
ref "out of range" c50-plant --service payments --mechanism improve --dose 9
ref "new PBKDF2 iteration count, 1..2499" c50-plant --service auth --mechanism improve --dose 2500
ref "alloc --dose is whole MB, 1..64" c50-plant --service inventory --mechanism alloc --dose 1.5
ref "changes/c30-plant exists (--force replaces it)" c30-plant --service payments --mechanism sleep --dose 3
ref "the title: 1..72 printable characters" c50-plant --service auth --mechanism noop --title "$(printf 'x%.0s' $(seq 1 60))"
ref "CI-skip token" c50-plant --service auth --mechanism noop --summary "a change [skip ci]"
ref "an IPv4 address or a 12-digit number" c50-plant --service auth --mechanism noop --summary "account 123456789012"
check "...no refusal wrote anything under changes/ (no temp folder left either)" test "$(lsch)" = "$before"
rc=$(pl c50-plant --mechanism sleep --dose 3)
check "usage: --service missing: exit 2" test "$rc" -eq 2
rc=$(pl c30-plant --service catalog --mechanism sleep --dose 4 --force --no-compile)
check "--force replaces changes/c30-plant (--no-compile: manifest compiled false, said loudly; exit $rc)" bash -c "[ $rc -eq 0 ] && [ '$(man c30-plant service) $(man c30-plant compiled)' = 'catalog false' ] &&
  grep -q 'NOT compiled here' '$T/pl.err' && [ \"\$(ls -A '$K/changes' | grep -c '^\.')\" -eq 0 ]"
# main moved: the anchors are checked against the current repo/
K2=$T/kit2
mkkit "$K2"
sed -i 's/^func VerifyToken(token string) bool {$/func VerifyTokenV2(token string) bool {/' "$K2/repo/$W/lib_v11.go"
sed -i 's/time.Sleep(6 \* time.Millisecond)/time.Sleep(6*time.Millisecond + 0)/' "$K2/repo/$W/lib_v11.go"
printf 'package hot\n\nfunc plantOld() {}\n' > "$K2/repo/kshop/app/internal/hot/plant.go"
rc=$(K=$K2 pl c51-plant --service auth --mechanism sleep --dose 1)
check "main moved: VerifyToken renamed on repo/: refused, the hook is gone (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'the hook is gone' '$T/pl.err'"
rc=$(K=$K2 pl c51-plant --service payments --mechanism improve --dose 2)
check "main moved: the card hold line differs: improve refused (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'card hold) on main (want exactly 1): repo/ moved' '$T/pl.err'"
rc=$(K=$K2 pl c51-plant --service catalog --mechanism spin --dose 1)
check "a plant.go already on main (a plant merged?): refused (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'plant.go exists on main' '$T/pl.err' && [ ! -e '$K2/changes/c51-plant' ]"
rm -f "$K2/state/main.sha"
rc=$(K=$K2 pl c51-plant --service inventory --mechanism noop)
check "no state/main.sha: refused (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'state/main.sha' '$T/pl.err'"
# a change that does not compile: gocheck.sh exit 3, plant.py exit 3, nothing written
K3=$T/kit3
mkkit "$K3"
printf '#!/usr/bin/env bash\necho "stub gocheck: does not compile" >&2\nexit 3\n' > "$K3/orch/gocheck.sh"
rc=$(K=$K3 pl c52-plant --service payments --mechanism sleep --dose 3)
check "gocheck.sh says it does not compile: plant.py exit 3, changes/c52-plant not written (exit $rc)" bash -c "[ $rc -eq 3 ] && [ ! -e '$K3/changes/c52-plant' ] && grep -q 'does not compile' '$T/pl.err'"
rm -rf "$T/b"; mkdir -p "$T/b"; cp -r "$KIT/repo/kshop" "$T/b/"
sed -i 's/^func Quote(cart string) int64 {$/&\n\tundefinedPlant()/' "$T/b/kshop/app/internal/hot/price.go"
rc=$(bash "$K/orch/gocheck.sh" "$T/b" "$T/b.log" kshop/app/internal/hot/price.go > /dev/null 2>&1; echo $?)
check "gocheck.sh on a tree that does not compile: exit 3, the go error in LOG (rc $rc)" bash -c "[ $rc -eq 3 ] && grep -q 'undefined: undefinedPlant' '$T/b.log'"
printf '//go:build never\n\npackage hot\n' > "$T/b/kshop/app/internal/hot/never.go"
cp "$KIT/repo/kshop/app/internal/hot/price.go" "$T/b/kshop/app/internal/hot/price.go"
rc=$(bash "$K/orch/gocheck.sh" "$T/b" "$T/b.log" kshop/app/internal/hot/never.go > /dev/null 2> "$T/b.err"; echo $?)
check "gocheck.sh: a changed file neither tag set builds was never checked: refused (rc $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'compiled under neither' '$T/b.err'"
# gocheck.sh keeps orch/agent_take.sh's compile step: the same go environment, cap and commands
gostep() { grep -E '^goenv=\(|^  "GOTMPDIR=|^  GOOS=linux|^\[\[ -z \$CAPPED \]\] \|\| cap=|^gorun\(\)|gorun go build|gorun go vet|gorun go list|ulimit -f|^\(\( \$\(du -sm|^\(\( \$\(df -Pm' "$1" | grep -v '^ *#' | sed -E 's/^ *//; s/ *[|][|].*$//'; }
check "gocheck.sh = agent_take.sh's compile step (goenv, cap, ulimit, build/vet/list lines, cache trim, free-space check)" \
  bash -c "[ \"\$($(declare -f gostep); gostep '$KIT/orch/gocheck.sh')\" = \"\$($(declare -f gostep); gostep '$KIT/orch/agent_take.sh')\" ] && [ \$($(declare -f gostep); gostep '$KIT/orch/gocheck.sh' | wc -l) -ge 10 ]"
check "nothing forbidden ran (ssh, aws, docker, kubectl)" test ! -s "$STUB_DIR/forbidden.log"
done_summary
