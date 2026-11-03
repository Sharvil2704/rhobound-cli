#!/usr/bin/env bash
# test_load.sh: the production load setting (SPEC3 F6a), offline. loadmix.py (the rate 10..400 with one decimal at most, the
# mix by name, the file's format/owner/mode, the environment never overriding the file, no "url" key in its output; weights
# written as plain decimals, never 1e-05/1e+16, so what envfile accepts every reader accepts; weights a float cannot hold
# refused at input); load.sh set|reset|show (validated, atomic, under the lock, the background load restarted at it,
# --no-restart; a new load.env refused on reading back changes nothing: the old file and the running Job stay);
# bgload.sh start/ensure/status at the setting (no file: the Job is render.py's without flags AND today's default written
# out here, LOAD_RPS "100" and spec.json's LOAD_MIX, not rendered by the render.py under test; a refused setting leaves the
# running Job alone; ensure restarts a Job running at another load and leaves an unreadable one); capture.sh: the window Job
# AND the background load its trap restarts at the SAME setting, the setting in meta/capture.json and as the last line of
# meta/load.json (loadlog.py, verify's score.py and load_ok still read it as before), the default window Job today's (the
# same two pins), a refused setting stopping it before anything is touched, a Job's log at another rate failing it.
# kubectl is the stub (orch/tests/stubs/kubectl), the CLI a fake whose check admits every window. lib.sh unsets
# RBD_LOAD_RPS/RBD_LOAD_MIX (a stray export in the caller's shell); the checks that need them set them per command.
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2030,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
mk_env
ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze
LOADIMG=$ECR@sha256:$(printf '%064d' 99)
jq -n --arg l "$LOADIMG" '{schema: "rbd.images/v1", load: $l}' > "$T/home/images.json"
export RBD_SETTLE_S=0 RBD_FLUSH_S=0 RBD_POLL_S=0 RBD_LOCK_WAIT=3
# the kit's load tools on the CI fixture world's spec (fixtures/repo-day1: 100 rps, browse 0.7 / card 0.18 / wallet 0.12): the
# tests check the generic mix logic; maze's own five-entry mix is rendered by test_render.py
mkdir -p "$T/opt"
cp -a "$DEMO/tools1/lib" "$DEMO/tools1/maze" "$T/opt/"
cp "$DEMO/tools1/tests/ci/fixtures/repo-day1/maze/spec.json" "$T/opt/maze/spec.json"
export RBD_OPT=$T/opt
K=$RBD_OPT/maze
MIX=$K/loadmix.py LOADSH=$K/load.sh BG=$K/bgload.sh REN=$K/render.py CAP=$DEMO/tools1/ci/capture.sh
F=$T/home/load.env
SF=http://storefront.maze.svc.cluster.local:8080/browse
CARD=http://checkout.maze.svc.cluster.local:8080/buy/card
WALLET=http://checkout.maze.svc.cluster.local:8080/buy/wallet
lm() { python3 -I "$MIX" "$@"; }
jqe() { jq -e "$@" > /dev/null; }
envof() { jq -r --arg n "$2" '.spec.template.spec.containers[0].env[] | select(.name == $n) | .value' "$1"; }   # envof MANIFEST NAME
loadenv() { jq -c '[.spec.template.spec.containers[0].env[] | select(.name | test("^LOAD_(RPS|MIX|PATTERN)$"))] | sort_by(.name)' "$1"; }
last_apply() { ls -t "$STUB_DIR"/apply.* 2> /dev/null | head -n 1; }
bg_apply() { grep -l '"maze-bgload"' "$STUB_DIR"/apply.* 2> /dev/null | xargs -r ls -t | head -n 1; }
fresh() { : > "$STUB_LOG"; rm -f "$STUB_DIR"/apply.*; }
holdlock() { ( RBD_HOME=$T/home; . "$DEMO/tools1/lib/lock.sh"; rbd_lock 5 a-truth-bracket; sleep "$1" ) & HP=$!; sleep 0.5; }
# today's default Jobs (the kit before F6a, and the maze generator's render.py), written out, not
# rendered by the render.py under test: the Job's name, then its whole env in order
DEFMIX="[{\"url\":\"$SF\",\"w\":0.7},{\"url\":\"$CARD\",\"w\":0.18},{\"url\":\"$WALLET\",\"w\":0.12}]"
pinned() {   # pinned MANIFEST JOB SECONDS [SEED]: LOAD_RPS "100", LOAD_SECONDS, LOAD_SEED (SEED, or the Job's own digits), LOAD_MIX DEFMIX
  local seed; seed=$(envof "$1" LOAD_SEED)
  [[ $seed =~ ^[0-9]+$ ]] && [ "$seed" = "${4:-$seed}" ] &&
    [ "$(jq -c '[.metadata.name, [.spec.template.spec.containers[0].env[] | [.name, .value]]]' "$1")" = \
      "$(jq -cn --arg n "$2" --arg s "$3" --arg seed "$seed" --arg mix "$DEFMIX" '[$n, [["LOAD_RPS", "100"], ["LOAD_SECONDS", $s], ["LOAD_SEED", $seed], ["LOAD_MIX", $mix]]]')" ]
}

echo "-- loadmix.py"
d=$(lm show "$F"); rc=$?
check "no load.env: the default (100 rps, browse 0.7 / card 0.18 / wallet 0.12; storefront 70, checkout 30 rps)" \
  jqe '.schema == "rbd.load/v1" and .source == "default" and .file == null and .sha256 == null and .rps == 100
    and .mix == "browse=0.7,card=0.18,wallet=0.12" and .entries == {storefront: 70, checkout: 30}
    and .rates == {browse: 70, card: 18, wallet: 12}' <<< "$d"
