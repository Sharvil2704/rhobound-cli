#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Phase A of the real-cluster run: the repository's cluster test (e2e/e2e_test.go) in its external-cluster mode, on
# a k3s (or any Kubernetes) cluster, at three loads. The demo's services spread over the app nodes (so calls cross
# nodes), the load generator runs on the load node, and each level is 2 rounds of before/after windows (about 14
# minutes a level). Each level reports the model against the load generator's measured latency and change.
#
# Before it: label the app nodes rbv/role=app, label the load node rbv/role=load and taint it
# rbv/role=load:NoSchedule, and put the demo image on every app and load node (go run ./e2e/imagetar; see
# docs/REAL_CLUSTER.md, "How to reproduce it").
#
#   KUBECONFIG=/path/to/kubeconfig RBV_RESULTS=/path/to/results/<run id> bash validation/cluster/phase-a.sh
#   RBV_DRYRUN=1 bash validation/cluster/phase-a.sh     # choose and check the loads only: no cluster, nothing runs
#
# The loads come from the demo's true topology, examples/fanout-topology.json (the e2e test TestDemoTopology checks
# that it matches the services the test deploys). Every service is visited once per request, so service i is
# rps * s_i / (servers_i * workers_i) busy. Each level's rps puts the busiest service at about 0.35, 0.58 and
# 0.72. The change is the test's +8 ms in api, halved until no service is busier than RBV_AFTER_MAX (0.80) after
# it: +8, +4 and +2 ms, so api goes 0.35 -> 0.49, 0.58 -> 0.70 and 0.72 -> 0.79. The CLI refuses above --max-rho
# 0.85, and the service times read from a capture run a few percent high (the kind runs read api at 20.4-20.5 ms
# for 20). Halving rather than taking the largest change under the cap keeps level 2's after windows near 0.70:
# at 0.80 a 150-s window's mean is about twice as noisy and the test's steadiness gates trip in most runs.
# `rhobound model` checks every level: it must not refuse at --max-rho RBV_AFTER_MAX.
#
# Settings (environment):
#   KUBECONFIG           the cluster's kubeconfig file (required). Only this file is read; the test never
#                        touches the default kubeconfig or its context.
#   RBV_RESULTS          the run's results folder (required); this writes RBV_RESULTS/phase-a/
#   RBV_LEVELS           the levels to run (default "1 2 3")
#   RHOBOUND_E2E_ROUNDS  before/after rounds per level (default 2)
#   RBV_APP_SELECTOR     nodes for the demo services (default rbv/role=app)
#   RBV_LOAD_SELECTOR    the load generator's node (default rbv/role=load); its taint must use the same key
#   RBV_MAX_RHO          --max-rho passed to rhobound predict (default 0.85, the CLI's default)
#   RBV_AFTER_MAX        the most any service may be busy after the change (default 0.80)
#   RBV_CHANGES          the change at each level, ms, instead of the halving rule (e.g. "8 7.5 2"); the
#                        same checks apply
#   RBV_KEEP_NS=1        keep the demo's namespace (rb-e2e) at the end; it is deleted otherwise
#   RBV_SKIP_CHECKS=1    skip the cluster checks (image on the nodes, kubelet log limit)
#   RBV_DRYRUN=1         print the plan and stop
#   RBV_SUMMARY_ONLY=1   rebuild summary.md and summary.json from RBV_RESULTS/phase-a (needs no cluster)
#
# Writes RBV_RESULTS/phase-a/plan.tsv, L<level>/ (the test's work folder: result.json, captures, load generator
# outputs, test.log), summary.md and summary.json. Exit status: 0 when every level ran to a verdict (PASS, FAIL or
# UNSTABLE; the verdicts are results, not errors), 1 when a level could not run or the inputs are wrong.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
TOPO=$ROOT/examples/fanout-topology.json
LEVELS=${RBV_LEVELS:-1 2 3}
ROUNDS=${RHOBOUND_E2E_ROUNDS:-2}
APP_SEL=${RBV_APP_SELECTOR:-rbv/role=app}
LOAD_SEL=${RBV_LOAD_SELECTOR:-rbv/role=load}
MAX_RHO=${RBV_MAX_RHO:-0.85}
AFTER_MAX=${RBV_AFTER_MAX:-0.80}
CHANGE_SVC=api   # the service the test changes (EXTRA_MS)
CHANGE_MS=8      # the test's default change, ms
NS="rb-e2e"
LINE_BYTES=1100  # about one frontend span line on the node's disk (lineBytes in the test)
WINDOW_S=155     # a window's load generator run (runSecs + skipSecs in the test)