check "...exit 0" [ $rc = 0 ]
check "...the same as show --default" [ "$(lm show --default)" = "$d" ]
check "the output has no \"url\" key and no 'maze-load:' (it becomes a load.json line)" bash -c "! grep -qE '\"url\"|maze-load:' <<< '$d'"
n=0; nbad=0; Z308=$(printf '0%.0s' $(seq 308)); Z400=$(printf '0%.0s' $(seq 400))
for bad in "--rps 9" "--rps 401" "--rps 9.9" "--rps 400.1" "--rps 130.25" "--rps abc" "--rps -5" "--rps 1e2" "--rps nan" \
  "--mix browse=1,card=0" "--mix browse=1,card=0,wallet=0,foo=1" "--mix browse=1,browse=2,card=0,wallet=0" \
  "--mix browse=0,card=0,wallet=0" "--mix browse=-1,card=0,wallet=1" "--mix browse=1e2,card=0,wallet=1" \
  "--mix browse=inf,card=0,wallet=1" "--mix browse,card=0,wallet=1" "--mix browse=0.7;card=0.18;wallet=0.12" \
  "--rates browse=91.25,card=18,wallet=12" "--rates browse=400,card=1,wallet=0" "--rates browse=5,card=2,wallet=2" \
  "--mix browse=1$Z400,card=0,wallet=1" "--mix browse=0.${Z400}1,card=0,wallet=1" "--mix browse=1$Z308,card=1$Z308,wallet=0"; do
  n=$((n + 1))
  # shellcheck disable=SC2086
  out=$(lm envfile $bad 2> "$T/bad.err"); rc=$?
  if [ $rc = 1 ] && [ -z "$out" ] && grep -q '^loadmix: ' "$T/bad.err"; then :; else nbad=$((nbad + 1)); echo "    accepted or bad refusal: $bad (rc $rc) $(cat "$T/bad.err")"; fi
done
check "envfile refuses $n bad settings (rate outside 10..400 or 2 decimals, unknown/duplicate/missing name, weights < 0 or summing to 0, not plain decimals, past a float or a non-zero rounding to 0, a sum past a float) with exit 1, a reason, no output" [ $nbad = 0 ]
lm envfile --mix "browse=1$Z400,card=0,wallet=1" 2> "$T/big.err"; check "...a weight past a float: the reason says so (too large for a float)" grep -q 'browse=1000.*\.\.\.: too large for a float' "$T/big.err"
lm envfile --rates browse=1 --rps 100 > /dev/null 2>&1; check "--rates with --rps: usage (exit 2)" [ $? = 2 ]
lm envfile > /dev/null 2>&1; check "envfile with nothing: usage (exit 2)" [ $? = 2 ]
check "the bounds 10 and 400 rps are accepted" bash -c "python3 -I '$MIX' envfile --rps 10 | grep -qx RBD_LOAD_RPS=10.0 && python3 -I '$MIX' envfile --rps 400 | grep -qx RBD_LOAD_RPS=400.0"
check "a 0 weight is accepted (it leaves the URL out of the Job)" bash -c "python3 -I '$MIX' envfile --mix browse=1,card=0,wallet=0 | grep -qx RBD_LOAD_MIX=browse=1.0,card=0.0,wallet=0.0"
plain() {   # plain WHAT MIX WRITTEN: envfile --rps 130 --mix MIX accepted, load.env's mix line WRITTEN, and show reads it back as WRITTEN
  local e rc; e=$(lm envfile --rps 130 --mix "$2" 2> "$T/plain.err"); rc=$?
  check "$1: accepted (rc $rc), written as RBD_LOAD_MIX=$3 (no exponent)" bash -c "[ $rc = 0 ] && grep -qxF 'RBD_LOAD_MIX=$3' <<< \"\$1\"" _ "$e"
  printf '%s\n' "$e" > "$T/plain.env"; chmod 0644 "$T/plain.env"
  check "...show reads that load.env back: exit 0, the same mix" bash -c "python3 -I '$MIX' show '$T/plain.env' | jq -e --arg m '$3' '.source == \"load.env\" and .mix == \$m' > /dev/null"
}
plain "a tiny weight (wallet=0.00001; repr writes 1e-05)" browse=0.7,card=0.18,wallet=0.00001 browse=0.7,card=0.18,wallet=0.00001
plain "a huge weight (browse=10000000000000000; repr writes 1e+16)" browse=10000000000000000,card=1,wallet=1 browse=10000000000000000,card=1.0,wallet=1.0
printf 'RBD_LOAD_RPS=130\nRBD_LOAD_MIX=browse=0.7,card=0.18,wallet=0.00001\n' > "$T/hand.env"; chmod 0644 "$T/hand.env"
check "a hand-written load.env with the plain wallet=0.00001: show accepts it, the mix as written (not '1e-05')" bash -c "python3 -I '$MIX' show '$T/hand.env' | jq -e '.mix == \"browse=0.7,card=0.18,wallet=0.00001\" and .rps == 130' > /dev/null"
check "canon: 2000 random weights 1e-30..1e30 and the extremes (5e-324, 1e-300, 1e16, 1e300, the largest float) written as plain decimals that read back as the same floats" \
  python3 -I -B -c '
import random, sys
sys.path.insert(0, sys.argv[1])
import loadmix, render
names = list(render.mix_targets().items())
rnd = random.Random(7)
bad = []
for w in [5e-324, 1e-300, 1e-05, 1 / 3, 0.1 + 0.2, 1e16, 1.5e16, 1e300, 1.7976931348623157e308] + [10 ** rnd.uniform(-30, 30) for _ in range(2000)]:
    weights = [(names[0][0], names[0][1], w), (names[1][0], names[1][1], 1.0), (names[2][0], names[2][1], 0.0)]
    text = loadmix.canon(weights)
    if not all(render.WEIGHT.match(p.split("=")[1]) for p in text.split(",")) or render.parse_weights(text) != weights:
        bad.append(text[:80])
print(*bad[:3], sep="\n")
sys.exit(1 if bad else 0)' "$K"
e=$(lm envfile --rps 130 --by tester)
check "envfile --rps 130: the rate, spec.json's mix (not an older file's), a dated comment" bash -c "grep -qx RBD_LOAD_RPS=130.0 <<< '$e' && grep -qx RBD_LOAD_MIX=browse=0.7,card=0.18,wallet=0.12 <<< '$e' && grep -q '^# rbd.load/v1 .*(tester, 20[0-9-]*T[0-9:]*Z)' <<< '$e' && [ \$(grep -vc '^#' <<< '$e') = 2 ]"
check "envfile --rates browse=91,card=18,wallet=12 (P-M1, browse x1.3): R = 121" bash -c "python3 -I '$MIX' envfile --rates browse=91,card=18,wallet=12 | grep -qx RBD_LOAD_RPS=121.0"
lm envfile --rps 130 --mix browse=0.91,card=0.18,wallet=0.12 > "$F"; chmod 0644 "$F"
s=$(lm show "$F")
check "show FILE: source load.env, its path and sha256, 130 rps, the mix, shares and per-entry rates" \
  jqe --arg f "$F" --arg h "sha256:$(sha256sum "$F" | cut -d' ' -f1)" '.source == "load.env" and .file == $f and .sha256 == $h
    and .rps == 130 and .mix == "browse=0.91,card=0.18,wallet=0.12" and (.shares.browse - 0.91 / 1.21 | fabs) < 1e-6
    and (.entries.storefront - 130 * 0.91 / 1.21 | fabs) < 1e-3 and (.summary | startswith("130 rps (load.env): browse 97.77"))' <<< "$s"
cp "$F" "$T/good.env"
bad_file() {   # bad_file WHAT GREP: show refuses the current $F (exit 1, the reason matching GREP, nothing on stdout)
  local out rc; out=$(lm show "$F" 2> "$T/bf.err"); rc=$?
  check "$1: refused (exit $rc: $(head -c 140 "$T/bf.err"))" bash -c "[ $rc = 1 ] && [ -z '$out' ] && grep -q '$2' '$T/bf.err'"
  rm -f "$F"; cp "$T/good.env" "$F"; chmod 0644 "$F"
}
chmod 0664 "$F"; bad_file "a group-writable load.env" "not group/other-writable"
chmod 0646 "$F"; bad_file "an other-writable load.env" "not group/other-writable"
rm "$F"; ln -s "$T/good.env" "$F"; bad_file "a symlink" "symlink"
echo "RBD_LOAD_PATTERN=mmpp:3:10:30" >> "$F"; bad_file "an unknown key" "line 4 is not RBD_LOAD_RPS"
echo "RBD_LOAD_RPS=140" >> "$F"; bad_file "a key twice" "RBD_LOAD_RPS a second time"
grep -v RBD_LOAD_MIX "$T/good.env" > "$F"; bad_file "no RBD_LOAD_MIX" "no RBD_LOAD_MIX"
sed -i 's/^RBD_LOAD_RPS=.*/RBD_LOAD_RPS="130"/' "$F"; bad_file "a quoted value (it is parsed, never sourced)" "plain decimal"
sed -i 's/^RBD_LOAD_RPS=.*/RBD_LOAD_RPS=$(touch pwned)/' "$F"; bad_file "a command substitution" "plain decimal"
check "...nothing ran it" bash -c "[ ! -e pwned ] && [ ! -e '$T/home/pwned' ]"
sed -i 's/^RBD_LOAD_RPS=.*/RBD_LOAD_RPS=500/' "$F"; bad_file "a rate over 400 in the file" "10..400"
check "the good file is back" cmp -s "$F" "$T/good.env"
out=$(RBD_LOAD_RPS=100 lm show "$F" 2> "$T/env.err"); rc=$?
check "RBD_LOAD_RPS=100 in the environment, 130 in load.env: refused (exit $rc), naming load.sh set" bash -c "[ $rc = 1 ] && [ -z '$out' ] && grep -q 'never by the environment' '$T/env.err' && grep -q 'load.sh set' '$T/env.err'"
out=$(RBD_LOAD_MIX=browse=0.7,card=0.18,wallet=0.12 lm show "$F" 2> /dev/null); check "RBD_LOAD_MIX at other shares than load.env's: refused" [ $? = 1 ]
check "RBD_LOAD_RPS=130 and RBD_LOAD_MIX at the same shares (rates 91/18/12): accepted" bash -c "RBD_LOAD_RPS=130 RBD_LOAD_MIX=browse=91,card=18,wallet=12 python3 -I '$MIX' show '$F' > /dev/null"
check "RBD_LOAD_RPS=130 with no load.env (the default is 100): refused" bash -c "! RBD_LOAD_RPS=130 python3 -I '$MIX' show '$T/none.env' > /dev/null 2>&1"
check "RBD_LOAD_RPS=100 with no load.env: accepted" bash -c "RBD_LOAD_RPS=100 python3 -I '$MIX' show '$T/none.env' > /dev/null"
check "no __pycache__ written beside render.py" [ ! -e "$K/__pycache__" ]