die() { echo "phase-a: $*" >&2; exit 1; }
say() { echo "phase-a: $*"; }

# the target utilization of the busiest service at each level
target() {
	case $1 in
	1) echo 0.35 ;;
	2) echo 0.58 ;;
	3) echo 0.72 ;;
	*) die "level $1: the levels are 1, 2 and 3" ;;
	esac
}

for t in go jq awk; do command -v $t >/dev/null || die "needs $t"; done
[ -f "$TOPO" ] || die "missing $TOPO"
[[ $ROUNDS =~ ^[1-9][0-9]*$ ]] || die "RHOBOUND_E2E_ROUNDS=$ROUNDS: want a positive whole number"
for l in $LEVELS; do target "$l" >/dev/null; done

DRY=${RBV_DRYRUN:-0}
if [ "$DRY" = 1 ]; then
	OUT=${RBV_RESULTS:+$RBV_RESULTS/phase-a}
	OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/phase-a-dry.XXXXXX")}
elif [ "${RBV_SUMMARY_ONLY:-0}" = 1 ]; then
	[ -n "${RBV_RESULTS:-}" ] || die "set RBV_RESULTS to the run's results folder"
	OUT=$RBV_RESULTS/phase-a
else
	[ -n "${KUBECONFIG:-}" ] || die "set KUBECONFIG to the cluster's kubeconfig file"
	[ -f "$KUBECONFIG" ] || die "KUBECONFIG=$KUBECONFIG: no such file"
	[[ $KUBECONFIG != *:* ]] || die "KUBECONFIG=$KUBECONFIG: give one file, not a list"
	[ -n "${RBV_RESULTS:-}" ] || die "set RBV_RESULTS to the run's results folder"
	command -v kubectl >/dev/null || die "needs kubectl"
	KUBECONFIG=$(cd "$(dirname "$KUBECONFIG")" && pwd)/$(basename "$KUBECONFIG")
	OUT=$RBV_RESULTS/phase-a
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# go test's temporary files go with the results, not to a small /tmp
mkdir -p "$OUT/tmp"
export TMPDIR=$OUT/tmp