echo "-- render.py --mix-weights"
r=$(python3 -I "$REN" load --load-image "$LOADIMG" --seconds 60 --seed 7 --rps 130 --mix-weights card=0.18,browse=0.91,wallet=0.12) && echo "$r" > "$T/r.json"
check "--rps 130 --mix-weights: LOAD_RPS 130.0, LOAD_MIX the spec URLs in spec order with the weights" \
  bash -c "[ \"\$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == \"LOAD_RPS\") | .value' '$T/r.json')\" = 130.0 ] && [ \"\$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == \"LOAD_MIX\") | .value' '$T/r.json')\" = '[{\"url\":\"$SF\",\"w\":0.91},{\"url\":\"$CARD\",\"w\":0.18},{\"url\":\"$WALLET\",\"w\":0.12}]' ]"
python3 -I "$REN" load --load-image "$LOADIMG" --seconds 60 --seed 7 --mix-weights browse=1,card=0,wallet=0.5 > "$T/r0.json"
check "a 0 weight leaves its URL out of LOAD_MIX" [ "$(envof "$T/r0.json" LOAD_MIX)" = "[{\"url\":\"$SF\",\"w\":1.0},{\"url\":\"$WALLET\",\"w\":0.5}]" ]
python3 -I "$REN" load --load-image "$LOADIMG" --seconds 60 --seed 7 --mix-weights browse=0.7,card=0.18,wallet=0.12 > "$T/rd.json"
python3 -I "$REN" load --load-image "$LOADIMG" --seconds 60 --seed 7 > "$T/rn.json"
check "--mix-weights with spec.json's weights = spec.json's LOAD_MIX" [ "$(envof "$T/rd.json" LOAD_MIX)" = "$(envof "$T/rn.json" LOAD_MIX)" ]
check "no flags: LOAD_RPS \"100\" (spec.json's int), as today" [ "$(envof "$T/rn.json" LOAD_RPS)" = 100 ]
python3 -I "$REN" load --load-image "$LOADIMG" --mix-weights browse=1,card=0 > /dev/null 2> "$T/r.err"; check "--mix-weights missing a name: refused" grep -q "no weight for wallet" "$T/r.err"
python3 -I "$REN" load --load-image "$LOADIMG" --mix-weights browse=1,card=0,wallet=0 --mix "$T/r.json" > /dev/null 2> "$T/r.err"; check "--mix and --mix-weights together: refused" grep -q "not both" "$T/r.err"

echo "-- bgload.sh start/ensure/status"
rm -f "$F"; fresh
bash "$BG" start 2> "$T/b1.err"; rc=$?
m=$(bg_apply); seed=$(envof "$m" LOAD_SEED)
check "start, no load.env: exit 0 (rc $rc)" [ $rc = 0 ]
check "...the Job byte-identical to render.py's without --rps/--mix-weights (bgload.sh passed no flags)" bash -c "python3 -I '$REN' load --load-image '$LOADIMG' --name maze-bgload --seconds 43200 --seed '$seed' | cmp -s - '$m'"
check "...today's default Job, written out: LOAD_RPS \"100\", LOAD_SECONDS 43200.0, spec.json's LOAD_MIX, nothing else" pinned "$m" maze-bgload 43200.0
check "...the log names the load" grep -q 'started (43200 s, seed [0-9]*; 100 rps (default): browse 70, card 18, wallet 12)' "$T/b1.err"
cp "$T/good.env" "$F"; chmod 0644 "$F"; fresh
bash "$BG" start 2> "$T/b2.err"; rc=$?; m130=$(bg_apply)
check "start with load.env (130 rps, browse 0.91): exit 0, LOAD_RPS 130.0 and the mix" bash -c "[ $rc = 0 ] && [ \"\$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == \"LOAD_RPS\") | .value' '$m130')\" = 130.0 ] && [ \"\$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == \"LOAD_MIX\") | .value' '$m130')\" = '[{\"url\":\"$SF\",\"w\":0.91},{\"url\":\"$CARD\",\"w\":0.18},{\"url\":\"$WALLET\",\"w\":0.12}]' ]"
check "...stopped the old Job first, then applied" [ "$(grep -oE 'delete job maze-bgload|apply -f -$' "$STUB_LOG" | tr '\n' '|')" = "delete job maze-bgload|apply -f -|" ]
cp "$m130" "$T/job130.json"
chmod 0664 "$F"; fresh
bash "$BG" start 2> "$T/b3.err"; rc=$?
check "start with a refused load.env: exit 1 (rc $rc), the reason, the running Job NOT stopped" bash -c "[ $rc = 1 ] && grep -q 'the load setting is refused: .*group/other-writable' '$T/b3.err' && ! grep -q 'delete job' '$STUB_LOG' && ! ls '$STUB_DIR'/apply.* > /dev/null 2>&1"
fresh
STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job130.json bash "$BG" ensure 2> "$T/b4.err"; rc=$?
check "ensure, Job running, load.env refused: exit 1, nothing touched" bash -c "[ $rc = 1 ] && ! grep -q 'delete job' '$STUB_LOG'"
chmod 0644 "$F"; fresh
STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job130.json bash "$BG" ensure 2> "$T/b5.err"; rc=$?
check "ensure, the running Job at the setting: nothing done (rc $rc)" bash -c "[ $rc = 0 ] && ! grep -q 'delete job' '$STUB_LOG'"
python3 -I "$REN" load --load-image "$LOADIMG" --name maze-bgload --seconds 43200 --seed 1001 > "$T/job100.json"
fresh
STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job100.json bash "$BG" ensure 2> "$T/b6.err"; rc=$?
check "ensure, the running Job at the default but load.env says 130: started again (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'delete job maze-bgload' '$STUB_LOG' && grep -q 'running at another load' '$T/b6.err'"
check "...at the setting" [ "$(loadenv "$(bg_apply)")" = "$(loadenv "$T/job130.json")" ]
fresh
STUB_BG_ACTIVE=1 bash "$BG" ensure 2> "$T/b7.err"; rc=$?
check "ensure, the running Job's env unreadable: left alone, warned (rc $rc)" bash -c "[ $rc = 0 ] && ! grep -q 'delete job' '$STUB_LOG' && grep -q 'cannot read the running Job' '$T/b7.err'"
holdlock 3; fresh
STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job100.json bash "$BG" ensure 2> "$T/b8.err"
check "ensure with the lock held: nothing touched, even at another load" bash -c "! grep -q 'maze-bgload' '$STUB_LOG' && grep -q 'lock held' '$T/b8.err'"
wait $HP
st=$(STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job100.json bash "$BG" status 2>&1)
check "status: 'maze-bgload: running' first, then the setting and the running Job at another load" bash -c "[ \"\$(head -n 1 <<< '$st')\" = 'maze-bgload: running' ] && grep -q '  load setting: 130 rps (load.env)' <<< '$st' && grep -q 'the running Job is at another load' <<< '$st'"
st=$(STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job130.json bash "$BG" status 2>&1)
check "status, the Job at the setting: no 'another load' line" bash -c "! grep -q 'another load' <<< '$st' && [ \$(wc -l <<< '$st') = 2 ]"
st=$(STUB_BG_ACTIVE="" bash "$BG" status 2>&1); check "status, not running: the setting still shown" bash -c "grep -qx 'maze-bgload: NOT running' <<< '$st' && grep -q 'load setting: 130 rps' <<< '$st'"

echo "-- load.sh"
rm -f "$F"
check "show, no load.env: the default (one JSON line)" bash -c "bash '$LOADSH' show | jq -se 'length == 1 and .[0].source == \"default\" and .[0].rps == 100' > /dev/null"
fresh
out=$(bash "$LOADSH" set --rps 130 --mix browse=0.91,card=0.18,wallet=0.12 2> "$T/l1.err"); rc=$?; last=$(tail -n 1 <<< "$out")
check "set --rps 130 --mix ...: exit 0 (rc $rc)" [ $rc = 0 ] || tail -5 "$T/l1.err"
check "...last line: step load ok, action set, the setting, restarted" jqe '.step == "load" and .ok and .action == "set" and .restarted and .load.source == "load.env" and .load.rps == 130' <<< "$last"
check "...load.env: the two lines, 0644, ours" bash -c "grep -qx RBD_LOAD_RPS=130.0 '$F' && grep -qx RBD_LOAD_MIX=browse=0.91,card=0.18,wallet=0.12 '$F' && [ \"\$(stat -c '%a %u' '$F')\" = '644 $(id -u)' ]"
check "...written atomically (no temporary file left)" bash -c "! ls -a '$T/home' | grep -q '^\.load\.env\.'"
m=$(bg_apply)
check "...the background load restarted at it" bash -c "grep -q 'delete job maze-bgload' '$STUB_LOG' && [ -n '$m' ] && [ '$(loadenv "${m:-/dev/null}" 2> /dev/null)' = '$(loadenv "$T/job130.json")' ]"
cp "$F" "$T/before.env"; fresh
out=$(bash "$LOADSH" set --rps 5 2> "$T/l2.err"); rc=$?
check "set --rps 5: refused (exit $rc), the reason in the last line, load.env and the background load untouched" bash -c "[ $rc = 1 ] && [ \"\$(tail -n 1 <<< '$out' | jq -r '\"\(.ok) \(.error)\"')\" = 'false --rps=5: the rate must be 10..400 rps' ] && cmp -s '$F' '$T/before.env' && [ ! -s '$STUB_LOG' ]"
holdlock 6; fresh
RBD_LOCK_WAIT=1 bash "$LOADSH" set --rps 140 > "$T/l3.out" 2> "$T/l3.err"; rc=$?
check "set with the lock held (a truth bracket): refused (exit $rc), naming the holder; nothing changed" bash -c "[ $rc = 1 ] && grep -q 'a-truth-bracket' '$T/l3.out' && cmp -s '$F' '$T/before.env' && [ ! -s '$STUB_LOG' ]"
wait $HP
out=$(RBD_LOAD_RPS=130 bash "$LOADSH" set --rps 140 2> /dev/null); rc=$?
check "set --rps 140 while rbd.env.local says RBD_LOAD_RPS=130: refused (exit $rc), file unchanged" bash -c "[ $rc = 1 ] && cmp -s '$F' '$T/before.env'"
fresh
out=$(bash "$LOADSH" set --rates browse=91,card=18,wallet=12 --no-restart 2> "$T/l4.err"); rc=$?
check "set --rates browse=91,card=18,wallet=12 --no-restart: 121 rps, restarted false, no kubectl" bash -c "[ $rc = 0 ] && grep -qx RBD_LOAD_RPS=121.0 '$F' && tail -n 1 <<< '$out' | jq -e '.restarted == false and .load.rps == 121' > /dev/null && ! grep -q kubectl '$STUB_LOG'"
bash "$LOADSH" set --rates browse=91,card=18,wallet=12 --rps 121 > /dev/null 2>&1; check "set --rates with --rps: usage (exit 2)" [ $? = 2 ]
bash "$LOADSH" set > /dev/null 2>&1; check "set with nothing: usage (exit 2)" [ $? = 2 ]
bash "$LOADSH" show --rps 1 > /dev/null 2>&1; check "show --rps: usage (exit 2)" [ $? = 2 ]
bash "$LOADSH" bogus > /dev/null 2>&1; check "an unknown action: usage (exit 2)" [ $? = 2 ]
# a new load.env that envfile wrote but the readers refuse (the 1e-05 bug; none left to reach it): a python3 first on PATH
# refuses 'loadmix.py show FILE' of any FILE holding the line FORCE_READBACK_REFUSED (the new body, wherever load.sh puts
# it), else is python3
REALPY=$(command -v python3)
cat > "$T/bin/python3" << EOF
#!/usr/bin/env bash
if [ -n "\${FORCE_READBACK_REFUSED:-}" ] && [ "\${3:-}" = show ] && [ -f "\${4:-}" ] && grep -qxF "\$FORCE_READBACK_REFUSED" "\$4"; then
  echo "loadmix: forced refusal (test)" >&2; exit 1