# --- the summary (RBV_SUMMARY_ONLY=1 runs only this) -------------------------------------------------------------
# se: a standard error of the measured means from the load generator's 10-s window means (batch means; at these
# loads a queue forgets its state in about a second, so the 10-s means are close to independent). It says how much
# of a level's model error the measurement's own noise can explain; the test's gates do not use it.
se_of() { # the standard error of the mean over the given load generator outputs (one window each)
	local f
	for f in "$@"; do tail -n 1 "$f"; done | jq -s '
		map([.windows[]? | select(.start_s >= 5 and .n > 0) | .mean_ms]
			| length as $k | if $k < 2 then null else (add / $k) as $m
			| ((map((. - $m) * (. - $m)) | add) / ($k - 1) / $k) end)
		| if length == 0 or any(. == null) then null else (add | sqrt) / length end'
}
summarize() { # writes OUT/summary.md and summary.json from OUT/plan.tsv and each level's folder
	{
		echo "# Phase A: the cluster test on the external cluster"
		echo
		echo "Rounds per level: $(cat "$OUT"/L*/result.json 2>/dev/null | jq -r '.rounds // empty' | sort -u | paste -sd/ -)." \
			"Measured = the load generator's mean over the before (or after) windows; the"
		echo "change's ± is 2 standard errors of the measurement (from its 10-s window means). Model = rhobound predict on"
		echo "each before window's capture, averaged. True topology = rhobound model on $(basename "$TOPO") (the demo's"
		echo "true service times, 0.5 ms hops), for reference. Verdicts: PASS (within the test's gates), FAIL (the model"
		echo "outside them, or the CLI refused), UNSTABLE (a steadiness gate tripped: the numbers are reported, not"
		echo "judged), ERROR (the level did not finish)."
		echo
		echo "| level | rps | change | busiest before / after | measured ms | model ms | level err | true topology ms | measured change | predicted change | change err / se | true topology change | verdict | notes |"
		echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
	} >"$OUT/summary.md"
	echo '[]' >"$OUT/summary.json"
	while IFS=$'\t' read -r l tg rps d busiest rb ra mm mc; do
		[ "$l" = level ] && continue
		W=$OUT/L$l
		v=$(cat "$W/verdict" 2>/dev/null || echo "not run")
		r=$W/result.json
		[ -f "$r" ] || r=/dev/null
		shopt -s nullglob
		bf=("$W"/before*.loadgen.json)
		af=("$W"/after*.loadgen.json)
		shopt -u nullglob
		seb=null sea=null
		[ ${#bf[@]} -gt 0 ] && seb=$(se_of "${bf[@]}")
		[ ${#af[@]} -gt 0 ] && sea=$(se_of "${af[@]}")
		entry=$(jq -n --slurpfile res <(cat "$r" 2>/dev/null || true) --arg l "$l" --arg v "$v" --argjson rps "$rps" \
			--argjson d "$d" --arg b "$busiest" --argjson rb "$rb" --argjson ra "$ra" --argjson mm "$mm" --argjson mc "$mc" \
			--argjson seb "$seb" --argjson sea "$sea" '
			($res[0] // {}) as $x
			| (if ($x.model_windows // 0) > 0 then $x else {} end) as $m
			| {level: ($l | tonumber), rps: $rps, change_ms: $d, busiest: $b, rho_before: $rb, rho_after_max: $ra, verdict: $v,
				measured_before_ms: $x.before_measured_ms, measured_after_ms: $x.after_measured_ms,
				measured_change_ms: $x.observed_change_ms,
				se_before_ms: $seb, se_after_ms: $sea,
				se_change_ms: (if $seb == null or $sea == null then null else ($seb * $seb + $sea * $sea | sqrt) end),
				model_before_ms: $m.model_before_ms, predicted_change_ms: $m.predicted_change_ms,
				true_topology_model_ms: $mm, true_topology_change_ms: $mc,
				unstable: ($x.unstable // []), model_wrong: ($x.model_wrong // []), partial: ($x.partial // false),
				result: ($x | del(.windows))}')
		jq --argjson e "$entry" '. + [$e]' "$OUT/summary.json" >"$OUT/summary.json.new"
		mv "$OUT/summary.json.new" "$OUT/summary.json"
		jq -n -r --argjson e "$entry" '
			def f(n): if n == null then "-" else (n * 100 | round / 100 | tostring) end;
			def short: if length > 160 then .[0:157] + "..." else . end;
			$e
			| (if .model_before_ms == null or .measured_before_ms == null or .measured_before_ms == 0 then "-"
			   else ((.model_before_ms - .measured_before_ms) / .measured_before_ms * 1000 | round / 10 | tostring) + "%" end) as $lerr
			| (if .predicted_change_ms == null or .measured_change_ms == null or .se_change_ms == null or .se_change_ms == 0 then "-"
			   else ((.predicted_change_ms - .measured_change_ms) / .se_change_ms * 10 | round / 10 | tostring) end) as $z
			| ((.unstable + .model_wrong) | map(gsub("\\|"; "/") | short)) as $n
			| "| \(.level) | \(.rps) | \(.busiest) +\(.change_ms) ms | \(.busiest) \(.rho_before) / \(.rho_after_max) | \(f(.measured_before_ms)) | \(f(.model_before_ms)) | \($lerr) | \(.true_topology_model_ms) | \(f(.measured_change_ms))\(if .se_change_ms == null then "" else " ± " + f(2 * .se_change_ms) end) | \(f(.predicted_change_ms)) | \($z) | \(.true_topology_change_ms) | \(.verdict) | \($n[0:3] | join("; "))\(if ($n | length) > 3 then " (+\(($n | length) - 3) more)" else "" end) |"' >>"$OUT/summary.md"
	done <"$OUT/plan.tsv"
}

if [ "${RBV_SUMMARY_ONLY:-0}" = 1 ]; then
	[ -f "$OUT/plan.tsv" ] || die "RBV_SUMMARY_ONLY=1: no $OUT/plan.tsv"
	summarize
	cat "$OUT/summary.md"
	exit 0
fi

# the CLI, built from this tree (the test rebuilds the same binary)
RB=$ROOT/bin/rhobound
(cd "$ROOT" && go build -o "$RB" ./cmd/rhobound) || die "go build ./cmd/rhobound failed"

# --- choose the loads ---------------------------------------------------------------------------------------------
jq -e '
	[.services[].children // [] | .[]] as $ch
	| ($ch | all(type == "string"))
	and (($ch | group_by(.) | map(length) | max // 1) == 1)
	and (($ch | length) == (.services | length) - 1)
	and ((.entry | length) == 1) and ((.entry | to_entries[0].value) == 1)' "$TOPO" >/dev/null ||
	die "$TOPO is not a graph in which every service is visited once per request; this script cannot compute its loads"

# plan.tsv: level, target, rps, change ms, the busiest service and its utilization before the change, the highest
# utilization after it, and the true topology's model: entry latency and change
printf 'level\ttarget\trps\tchange_ms\tbusiest\trho_before\trho_after_max\tmodel_ms\tmodel_change_ms\n' >"$OUT/plan.tsv"
for l in $LEVELS; do
	tg=$(target "$l")
	given=""
	if [ -n "${RBV_CHANGES:-}" ]; then
		read -r -a ch <<<"$RBV_CHANGES"
		[ "${#ch[@]}" -ge "$l" ] || die "RBV_CHANGES=\"$RBV_CHANGES\": no change for level $l (one per level 1, 2, 3)"
		given=${ch[$((l - 1))]}
		[[ $given =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "RBV_CHANGES: $given is not a number of ms"
	fi
	row=$(jq -r --argjson tg "$tg" --argjson amax "$AFTER_MAX" --argjson dmax "$CHANGE_MS" --arg csvc "$CHANGE_SVC" --arg given "$given" '
		def cap: ([.servers // 1, 1] | max) * ([.workers // 1, 1] | max);
		[.services[] | {name, s, cap: cap, u: (.s / 1000 / cap)}] as $sv
		| ($sv | max_by(.u)) as $b
		| (($tg / $b.u) | round) as $rps
		| ($sv[] | select(.name == $csvc)) as $c
		# the default change, halved until the changed service is at amax or below (or a given one)
		| (if $given != "" then ($given | tonumber)
		   else [limit(8; $dmax | recurse(. / 2))] | map(select(($c.s + .) / 1000 / $c.cap * $rps <= $amax + 1e-9)) | (.[0] // 0)
		   end) as $d
		| ([$sv[] | (if .name == $csvc then (.s + $d) else .s end) / 1000 / .cap * $rps] | max) as $after
		| [$rps, $d, $b.name, ($b.u * $rps), $after] | @tsv' "$TOPO")
	[ -n "$row" ] || die "level $l: $TOPO has no service $CHANGE_SVC"
	read -r rps d busiest rb ra <<<"$row"
	awk -v d="$d" 'BEGIN { exit !(d >= 0.5) }' ||
		die "level $l: the change ($d ms) is under 0.5 ms: no halving of $CHANGE_MS ms keeps $CHANGE_SVC at $AFTER_MAX or below at $rps requests/s"
	awk -v a="$ra" -v m="$AFTER_MAX" 'BEGIN { exit !(a <= m + 1e-9) }' ||
		die "level $l: after $CHANGE_SVC +$d ms a service is busier than $AFTER_MAX ($ra) at $rps requests/s"
	# the check: the model on the true topology, which refuses a load above --max-rho before or after the change
	if ! rep=$("$RB" model "$TOPO" --rps "$rps" --patch "$CHANGE_SVC=+${d}ms" --max-rho "$AFTER_MAX" --json 2>"$OUT/model-L$l.err"); then
		cat "$OUT/model-L$l.err" >&2
		die "level $l: rhobound model refuses $rps requests/s with $CHANGE_SVC +${d} ms at --max-rho $AFTER_MAX"
	fi
	echo "$rep" >"$OUT/model-L$l.json"
	mu=$(jq -r '.max_utilization' <<<"$rep")
	mb=$(jq -r '.busiest_service' <<<"$rep")
	awk -v u="$mu" -v t="$tg" 'BEGIN { exit !(u >= t - 0.02 && u <= t + 0.02) }' ||
		die "level $l: rhobound model puts $mb at $mu, not about $tg"
	[ "$mb" = "$busiest" ] || die "level $l: rhobound model's busiest service is $mb, this script's $busiest"
	mm=$(jq -r '.services[] | select(.entry) | .model_ms' <<<"$rep")
	mc=$(jq -r '.services[] | select(.entry) | .change_ms' <<<"$rep")
	printf '%s\t%s\t%s\t%s\t%s\t%.3f\t%.3f\t%.2f\t%.2f\n' "$l" "$tg" "$rps" "$d" "$busiest" "$mu" "$ra" "$mm" "$mc" >>"$OUT/plan.tsv"
done

per_window=200 # s: a 150-s window, its 5-s skip, the rollouts, settling and the capture (the kind runs took ~190 s)
n_levels=$(wc -w <<<"$LEVELS")
est=$(((n_levels * (60 + ROUNDS * 2 * per_window) + 59) / 60))
say "plan ($ROUNDS rounds a level, about $est minutes in all; true topology $TOPO):"
if command -v column >/dev/null; then column -t -s $'\t' "$OUT/plan.tsv"; else cat "$OUT/plan.tsv"; fi | sed 's/^/  /'
if [ "$DRY" = 1 ]; then
	say "RBV_DRYRUN=1: stopping here (plan in $OUT/plan.tsv)"
	exit 0
fi

# --- check the cluster --------------------------------------------------------------------------------------------
k() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
app_nodes=$(k get nodes -l "$APP_SEL" -o jsonpath='{.items[*].metadata.name}')
load_nodes=$(k get nodes -l "$LOAD_SEL" -o jsonpath='{.items[*].metadata.name}')
[ -n "$app_nodes" ] || die "no node matches $APP_SEL"
[ -n "$load_nodes" ] || die "no node matches $LOAD_SEL"
say "app nodes: $app_nodes; load node(s): $load_nodes"
[ "$(wc -w <<<"$app_nodes")" -ge 2 ] || say "warning: one app node: no call crosses nodes"
if [ "${RBV_SKIP_CHECKS:-0}" != 1 ]; then
	# the image, as each kubelet reports it (node status lists up to 50 images, the largest first)
	missing=$(k get nodes -o json | jq -r --arg nodes "$app_nodes $load_nodes" '
		($nodes | split(" ") | map(select(. != ""))) as $want
		| .items[] | select(.metadata.name as $n | $want | index($n))
		| select([.status.images[]?.names[]?] | index("docker.io/library/rhobound-demo:e2e") | not) | .metadata.name')
	[ -z "$missing" ] || die "rhobound-demo:e2e is not on: $missing (load it with: go run ./e2e/imagetar; RBV_SKIP_CHECKS=1 skips this check)"
	# the kubelet's log limit: kubectl logs reads only the current file, so a rotation inside a window loses spans
	maxrps=$(awk -F'\t' 'NR > 1 && $3 > m { m = $3 } END { print m }' "$OUT/plan.tsv")
	need=$((2 * maxrps * WINDOW_S * LINE_BYTES))
	for n in $app_nodes; do
		lim=$(k get --raw "/api/v1/nodes/$n/proxy/configz" 2>/dev/null | jq -r '.kubeletconfig.containerLogMaxSize // empty' || true)
		bytes=$(awk -v q="$lim" 'BEGIN {
			n = q + 0; u = q; sub(/^[0-9.]+/, "", u)
			m["Ki"] = 1024; m["Mi"] = 1048576; m["Gi"] = 1073741824; m["K"] = 1000; m["k"] = 1000; m["M"] = 1e6; m["G"] = 1e9; m[""] = 1
			if (q == "" || !(u in m)) print 0; else printf "%.0f", n * m[u] }')
		if [ "$bytes" = 0 ]; then
			say "warning: node $n: the kubelet's containerLogMaxSize could not be read (the test checks it again)"
		elif [ "$bytes" -lt "$need" ]; then
			die "node $n: the kubelet rotates container logs at $lim, under twice the frontend's log at $maxrps requests/s ($((need / 1048576)) MiB): spans would be lost. Give the kubelets container-log-max-size=100Mi (k3s: --kubelet-arg=container-log-max-size=100Mi), or RBV_SKIP_CHECKS=1"
		fi
	done
fi

# --- run the levels -----------------------------------------------------------------------------------------------
status=0
while IFS=$'\t' read -r l tg rps d busiest rb ra mm mc; do
	[ "$l" = level ] && continue
	W=$OUT/L$l
	mkdir -p "$W"
	tmo=$((15 + ROUNDS * 2 * 5))
	say "level $l: $rps requests/s, $CHANGE_SVC +${d} ms ($busiest ${rb} -> at most ${ra}), $ROUNDS rounds, timeout ${tmo}m; log $W/test.log"
	set +e
	(
		cd "$ROOT" &&
			env -u KUBECONFIG RHOBOUND_E2E=1 RHOBOUND_E2E_KUBECONFIG="$KUBECONFIG" RHOBOUND_E2E_IMAGE_LOADED=1 \
				RHOBOUND_E2E_RPS="$rps" RHOBOUND_E2E_EXTRA_MS="$d" RHOBOUND_E2E_MAX_RHO="$MAX_RHO" \
				RHOBOUND_E2E_APP_SELECTOR="$APP_SEL" RHOBOUND_E2E_LOAD_SELECTOR="$LOAD_SEL" RHOBOUND_E2E_SPREAD=1 \
				RHOBOUND_E2E_ROUNDS="$ROUNDS" RHOBOUND_E2E_WORK="$W" \
				go test -tags e2e -v -count=1 -timeout "${tmo}m" -run '^TestClusterEndToEnd$' ./e2e
	) </dev/null 2>&1 | tee "$W/test.log"
	rc=${PIPESTATUS[0]}
	set -e
	if grep -q -- '--- PASS: TestClusterEndToEnd' "$W/test.log"; then
		v=PASS
	elif grep -q -- '--- SKIP: TestClusterEndToEnd' "$W/test.log"; then
		v=UNSTABLE
	elif grep -q -- '--- FAIL: TestClusterEndToEnd' "$W/test.log" && [ -f "$W/result.json" ] &&
		jq -e '.partial != true' "$W/result.json" >/dev/null; then
		v=FAIL
	else
		v=ERROR # it stopped before its verdict (setup, a timeout, a crash): see test.log
		status=1
	fi
	echo "$v" >"$W/verdict"
	say "level $l: $v (go test exit $rc)"
done <"$OUT/plan.tsv"

if [ "${RBV_KEEP_NS:-0}" != 1 ]; then
	# wait, so that a run straight after this one does not find the namespace still terminating
	k delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s >/dev/null || say "warning: could not delete namespace $NS"
fi

# --- the summary --------------------------------------------------------------------------------------------------
summarize
echo
cat "$OUT/summary.md"
say "results in $OUT (summary.md, summary.json, L<level>/result.json and test.log)"
exit $status