fi
exec "$REALPY" "\$@"
EOF
chmod +x "$T/bin/python3"
python3 -I "$REN" load --load-image "$LOADIMG" --name maze-bgload --seconds 43200 --seed 1001 --rps 121 --mix-weights browse=91,card=18,wallet=12 > "$T/job121.json"
cp "$F" "$T/before121.env"; fresh
out=$(FORCE_READBACK_REFUSED=RBD_LOAD_RPS=130.0 bash "$LOADSH" set --rps 130 2> "$T/l6.err"); rc=$?
check "set, the new load.env refused on reading back (forced): exit 1 (rc $rc), the refusal seen" bash -c "[ $rc = 1 ] && grep -q 'forced refusal (test)' '$T/l6.err'"
check "...the old load.env (121 rps) kept byte for byte, no temporary file left" bash -c "cmp -s '$F' '$T/before121.env' && ! ls -a '$T/home' | grep -q '^\.load\.env\.'"
check "...the background load untouched (no kubectl call)" [ ! -s "$STUB_LOG" ]
check "...the last line: ok false, refused on reading back, nothing changed: load.env as it was" jqe --arg f "$F" '.ok == false and .action == "set" and (.error | contains("refused on reading back") and contains("nothing changed: \($f) as it was"))' <<< "$(tail -n 1 <<< "$out")"
check "...show: still 121 rps from load.env" bash -c "bash '$LOADSH' show | jq -e '.source == \"load.env\" and .rps == 121' > /dev/null"
fresh
STUB_BG_ACTIVE=1 STUB_BG_JOB=$T/job121.json bash "$BG" ensure 2> "$T/l6b.err"; rc=$?
check "...the next ensure, the Job running at 121: left alone (not restarted at the default)" bash -c "[ $rc = 0 ] && ! grep -q 'delete job' '$STUB_LOG' && ! ls '$STUB_DIR'/apply.* > /dev/null 2>&1"
fresh
out=$(bash "$LOADSH" reset 2> "$T/l5.err"); rc=$?
check "reset: exit 0, load.env removed, last line the default, restarted" bash -c "[ $rc = 0 ] && [ ! -e '$F' ] && [ \"\$(tail -n 1 <<< '$out' | jq -r '\"\(.action) \(.load.source) \(.restarted)\"')\" = 'reset default true' ]"
m=$(bg_apply); seed=$(envof "$m" LOAD_SEED)
check "...the background load restarted as render.py's Job without flags" bash -c "python3 -I '$REN' load --load-image '$LOADIMG' --name maze-bgload --seconds 43200 --seed '$seed' | cmp -s - '$m'"
check "...and as today's default Job, written out (LOAD_RPS \"100\", spec.json's LOAD_MIX)" pinned "$m" maze-bgload 43200.0
bash "$LOADSH" reset --no-restart > /dev/null 2>&1; check "reset with no load.env: exit 0" [ $? = 0 ]
fresh
out=$(FORCE_READBACK_REFUSED=RBD_LOAD_RPS=130.0 bash "$LOADSH" set --rps 130 2> "$T/l7.err"); rc=$?
check "set, refused on reading back (forced), no load.env before: exit 1 (rc $rc), still none, no temporary file, no kubectl call" bash -c "[ $rc = 1 ] && grep -q 'forced refusal (test)' '$T/l7.err' && [ ! -e '$F' ] && ! ls -a '$T/home' | grep -q '^\.load\.env\.' && [ ! -s '$STUB_LOG' ]"
check "...the last line: nothing changed: no load.env (spec.json's load)" jqe --arg f "$F" '.ok == false and (.error | contains("nothing changed: no \($f) (spec.json"))' <<< "$(tail -n 1 <<< "$out")"
rm -f "$T/bin/python3"; hash -r

echo "-- capture.sh at the setting"
D=$T/data; mkdir -p "$D"; printf '{"resourceSpans":[]}\n' > "$D/spans.jsonl"; touch -d 2026-10-31T09:02:00Z "$D/spans.jsonl"
echo '{"kind":"List","items":[]}' > "$T/k8s.json"
export FAKE_DATA=$D FAKE_K8S_JSON=$T/k8s.json
cat > "$T/bin/rhobound-fake" << 'EOF'
#!/usr/bin/env bash
# a fake rhobound: version; check RAW --window S,E --cut entry-start --out CUT --request-count RC --json: admitted
case $1 in
  version) echo "rhobound fake" ;;
  check) prev=""; for a in "$@"; do [ "$prev" != --out ] || out=$a; prev=$a; done
         mkdir -p "$out" && echo '{"fake":true}' > "$out/manifest.json"
         echo '{"verdict":"admitted","manifest_sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000007","counts":{}}' ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$T/bin/rhobound-fake"; export RBD_CLI=$T/bin/rhobound-fake
mklog() {   # mklog FILE RPS SECS SEED W_BROWSE W_CARD W_WALLET: a finished maze-load log in its own format
  python3 -I - "$@" << 'PY'
import json, sys
f, rps, secs, seed = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
w = [float(x) for x in sys.argv[5:8]]
n = int(rps * secs)
ok = [int(n * x / sum(w)) for x in w[:2]]
ok.append(n - sum(ok))
urls = ["http://storefront.maze.svc.cluster.local:8080/browse", "http://checkout.maze.svc.cluster.local:8080/buy/card",
        "http://checkout.maze.svc.cluster.local:8080/buy/wallet"]
lines = [f"2026/10/31 09:00:00 maze-load: {n} requests over {secs} s ({rps:.1f} rps), seed {seed}"]
for u, k, m in zip(urls, ok, (68.0, 88.0, 89.0)):
    lines.append(json.dumps({"errors": 0, "mean_ms": m, "ok": k, "p50_ms": m, "p95_ms": m * 2, "p99_ms": m * 3, "url": u}))
lines.append(f"2026/10/31 09:01:00 maze-load: done in {secs} s")
open(f, "w").write("\n".join(lines) + "\n")
PY
}
lm envfile --rates browse=91,card=18,wallet=12 > "$F"; chmod 0644 "$F"
mklog "$T/log121.json" 121 60 7 91 18 12
fresh
out=$(FAKE_LOAD_JSON=$T/log121.json bash "$CAP" c1 60 7 2> "$T/c1.err"); rc=$?; last=$(tail -n 1 <<< "$out")
C=$T/home/captures/c1
check "capture at 121 rps (P-M1 mix): exit 0 (rc $rc)" [ $rc = 0 ] || tail -8 "$T/c1.err"
check "...the window Job: LOAD_RPS 121.0, LOAD_MIX browse 91 / card 18 / wallet 12" bash -c "[ \"\$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == \"LOAD_RPS\") | .value' '$C/meta/load-job.json')\" = 121.0 ] && [ \"\$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == \"LOAD_MIX\") | .value' '$C/meta/load-job.json')\" = '[{\"url\":\"$SF\",\"w\":91.0},{\"url\":\"$CARD\",\"w\":18.0},{\"url\":\"$WALLET\",\"w\":12.0}]' ]"
bgm=$(bg_apply)
check "...the background load restarted after the window at the SAME rate and mix (not the default)" bash -c "[ -n '$bgm' ] && [ '$(loadenv "${bgm:-/dev/null}" 2> /dev/null)' = '$(loadenv "$C/meta/load-job.json")' ]"
order=$(grep -oE 'delete job maze-bgload|apply -f [^ ]*load-job.json|logs job/maze-load|exec spans-reader -c reader -- tar|apply -f -$' "$STUB_LOG" | sed -E 's#apply -f /.*load-job.json#apply -f load-job#' | tr '\n' '|')
check "...order: bgload stopped, window Job, its log, the copy, bgload started again ($order)" [ "$order" = "delete job maze-bgload|apply -f load-job|logs job/maze-load|exec spans-reader -c reader -- tar|delete job maze-bgload|apply -f -|" ]
check "...meta/capture.json: load = the setting (load.env, its sha256, 121 rps, the mix, per-entry rates)" \
  jqe --arg h "sha256:$(sha256sum "$F" | cut -d' ' -f1)" '.load.schema == "rbd.load/v1" and .load.source == "load.env" and .load.sha256 == $h
    and .load.rps == 121 and .load.mix == "browse=91.0,card=18.0,wallet=12.0" and .load.entries == {storefront: 91, checkout: 30} and .rps == 121' "$C/meta/capture.json"
nl=$(wc -l < "$T/log121.json")
check "...meta/load.json: the Job's log unchanged, then one rbd.load/v1 line = capture.json's load" bash -c "[ \$(wc -l < '$C/meta/load.json') = $((nl + 1)) ] && head -n $nl '$C/meta/load.json' | cmp -s - '$T/log121.json' && [ \"\$(tail -n 1 '$C/meta/load.json' | jq -cS .)\" = \"\$(jq -cS .load '$C/meta/capture.json')\" ]"
check "...verify's load_ok (done line, 3 '\"url\"' lines: the record adds none) accepts it" bash -c "grep -q 'maze-load: done in' '$C/meta/load.json' && [ \$(grep -c '\"url\"' '$C/meta/load.json') = 3 ]"
check "...verify's score.py parses it as before (3 URLs, no problem)" python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import score
w = score.parse_load(sys.argv[2])
sys.exit(0 if (len(w["urls"]) == 3 and not w["problems"] and w["requests"] == 7260 and w["done"]) else 1)' "$DEMO/verify" "$C/meta/load.json"
check "...loadlog.py reads the same window from it as from the bare log" bash -c "[ \"\$(python3 -I '$K/loadlog.py' '$C/meta/load.json' --seconds 60 --out '$T/rc1.json')\" = \"\$(python3 -I '$K/loadlog.py' '$T/log121.json' --seconds 60 --out '$T/rc2.json')\" ] && cmp -s '$T/rc1.json' '$T/rc2.json'"
check "...the last line names the load" jqe '.ok and (.load | startswith("121 rps (load.env)"))' <<< "$last"
check "...the log says it" grep -q 'window Job running for 60 s (seed 7; 121 rps (load.env)' "$T/c1.err"
rm -rf "$C"

rm -f "$F"; mklog "$T/log100.json" 100 60 7 0.7 0.18 0.12; fresh
printf '%s' "$(cat "$T/log100.json")" > "$T/log100n.json"   # a log whose last line has no newline
out=$(FAKE_LOAD_JSON=$T/log100n.json bash "$CAP" c2 60 7 2> "$T/c2.err"); rc=$?
C=$T/home/captures/c2
check "capture, no load.env: exit 0 (rc $rc)" [ $rc = 0 ] || tail -8 "$T/c2.err"
check "...a log without a final newline: the record still a line of its own" bash -c "[ \$(wc -l < '$C/meta/load.json') = 6 ] && sed -n 5p '$C/meta/load.json' | grep -qx '2026/10/31 09:01:00 maze-load: done in 60 s'"
check "...the window Job byte-identical to render.py's without --rps/--mix-weights (capture.sh passed no flags)" bash -c "python3 -I '$REN' load --load-image '$LOADIMG' --name maze-load --seconds 60 --seed 7 | cmp -s - '$C/meta/load-job.json'"
check "...today's default window Job, written out: LOAD_RPS \"100\", LOAD_SECONDS 60.0, LOAD_SEED 7, spec.json's LOAD_MIX" pinned "$C/meta/load-job.json" maze-load 60.0 7
m=$(bg_apply); seed=$(envof "$m" LOAD_SEED)
check "...the background load restarted as render.py's Job without flags" bash -c "python3 -I '$REN' load --load-image '$LOADIMG' --name maze-bgload --seconds 43200 --seed '$seed' | cmp -s - '$m'"
check "...and as today's default Job, written out" pinned "$m" maze-bgload 43200.0
check "...capture.json load: the default, 100 rps; load.json's last line the same" bash -c "jq -e '.load.source == \"default\" and .load.rps == 100 and .load.file == null' '$C/meta/capture.json' > /dev/null && [ \"\$(tail -n 1 '$C/meta/load.json' | jq -cS .)\" = \"\$(jq -cS .load '$C/meta/capture.json')\" ]"
rm -rf "$C"

lm envfile --rps 130 > "$F"; chmod 0644 "$F"; fresh
out=$(FAKE_LOAD_JSON=$T/log100.json bash "$CAP" c3 60 7 2> "$T/c3.err"); rc=$?
check "the Job's log says 100.0 rps, the setting 130: the capture fails (exit $rc)" bash -c "[ $rc = 1 ] && grep -q 'the window ran at 100.0 rps (the Job.s log), the load setting is 130.0 rps' '$T/c3.err'"
fd=$(ls -d "$T"/home/captures/c3.failed-* 2> /dev/null | head -n 1)
check "...kept as c3.failed-*, its load.json recorded at 130" bash -c "[ -n '$fd' ] && tail -n 1 '$fd/meta/load.json' | jq -e '.rps == 130' > /dev/null"
check "...the background load started again at 130 (the trap, the setting)" [ "$(envof "$(bg_apply)" LOAD_RPS)" = 130.0 ]
rm -rf "$T"/home/captures/c3.failed-*

chmod 0664 "$F"; fresh
out=$(FAKE_LOAD_JSON=$T/log100.json bash "$CAP" c4 60 7 2> "$T/c4.err"); rc=$?
check "a refused load.env: capture refused (exit $rc) with the reason in its last line" bash -c "[ $rc = 1 ] && tail -n 1 <<< '$out' | jq -e '.ok == false and (.error | test(\"the load setting is refused: .*group/other-writable\"))' > /dev/null"
check "...before anything was touched (no kubectl call, no capture folder)" bash -c "! grep -q kubectl '$STUB_LOG' && ! ls -a '$T/home/captures' | grep -q c4"
chmod 0644 "$F"; fresh
out=$(RBD_LOAD_RPS=100 FAKE_LOAD_JSON=$T/log100.json bash "$CAP" c5 60 7 2> "$T/c5.err"); rc=$?
check "RBD_LOAD_RPS=100 in the environment, load.env 130: capture refused (exit $rc), nothing touched" bash -c "[ $rc = 1 ] && grep -q 'never by the environment' '$T/c5.err' && ! grep -q kubectl '$STUB_LOG'"
check "the lock is free afterwards" [ "$( (. "$DEMO/tools1/lib/lock.sh"; RBD_LOCK_FILE=$T/home/lock rbd_lock_holder) )" = free ]
rm -rf "$D"
finish
