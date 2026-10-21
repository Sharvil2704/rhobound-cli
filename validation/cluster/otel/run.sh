#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Phase B of the real-cluster run: real software. The OpenTelemetry Demo (the Astronomy Shop) on a k3s (or any
# Kubernetes) cluster, with its own load generator; its Collector also writes the traces as OTLP/JSON; a steady
# window of them is copied back, and `rhobound infer` and `rhobound predict` run on it. Every refusal and warning of
# the CLI is a finding: this is software nobody shaped for the model.
#
# Before it: label the load node rbv/role=load and taint it rbv/role=load:NoSchedule (or set RBV_LOAD_SELECTOR to
# your own key=value, or to the empty string for no placement); docs/REAL_CLUSTER.md, "How to reproduce it", has
# the whole procedure.
#
#   KUBECONFIG=/path/to/kubeconfig RBV_RESULTS=/path/to/results/<run id> bash validation/cluster/otel/run.sh
#   RBV_RESULTS=DIR bash validation/cluster/otel/run.sh plan   # render and check the manifests only: no cluster
#
# Subcommands (default: all = deploy, capture, analyze, then down unless RBV_KEEP_NS=1):
#   plan      fetch the pinned manifest, check its sha256, render it with the kit's patches (kubectl's built-in
#             kustomize; helm is not needed), and print what runs where and the memory it may take. No cluster.
#             RBV_DRYRUN=1 makes every subcommand stop after this.
#   prepull   pull the demo's images on the nodes ahead of deploy (k3s crictl over RBV_SSH, the nodes in parallel):
#             run it during the cluster set-up, before Phase A, to take the pulls (about 5 minutes) out of Phase B's
#             time. Docker Hub images only on nodes with a docker.io mirror (see below). Optional.
#   deploy    plan, then apply it (server-side) and wait until the demo is ready
#   capture   run each load mix (RBV_OTEL_MIXES) for a warm-up and a window, and copy the trace file back
#   analyze   cut each window out of the copied file, describe it, run the CLI (and its diagnostic variants when it
#             refuses), and write the summary. Needs no cluster.
#   down      delete the demo (its namespace and its cluster-wide RBAC objects)
#
# The release: OpenTelemetry Demo 2.2.0, kubernetes/opentelemetry-demo.yaml at the tag, sha256 pinned below. It is the
# last release with generated Kubernetes manifests (3.0.0 removed them, open-telemetry/opentelemetry-demo#3236); the
# file was generated for the 2.1.3 service images (ghcr.io/open-telemetry/demo:2.1.3-*), with
# otel/opentelemetry-collector-contrib:0.135.0. Everything is applied as shipped except:
#   - the Collector: a second --config (collector-rhobound.yaml) adds a file exporter to the traces pipeline, writing
#     OTLP/JSON to an emptyDir; a busybox sidecar shares the folder (the Collector image is scratch: no shell, no
#     tar) so the file can be copied out; the memory limit goes from 200Mi to RBV_OTEL_COLLECTOR_MEM (GOMEMLIMIT
#     with it): at the load below, the shipped 200Mi would let its memory_limiter refuse spans, and a refused span
#     breaks its trace. The shipped pipelines, processors (k8sattributes, resource) and exporters are unchanged.
#   - the load generator (Locust): on the load node (RBV_LOAD_SELECTOR, with a toleration of its taint);
#     RBV_OTEL_USERS users instead of 10 (10 users with its 1-10 s waits send about 2 requests/s); its Playwright
#     browser users off (LOCUST_BROWSER_TRAFFIC_ENABLED=true runs a headless Chromium for half the users: at 100
#     users that is 50 browsers, which its 1500Mi limit does not hold, and their page loads add asset and image
#     requests in bursts). RBV_OTEL_BROWSER=1 keeps them.
#   - Jaeger's memory limit (its in-memory trace store, on no request path): 400Mi -> RBV_OTEL_JAEGER_MEM. In an earlier
#     trial run on a single-node kind cluster at 100 users it was OOM-killed at 400Mi inside a window, and not at 1Gi; a Jaeger that restarts makes
#     the Collector queue and retry its spans, in memory.
# Left as shipped, though they restart under this load on kind: flagd-ui (flagd's flag editor, in flagd's pod, on no
# request path; OOM-killed at 250Mi and at 512Mi alike), so a required workload counts as ready when its container
# of the same name is (flagd); and accounting, a Kafka consumer (OOM-killed at 120Mi in the shipped mix). Restarts
# in a window are listed in the summary, apart for the containers on no request path.
#
# The load mixes (RBV_OTEL_MIXES, run in order, one window each):
#   shipped   the load generator's own task mix (nine tasks: home page, product pages, recommendations, ads, cart,
#             add to cart, checkout, multi-item checkout, the flood flag check)
#   browse    only its browse_product task (locustfile_browse.py imports the shipped file and runs that task), so
#             that every frontend visit is one GET /api/products/{id}: one shape of calls, which the CLI can model,
#             where the shipped mix's frontend visits call different services different numbers of times
# Between mixes the load generator is restarted with the new mix and the services are warmed up again.
#
# Diagnostic variants (analyze, only when the CLI refuses the capture as captured; RBV_OTEL_VARIANTS): the same
# window cut again by otelcap with a change that removes one cause found in that trial run on kind, each reported apart
# and labelled, never as the capture's result:
#   nested       two nested spans of one kind in one pod become one (otelcap cut -nested-internal): Next.js opens a
#                SERVER span inside the HTTP instrumentation's (the CLI reads frontend -> frontend, a cycle), and
#                .NET's gRPC client wraps the HTTP client's CLIENT span in its own (two calls read for one)
#   nested-drop  and the spans of RBV_OTEL_DROP (default flagd) left out, so the calls to it are outside delays:
#                the flag lookups of some services join flagd's spans to their trace and others do not (Java and
#                Python lookups timed out at 500 ms on kind), which the CLI counts as lost spans
#
# No change is measured in this phase: none of the demo's feature flags changes a service's work per request by a
# known amount (adHighCpu loads the CPU of the ad pod's node; the others inject failures or delays the CLI does not
# model), and a CPU limit would throttle, which the CLI does not model either. So: level and structure only.
#
# Docker Hub: the demo pulls about 8 images from docker.io (the Collector, Jaeger, OpenSearch, Grafana, Valkey,
# busybox). When the nodes leave through one shared public address (a NAT), Docker Hub's anonymous pull limit counts
# them as one client. A docker.io mirror in each node's /etc/rancher/k3s/registries.yaml (k3s still falls back to
# Docker Hub) avoids it; deploy warns when a node has none (if RBV_SSH is set), and stops with a message on a 429.
#
# Settings (environment):
#   KUBECONFIG              the cluster's kubeconfig file (deploy, capture, down). Only this file is used; the default
#                           kubeconfig and its context are never read or changed.
#   RBV_RESULTS             the run's results folder (required); this writes RBV_RESULTS/phase-b/
#   RBV_OTEL_MIXES          the load mixes, in order (default "shipped browse")
#   RBV_OTEL_USERS          Locust users (default 100: about 20 requests/s into the frontend proxy)
#   RBV_OTEL_SPAWN_RATE     users started per second (default 10)
#   RBV_OTEL_WARMUP_S       warm-up before the first window, s (default 180)
#   RBV_OTEL_REWARM_S       warm-up after a mix change, s (default 120)
#   RBV_OTEL_WINDOW_S       each window, s (default 420)
#   RBV_OTEL_GRACE_S        wait after a window before the copy, so its last traces are written, s (default 20)
#   RBV_OTEL_BROWSER=1      keep the load generator's browser users (default off)
#   RBV_OTEL_COLLECTOR_MEM  the Collector's memory limit (default 1Gi); RBV_OTEL_GOMEMLIMIT (default 800MiB)
#   RBV_OTEL_JAEGER_MEM     Jaeger's memory limit (default 1Gi)
#   RBV_OTEL_READY_TIMEOUT  s to wait for the demo to be ready (default 900)
#   RBV_OTEL_OPTIONAL_WAIT  s to wait for the parts the capture does not need once the rest is ready (default 120)
#   RBV_LOAD_SELECTOR       the load generator's node, key=value (default rbv/role=load, as in Phase A); its taint
#                           must be key=value:NoSchedule. Empty: no node selector and no toleration.
#   RBV_OTEL_PREDICT_ARGS   more arguments for rhobound predict and infer (e.g. "--workers frontend=8")
#   RBV_OTEL_VARIANTS       diagnostic variants when the CLI refuses (default "nested nested-drop"; empty: none)
#   RBV_OTEL_VARIANTS_ALWAYS=1  run them even when the CLI does not refuse
#   RBV_OTEL_DROP           the services nested-drop leaves out (default "flagd")
#   RBV_OTEL_MANIFEST       a local copy of the release's manifest instead of the download (its sha256 is checked)
#   RBV_SSH                 optional: an ssh command that reaches the nodes by the aliases w1..wN (the app nodes) and
#                           load (the load node), such as "ssh -F my-ssh-config". Used by prepull and by the
#                           docker.io mirror check; everything else needs only KUBECONFIG
#   RBV_N_WORKERS           the number N of app nodes w1..wN for RBV_SSH (default 3)
#   RBV_KEEP_NS=1           keep the demo running after 'all'
#   RBV_DRYRUN=1            plan only, whatever the subcommand
#
# Writes RBV_RESULTS/phase-b/: manifest/ (the upstream file, the kustomization, rendered.yaml, plan.txt), timing.tsv,
# pods.txt and nodes.txt, and per mix <mix>/: window.json, raw/spans.jsonl.gz (the Collector's whole file at the
# copy), collector.log, top-*.txt, pods.txt, and per variant v-<variant>/ (captured first): capture/traces/
# spans.jsonl.gz (the window), cut.json, stats.json (otelcap), infer.json/.err/.rc, predict.json/.err/.rc/.txt; then
# summary.md and summary.json. Exit status: 0 when every step ran (a refusal of the CLI is a result, not an error),
# 1 when a step could not run.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)

OTEL_VERSION=2.2.0
MANIFEST_URL=https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/$OTEL_VERSION/kubernetes/opentelemetry-demo.yaml
MANIFEST_SHA256=6d7e60bf1ba71a68d79ab3cac39482ab46627759ddcfcdb4e6a1d0645092ca3c
SHIPPED_TRACE_EXPORTERS="otlp debug spanmetrics" # the pinned relay's traces exporters; collector-rhobound.yaml lists them
NS=otel-demo
SIDECAR_IMAGE=docker.io/library/busybox:1.37.0
FIELD_MANAGER=rbv-phase-b
# what the capture needs ready; a required workload counts as ready when its container of the same name is (flagd's
# pod also runs flagd-ui, which the capture does not need)
REQUIRED="otel-collector load-generator frontend-proxy frontend product-catalog currency cart checkout ad recommendation shipping quote payment email flagd kafka valkey-cart"
# containers on no request path (restarts are listed apart): telemetry back ends, the flag editor, the Kafka consumers
OFF_PATH="jaeger grafana grafana-sc-alerts grafana-sc-dashboard grafana-sc-datasources prometheus-server opensearch flagd-ui accounting fraud-detection"

MIXES=${RBV_OTEL_MIXES:-shipped browse}
USERS=${RBV_OTEL_USERS:-100}
SPAWN=${RBV_OTEL_SPAWN_RATE:-10}
WARMUP_S=${RBV_OTEL_WARMUP_S:-180}
REWARM_S=${RBV_OTEL_REWARM_S:-120}
WINDOW_S=${RBV_OTEL_WINDOW_S:-420}
GRACE_S=${RBV_OTEL_GRACE_S:-20}
BROWSER=${RBV_OTEL_BROWSER:-0}
COLL_MEM=${RBV_OTEL_COLLECTOR_MEM:-1Gi}
COLL_GOMEM=${RBV_OTEL_GOMEMLIMIT:-800MiB}
JAEGER_MEM=${RBV_OTEL_JAEGER_MEM:-1Gi}
READY_TIMEOUT=${RBV_OTEL_READY_TIMEOUT:-900}
OPTIONAL_WAIT=${RBV_OTEL_OPTIONAL_WAIT:-120}
LOAD_SEL=${RBV_LOAD_SELECTOR-rbv/role=load}
VARIANTS=${RBV_OTEL_VARIANTS-nested nested-drop}
DROP=${RBV_OTEL_DROP:-flagd}
read -r -a PREDICT_ARGS <<<"${RBV_OTEL_PREDICT_ARGS:-}"
DRY=${RBV_DRYRUN:-0}

die() { echo "phase-b: $*" >&2; exit 1; }
say() { echo "phase-b: $*"; }

case ${1:-} in -h | --help | help)
	awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
	exit 0
	;;
esac

for v in USERS SPAWN WARMUP_S REWARM_S WINDOW_S GRACE_S READY_TIMEOUT OPTIONAL_WAIT; do
	[[ ${!v} =~ ^[0-9]+$ ]] || die "$v=${!v}: want a whole number"
done
[ "$USERS" -ge 1 ] || die "RBV_OTEL_USERS must be at least 1"
[ "$WINDOW_S" -ge 60 ] || die "RBV_OTEL_WINDOW_S must be at least 60"
for m in $MIXES; do
	case $m in shipped | browse) ;; *) die "RBV_OTEL_MIXES: unknown mix '$m' (shipped, browse)" ;; esac
done
for v in $VARIANTS; do
	case $v in nested | nested-drop) ;; *) die "RBV_OTEL_VARIANTS: unknown variant '$v' (nested, nested-drop)" ;; esac
done
for m in COLL_MEM JAEGER_MEM; do
	[[ ${!m} =~ ^[0-9]+(Mi|Gi)$ ]] || die "$m=${!m}: want a size such as 512Mi or 1Gi"
done
if [ -n "$LOAD_SEL" ]; then
	[[ $LOAD_SEL =~ ^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+$ ]] || die "RBV_LOAD_SELECTOR=$LOAD_SEL: want one key=value"
fi

for t in jq awk sha256sum kubectl curl; do command -v $t >/dev/null || die "needs $t"; done

[ -n "${RBV_RESULTS:-}" ] || die "set RBV_RESULTS to the run's results folder"
mkdir -p "$RBV_RESULTS/phase-b"
OUT=$(cd "$RBV_RESULTS/phase-b" && pwd)
MAN=$OUT/manifest
mkdir -p "$OUT/tmp"
export TMPDIR=$OUT/tmp # go's and mktemp's files go with the results, not to a small /tmp

need_cluster() {
	[ -n "${KUBECONFIG:-}" ] || die "set KUBECONFIG to the cluster's kubeconfig file"
	[ -f "$KUBECONFIG" ] || die "KUBECONFIG=$KUBECONFIG: no such file"
	[[ $KUBECONFIG != *:* ]] || die "KUBECONFIG=$KUBECONFIG: give one file, not a list"
	KUBECONFIG=$(cd "$(dirname "$KUBECONFIG")" && pwd)/$(basename "$KUBECONFIG")
}
k() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
kn() { k -n "$NS" "$@"; }
# YAML to JSON (an array of the objects) with no cluster: kubectl's local mode. The label is never applied.
yaml_json() { KUBECONFIG=/dev/null kubectl label --local -f "$1" rbv-inspect=1 -o json | jq -s '[.[] | if .kind == "List" then .items[] else . end]'; }
stamp() { printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "$(date -u +%FT%TZ)" >>"$OUT/timing.tsv"; }
nodes_ssh() { seq 1 "${RBV_N_WORKERS:-3}" | sed 's/^/w/'; echo load; } # the RBV_SSH aliases of the nodes pods run on

# --- plan ---------------------------------------------------------------------------------------------------------
fetch_manifest() {
	mkdir -p "$MAN"
	local up=$MAN/upstream.yaml
	if [ -n "${RBV_OTEL_MANIFEST:-}" ]; then
		cp -- "$RBV_OTEL_MANIFEST" "$up"
	elif [ ! -f "$up" ] || ! echo "$MANIFEST_SHA256  $up" | sha256sum -c --status; then
		say "fetching $MANIFEST_URL"
		curl -fsSL --retry 3 -o "$up.part" "$MANIFEST_URL" || die "download of the demo's manifest failed"
		mv "$up.part" "$up"
	fi
	echo "$MANIFEST_SHA256  $up" | sha256sum -c --status ||
		die "$up: sha256 $(sha256sum "$up" | awk '{print $1}') is not the pinned $MANIFEST_SHA256 (release $OTEL_VERSION)"
}

# the traces pipeline's exporters in the shipped Collector config (the relay key of ConfigMap otel-collector)
shipped_trace_exporters() {
	jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "otel-collector") | .data.relay' "$MAN/upstream.json" |
		awk '
			/^  pipelines:/ { inp = 1; next }
			inp && /^    traces:/ { intr = 1; next }
			intr && /^    [a-z]/ { intr = 0 }
			intr && /^      exporters:/ { inx = 1; next }
			inx && /^      - / { sub(/^      - /, ""); printf "%s%s", sep, $0; sep = " "; next }
			inx { inx = 0 }
			END { print "" }'
}

write_kustomization() {
	cp -- "$HERE/collector-rhobound.yaml" "$MAN/collector-rhobound.yaml"
	cp -- "$HERE/locustfile_browse.py" "$MAN/locustfile_browse.py"
	local browser=false sel="      nodeSelector: {}" tol="      tolerations: []"
	[ "$BROWSER" = 1 ] && browser=true
	if [ -n "$LOAD_SEL" ]; then
		local key=${LOAD_SEL%%=*} val=${LOAD_SEL#*=}
		sel=$(printf '      nodeSelector:\n        %s: "%s"' "$key" "$val")
		tol=$(printf '      tolerations:\n      - key: "%s"\n        operator: Equal\n        value: "%s"\n        effect: NoSchedule' "$key" "$val")
	fi
	cat >"$MAN/kustomization.yaml" <<EOF
# Generated by validation/cluster/otel/run.sh: OpenTelemetry Demo $OTEL_VERSION as shipped, plus the capture.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Most of the shipped objects name no namespace (the demo's docs apply the file with -n $NS): this puts every
# namespaced object in $NS, whatever the kubeconfig's default namespace is.
namespace: $NS
resources:
- upstream.yaml
configMapGenerator:
- name: rbv-collector-config
  files:
  - rhobound.yaml=collector-rhobound.yaml
- name: rbv-locust
  files:
  - locustfile_browse.py
generatorOptions:
  disableNameSuffixHash: true
  labels:
    app.kubernetes.io/part-of: rbv-phase-b
# targets by kind and name: the patches apply before the namespace above, to objects with and without one
patches:
- path: patch-collector.yaml
  target:
    kind: Deployment
    name: otel-collector
- path: patch-load-generator.yaml
  target:
    kind: Deployment
    name: load-generator
- path: patch-jaeger.yaml
  target:
    kind: Deployment
    name: jaeger
EOF
	cat >"$MAN/patch-collector.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
spec:
  template:
    spec:
      containers:
      - name: opentelemetry-collector
        args:
        - --config=/conf/relay.yaml
        - --config=/conf-rhobound/rhobound.yaml
        env:
        - name: GOMEMLIMIT
          value: "$COLL_GOMEM"
        resources:
          limits:
            memory: "$COLL_MEM"
        volumeMounts:
        - name: rbv-collector-config
          mountPath: /conf-rhobound
          readOnly: true
        - name: rbv-capture
          mountPath: /capture
      - name: rbv-capture
        image: $SIDECAR_IMAGE
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "trap 'exit 0' TERM; while :; do sleep 3600 & wait \$!; done"]
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 256Mi
        volumeMounts:
        - name: rbv-capture
          mountPath: /capture
      volumes:
      - name: rbv-collector-config
        configMap:
          name: rbv-collector-config
      - name: rbv-capture
        emptyDir:
          sizeLimit: 20Gi
EOF
	cat >"$MAN/patch-load-generator.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: load-generator
spec:
  template:
    spec:
$sel
$tol
      containers:
      - name: load-generator
        env:
        - name: LOCUST_USERS
          value: "$USERS"
        - name: LOCUST_SPAWN_RATE
          value: "$SPAWN"
        - name: LOCUST_BROWSER_TRAFFIC_ENABLED
          value: "$browser"
        volumeMounts:
        - name: rbv-locust
          mountPath: /rbv
          readOnly: true
      volumes:
      - name: rbv-locust
        configMap:
          name: rbv-locust
EOF
	cat >"$MAN/patch-jaeger.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
spec:
  template:
    spec:
      containers:
      - name: jaeger
        resources:
          limits:
            memory: "$JAEGER_MEM"
EOF
}

cmd_plan() {
	fetch_manifest
	yaml_json "$MAN/upstream.yaml" >"$MAN/upstream.json"
	local got
	got=$(shipped_trace_exporters)
	[ "$got" = "$SHIPPED_TRACE_EXPORTERS" ] ||
		die "the shipped traces pipeline exports to '$got', not '$SHIPPED_TRACE_EXPORTERS': collector-rhobound.yaml would drop or miss one"
	write_kustomization
	KUBECONFIG=/dev/null kubectl kustomize "$MAN" >"$MAN/rendered.yaml" || die "kubectl kustomize $MAN failed"
	yaml_json "$MAN/rendered.yaml" >"$MAN/rendered.json"
	jq -e --rawfile c "$HERE/collector-rhobound.yaml" '
		[.[] | select(.kind == "ConfigMap" and .metadata.name == "rbv-collector-config") | .data["rhobound.yaml"] == $c] == [true]' \
		"$MAN/rendered.json" >/dev/null || die "the rendered rbv-collector-config is not collector-rhobound.yaml"
	jq -e '[.[] | select(.kind == "Deployment" and .metadata.name == "otel-collector") | .spec.template.spec.containers[]
		| select(.name == "opentelemetry-collector") | .args] == [["--config=/conf/relay.yaml", "--config=/conf-rhobound/rhobound.yaml"]]' \
		"$MAN/rendered.json" >/dev/null || die "the rendered Collector does not take both configs"
	jq -e --arg ns "$NS" '[.[] | select(.kind != "Namespace" and (.kind | test("^Cluster") | not)) | .metadata.namespace == $ns] | all' \
		"$MAN/rendered.json" >/dev/null || die "some rendered object is not in namespace $NS"
	{
		echo "OpenTelemetry Demo $OTEL_VERSION ($MANIFEST_URL, sha256 $MANIFEST_SHA256)"
		echo "load mixes: $MIXES; $USERS Locust users (spawn $SPAWN/s), browser users $([ "$BROWSER" = 1 ] && echo on || echo off);" \
			"warm-up ${WARMUP_S}s, re-warm ${REWARM_S}s, window ${WINDOW_S}s"
		echo "load generator on: ${LOAD_SEL:-any node}; everything else where the scheduler puts it (untainted nodes)"
		echo "diagnostic variants when the CLI refuses: ${VARIANTS:-none} (nested-drop leaves out: $DROP)"
		echo
		# memory: the containers' limits (most of the demo sets limits only); cpu: requests (only opensearch has one)
		jq -r '
			def mem: if . == null then 0 else (tostring | capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$") as $m
				| ($m.n | tonumber) * ({"": 0.00000095367, "Ki": 0.0009765625, "Mi": 1, "Gi": 1024, "K": 0.00095367, "M": 0.95367, "G": 953.67}[$m.u] // 0)) end;
			def cpu: if . == null then 0 else (tostring | if endswith("m") then (.[:-1] | tonumber) / 1000 else tonumber end) end;
			[.[] | select(.kind == "Deployment" or .kind == "StatefulSet")
				| .spec.template.spec as $s
				| {name: .metadata.name,
					load: (($s.nodeSelector // {}) | length > 0),
					mem: ([$s.containers[] | .resources.limits.memory | mem] | add),
					cpu: ([$s.containers[] | .resources.requests.cpu | cpu] | add),
					images: [$s.containers[].image] | unique | join(" ")}] as $ws
			| (["workload", "node", "mem limit MiB", "cpu request", "images"] | @tsv),
			  ($ws | sort_by(-.mem)[] | [.name, (if .load then "load" else "app" end), (.mem | round), .cpu, .images] | @tsv),
			  (["total, app nodes", "", ([$ws[] | select(.load | not) | .mem] | add | round), ([$ws[] | select(.load | not) | .cpu] | add), ""] | @tsv),
			  (["total, load node", "", ([$ws[] | select(.load) | .mem] | add | round), ([$ws[] | select(.load) | .cpu] | add), ""] | @tsv)' \
			"$MAN/rendered.json" | if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi
	} >"$MAN/plan.txt"
	sed 's/^/  /' "$MAN/plan.txt"
	say "rendered $MAN/rendered.yaml ($(jq length "$MAN/rendered.json") objects)"
}

# --- prepull ------------------------------------------------------------------------------------------------------
is_dockerhub() { # an image reference on Docker Hub: no registry host in front, or docker.io
	local first=${1%%/*}
	[[ $1 != */* || ($first != *.* && $first != *:* && $first != localhost) || $first == docker.io ]]
}

cmd_prepull() {
	cmd_plan
	[ "$DRY" = 1 ] && { say "RBV_DRYRUN=1: stopping after the plan"; return 0; }
	[ -n "${RBV_SSH:-}" ] || die "prepull needs RBV_SSH, an ssh command that reaches the nodes as w1..wN and load (for example RBV_SSH=\"ssh -F my-ssh-config\")"
	local app load a pids=() img
	app=$(jq -r '[.[] | select(.kind == "Deployment" or .kind == "StatefulSet") | select(.metadata.name != "load-generator")
		| .spec.template.spec | (.containers + (.initContainers // []))[] | .image] | unique | .[]' "$MAN/rendered.json")
	load=$(jq -r '[.[] | select(.kind == "Deployment" and .metadata.name == "load-generator")
		| .spec.template.spec | (.containers + (.initContainers // []))[] | .image] | unique | .[]' "$MAN/rendered.json")
	stamp prepull-start
	for a in $(nodes_ssh); do
		(
			local list mirror=0 ok=0 bad=0 skip=0
			if [ "$a" = load ]; then list=$load; else list=$app; fi
			# shellcheck disable=SC2086  # RBV_SSH is "ssh -F <file>", meant to split
			$RBV_SSH -o ConnectTimeout=10 "$a" 'grep -qs "docker.io" /etc/rancher/k3s/registries.yaml' </dev/null && mirror=1
			for img in $list; do
				if is_dockerhub "$img" && [ "$mirror" = 0 ]; then
					skip=$((skip + 1))
					continue
				fi
				# shellcheck disable=SC2086
				if $RBV_SSH -o ConnectTimeout=10 "$a" "sudo k3s crictl pull '$img'" </dev/null >>"$OUT/prepull-$a.log" 2>&1; then
					ok=$((ok + 1))
				else
					bad=$((bad + 1))
				fi
			done
			say "prepull $a: $ok pulled, $bad failed$([ "$skip" = 0 ] || echo ", $skip Docker Hub images left for deploy (no docker.io mirror on the node)")"
		) &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" || true; done
	stamp prepull-end
}

# --- deploy -------------------------------------------------------------------------------------------------------
pod_problems() { # pods that are not ready, with why (image pull errors named)
	kn get pods -o json | jq -r '.items[] | select(.status.phase != "Succeeded")
		| select([.status.containerStatuses[]?.ready] | all | not)
		| [.metadata.name, .status.phase,
			([.status.containerStatuses[]?, .status.initContainerStatuses[]? | .state.waiting // empty | "\(.reason): \(.message // "" | .[0:160])"] | join("; "))] | @tsv'
}

# the required workloads that are not ready: a deployment whose pods do not all have the container of its name ready
# (or all containers, when none has its name), or a statefulset short of replicas
required_not_ready() {
	# the two JSON documents go in as files: as --argjson arguments the pod list passes the kernel's limit of one
	# argument (128 KiB) on a full-size cluster ("jq: Argument list too long")
	local deps pods
	deps=$(mktemp) pods=$(mktemp)
	kn get deploy -o json >"$deps"
	kn get pods -o json >"$pods"
	jq -nr --slurpfile d "$deps" --slurpfile p "$pods" --arg req "$REQUIRED" '
		($d[0]) as $d | ($p[0]) as $p
		| ($req | split(" ")) as $want
		| $d.items[] | select(.metadata.name as $n | $want | index($n)) | . as $dep
		| (.spec.selector.matchLabels) as $sel
		| [$p.items[] | select(.metadata.labels as $l | $sel | to_entries | all($l[.key] == .value)) | select(.metadata.deletionTimestamp == null)
			| ([.status.containerStatuses[]? | select(.name == $dep.metadata.name)] as $own
				| if ($own | length) > 0 then ($own | all(.ready)) else ([.status.containerStatuses[]?.ready] | (length > 0 and all)) end)] as $ok
		| select(($ok | length) < (.spec.replicas // 1) or ($ok | all | not)) | .metadata.name'
	rm -f "$deps" "$pods"
	for w in $REQUIRED; do
		kn get statefulset "$w" >/dev/null 2>&1 || continue
		kn get statefulset "$w" -o json | jq -r 'select((.status.readyReplicas // 0) < (.spec.replicas // 1)) | .metadata.name'
	done
}

cmd_deploy() {
	cmd_plan
	[ "$DRY" = 1 ] && { say "RBV_DRYRUN=1: stopping after the plan"; return 0; }
	need_cluster
	k get nodes -o wide >"$OUT/nodes.txt" 2>&1 || die "the cluster does not answer (KUBECONFIG=$KUBECONFIG)"
	if [ -n "$LOAD_SEL" ]; then
		local ln key=${LOAD_SEL%%=*} val=${LOAD_SEL#*=}
		ln=$(k get nodes -l "$LOAD_SEL" -o jsonpath='{.items[*].metadata.name}')
		[ -n "$ln" ] || die "no node matches RBV_LOAD_SELECTOR=$LOAD_SEL (label the load node rbv/role=load and taint it rbv/role=load:NoSchedule)"
		k get nodes -l "$LOAD_SEL" -o json | jq -e --arg k "$key" --arg v "$val" \
			'[.items[] | [.spec.taints[]? | select(.effect == "NoSchedule")] | all(.key == $k and (.value // "") == $v)] | all' >/dev/null ||
			say "warning: the load node has a NoSchedule taint other than $key=$val: the load generator may not schedule there"
	fi
	if [ -n "${RBV_SSH:-}" ]; then
		local a
		for a in $(nodes_ssh); do
			# shellcheck disable=SC2086  # RBV_SSH is "ssh -F <file>", meant to split
			if ! $RBV_SSH -o ConnectTimeout=10 "$a" 'grep -qs "docker.io" /etc/rancher/k3s/registries.yaml' </dev/null 2>/dev/null; then
				say "warning: $a has no docker.io mirror in /etc/rancher/k3s/registries.yaml: the demo pulls about 8 images from Docker Hub (anonymous pull limit, counted per public address); a 429 stops deploy below"
				break
			fi
		done
	fi
	stamp deploy-start
	say "applying the demo (server-side apply, field manager $FIELD_MANAGER)"
	k apply --server-side --force-conflicts --field-manager="$FIELD_MANAGER" -f "$MAN/rendered.yaml" >"$OUT/apply.log" 2>&1 ||
		{ tail -n 20 "$OUT/apply.log" >&2; die "kubectl apply failed (log: $OUT/apply.log)"; }
	local start now notready reqnot reqok_at=""
	start=$(date +%s)
	say "waiting for the demo to be ready (up to ${READY_TIMEOUT}s)"
	while :; do
		now=$(date +%s)
		notready=$(kn get deploy,statefulset -o json | jq -r '.items[] | select((.status.readyReplicas // 0) < (.spec.replicas // 1)) | .metadata.name' | sort)
		[ -z "$notready" ] && break
		reqnot=$(required_not_ready | sort -u)
		if [ -z "$reqnot" ]; then
			[ -n "$reqok_at" ] || reqok_at=$now
			[ $((now - reqok_at)) -ge "$OPTIONAL_WAIT" ] && break
		else
			reqok_at=""
		fi
		[ $((now - start)) -ge "$READY_TIMEOUT" ] && break
		if pod_problems | grep -qiE 'toomanyrequests|429 Too Many|rate limit'; then
			pod_problems | sed 's/^/  /'
			die "image pulls are rate limited (Docker Hub): give the nodes a docker.io mirror (k3s: /etc/rancher/k3s/registries.yaml) and run deploy again"
		fi
		say "  $(wc -w <<<"$notready") not ready after $((now - start))s: $(tr '\n' ' ' <<<"$notready")"
		sleep 20
	done
	kn get pods -o wide >"$OUT/pods.txt" 2>&1 || true
	reqnot=$(required_not_ready | sort -u)
	if [ -n "$reqnot" ]; then
		pod_problems | sed 's/^/  /'
		die "not ready after ${READY_TIMEOUT}s: $(tr '\n' ' ' <<<"$reqnot")(pods: $OUT/pods.txt)"
	fi
	[ -z "$notready" ] || say "warning: not ready, not needed for the capture: $(tr '\n' ' ' <<<"$notready")"
	stamp deploy-ready
	say "ready after $(($(date +%s) - start))s"
	if [ -n "$LOAD_SEL" ]; then
		local lgnode
		lgnode=$(kn get pods -l app.kubernetes.io/component=load-generator -o jsonpath='{.items[0].spec.nodeName}')
		k get node "$lgnode" -o json | jq -e --arg k "${LOAD_SEL%%=*}" --arg v "${LOAD_SEL#*=}" '.metadata.labels[$k] == $v' >/dev/null ||
			die "the load generator runs on $lgnode, not on a $LOAD_SEL node"
		say "load generator on $lgnode"
	fi
	local sz
	sleep 15
	sz=$(kn exec deploy/otel-collector -c rbv-capture -- stat -c %s /capture/spans.jsonl 2>/dev/null || echo 0)
	[ "${sz:-0}" -gt 0 ] || die "the Collector has not written /capture/spans.jsonl (kubectl -n $NS logs deploy/otel-collector -c opentelemetry-collector)"
	say "the Collector writes the trace file (${sz} bytes so far)"
}

# --- capture ------------------------------------------------------------------------------------------------------
restarts() { kn get pods -o json | jq -c '[.items[] | .metadata.name as $p | .status.containerStatuses[]? | {pod: $p, container: .name, n: .restartCount, reason: (.lastState.terminated.reason // null)}]'; }
cap_exec() { kn exec deploy/otel-collector -c rbv-capture -- "$@"; }

set_mix() {
	local mix=$1 cur
	cur=$(kn get deploy/load-generator -o json | jq -r '[.spec.template.spec.containers[] | select(.name == "load-generator") | .env[]? | select(.name == "LOCUST_LOCUSTFILE") | .value][0] // ""')
	case $mix in
	shipped) [ -z "$cur" ] || kn set env deploy/load-generator -c load-generator LOCUST_LOCUSTFILE- >/dev/null ;;
	browse) [ "$cur" = /rbv/locustfile_browse.py ] || kn set env deploy/load-generator -c load-generator LOCUST_LOCUSTFILE=/rbv/locustfile_browse.py >/dev/null ;;
	esac
	kn rollout status deploy/load-generator --timeout=300s >/dev/null || die "the load generator did not roll out with mix $mix"
	local _
	for _ in $(seq 1 30); do # a terminating old pod is gone once only one pod is left
		[ "$(kn get pods -l app.kubernetes.io/component=load-generator --no-headers 2>/dev/null | wc -l)" = 1 ] && break
		sleep 2
	done
}

wait_s() { # sleep N seconds in steps, showing the load generator and the file
	local total=$1 what=$2 left=$1 step sz lg
	while [ "$left" -gt 0 ]; do
		step=$((left < 60 ? left : 60))
		sleep "$step"
		left=$((left - step))
		sz=$(cap_exec stat -c %s /capture/spans.jsonl 2>/dev/null || echo 0)
		lg=$(kn get pods -l app.kubernetes.io/component=load-generator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")
		say "  $what: $((total - left))/${total}s, load generator $lg, trace file $((${sz:-0} / 1048576)) MiB"
	done
}

# the Collector's log lines that matter for the capture: its memory limiter, and the exporters' failures by exporter
collector_log_json() {
	local log=$1
	jq -n --argjson ml "$(grep -ciE 'memory usage is above|refused due to high memory' "$log" || true)" \
		--argjson drop "$(grep -ciE 'dropping data|dropped|queue is full' "$log" || true)" \
		--argjson fail "$(grep -iE 'exporting failed|failed to export|export failed' "$log" | grep -oE '"otelcol.component.id": "[^"]+"' |
			sed 's/.*: "//; s/"$//' | sort | uniq -c | awk '{printf "%s\"%s\":%s", (n++ ? "," : "{"), $2, $1} END {printf "%s", (n ? "}" : "{}")}')" \
		'{memory_limiter_lines: $ml, dropping_lines: $drop, export_failures_by_exporter: $fail}'
}

window() {
	local mix=$1 first=$2 W=$OUT/$1 warm t0 t1 rb ra
	mkdir -p "$W/raw"
	stamp "$mix-start"
	say "mix $mix: load generator restarted with the mix"
	set_mix "$mix"
	if [ "$first" = 1 ]; then warm=$WARMUP_S; else warm=$REWARM_S; fi
	wait_s "$warm" "mix $mix warm-up"
	rb=$(restarts)
	t0=$(cap_exec date +%s) || die "cannot read the clock of the Collector's node"
	stamp "$mix-window"
	say "mix $mix: window from $(date -u -d "@$t0" +%FT%TZ) for ${WINDOW_S}s"
	wait_s "$WINDOW_S" "mix $mix window"
	t1=$((t0 + WINDOW_S))
	ra=$(restarts)
	sleep "$GRACE_S"
	say "mix $mix: copying the trace file"
	cap_exec gzip -1 -c /capture/spans.jsonl >"$W/raw/spans.jsonl.gz" || die "copying /capture/spans.jsonl failed"
	stamp "$mix-copied"
	kn logs deploy/otel-collector -c opentelemetry-collector --since="$((warm + WINDOW_S + GRACE_S + 120))s" >"$W/collector.log" 2>&1 || true
	k top nodes >"$W/top-nodes.txt" 2>&1 || true
	kn top pods --containers >"$W/top-pods.txt" 2>&1 || true
	kn get pods -o wide >"$W/pods.txt" 2>&1 || true
	local lgnode collnode
	lgnode=$(kn get pods -l app.kubernetes.io/component=load-generator -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
	collnode=$(kn get pods -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
	jq -n --arg mix "$mix" --argjson t0 "$t0" --argjson t1 "$t1" --argjson warm "$warm" --argjson users "$USERS" \
		--argjson spawn "$SPAWN" --arg browser "$BROWSER" --argjson rb "$rb" --argjson ra "$ra" --arg lg "$lgnode" --arg cn "$collnode" \
		--argjson raw "$(stat -c %s "$W/raw/spans.jsonl.gz")" --argjson log "$(collector_log_json "$W/collector.log")" \
		--arg off "$OFF_PATH" '
		{mix: $mix, users: $users, spawn_rate: $spawn, browser_users: ($browser == "1"), warmup_s: $warm,
			t0_unix: $t0, t1_unix: $t1, window_s: ($t1 - $t0), load_generator_node: $lg, collector_node: $cn,
			raw_gz_bytes: $raw,
			restarted_in_window: [$ra[] as $a | ($rb[] | select(.pod == $a.pod and .container == $a.container) | .n) as $b
				| select($a.n > $b) | {pod: $a.pod, container: $a.container, restarts: ($a.n - $b), reason: $a.reason,
					on_a_request_path: ($off | split(" ") | index($a.container) | not)}],
			# a pod replaced during the window (a rollout, an evicted pod) is a bigger break than a restart
			pods_new_in_window: ([$ra[].pod] - [$rb[].pod] | unique),
			pods_gone_in_window: ([$rb[].pod] - [$ra[].pod] | unique),
			collector_log: $log}' >"$W/window.json"
	say "mix $mix: copied $(($(stat -c %s "$W/raw/spans.jsonl.gz") / 1048576)) MiB (gzip); window $t0..$t1"
}

cmd_capture() {
	[ "$DRY" = 1 ] && { cmd_plan; say "RBV_DRYRUN=1: stopping after the plan"; return 0; }
	need_cluster
	kn get deploy/otel-collector >/dev/null 2>&1 || die "the demo is not deployed (run.sh deploy)"
	local first=1 m
	for m in $MIXES; do
		window "$m" "$first"
		first=0
	done
	kn get pods -o wide >"$OUT/pods.txt" 2>&1 || true
	k get nodes -o wide >"$OUT/nodes.txt" 2>&1 || true
}

# --- analyze ------------------------------------------------------------------------------------------------------
build_tools() {
	command -v go >/dev/null || die "needs go (to build the CLI and otelcap from this tree)"
	mkdir -p "$ROOT/bin"
	(cd "$ROOT" && go build -o bin/rhobound ./cmd/rhobound && go build -o bin/otelcap ./validation/cluster/otel/otelcap) ||
		die "go build failed"
}

variant_args() { # otelcap cut's options for a variant
	case $1 in
	captured) ;;
	nested) echo "-nested-internal" ;;
	nested-drop)
		local d out="-nested-internal"
		for d in $DROP; do out="$out -drop-service $d"; done
		echo "$out"
		;;
	esac
}

variant_text() {
	case $1 in
	captured) echo "as captured" ;;
	nested) echo "diagnostic: nested spans of one pod made one (otelcap cut -nested-internal)" ;;
	nested-drop) echo "diagnostic: nested spans made one, and the spans of $DROP left out (their calls become outside delays)" ;;
	esac
}

analyze_variant() { # cut the window again with the variant's changes, describe it, and run the CLI on it
	local W=$1 v=$2 RB=$ROOT/bin/rhobound OC=$ROOT/bin/otelcap t0 t1 rc V=$1/v-$2
	local -a opts
	read -r -a opts <<<"$(variant_args "$v")"
	t0=$(jq -r .t0_unix "$W/window.json")
	t1=$(jq -r .t1_unix "$W/window.json")
	rm -rf "$V"
	mkdir -p "$V"
	"$OC" cut -from "$t0" -to "$t1" -o "$V/capture" "${opts[@]}" "$W/raw/spans.jsonl.gz" >"$V/cut.json" || die "otelcap cut failed on $W ($v)"
	"$OC" stats "$V/capture" >"$V/stats.json" 2>"$V/stats.err" || say "warning: otelcap stats failed on $V ($(head -c 300 "$V/stats.err"))"
	set +e
	"$RB" infer "$V/capture" "${PREDICT_ARGS[@]}" >"$V/infer.json" 2>"$V/infer.err"
	echo $? >"$V/infer.rc"
	"$RB" predict "$V/capture" --json "${PREDICT_ARGS[@]}" >"$V/predict.json" 2>"$V/predict.err"
	rc=$?
	echo $rc >"$V/predict.rc"
	"$RB" predict "$V/capture" "${PREDICT_ARGS[@]}" >"$V/predict.txt" 2>&1
	if [ "$rc" != 0 ] && grep -q 'refusing to predict: at the observed load' "$V/predict.err"; then
		# diagnostic only: the busiest service read against the CLI's highest limit (it still refuses above it)
		"$RB" predict "$V/capture" --json --max-rho 0.95 "${PREDICT_ARGS[@]}" >"$V/predict-rho95.json" 2>"$V/predict-rho95.err"
	fi
	set -e
	[ -s "$V/predict.json" ] || rm -f "$V/predict.json"
	[ -s "$V/infer.json" ] || rm -f "$V/infer.json"
	say "$(basename "$W") ($v): infer exit $(cat "$V/infer.rc"), predict exit $rc"
	return "$rc"
}

analyze_mix() {
	local W=$1 v
	if analyze_variant "$W" captured && [ "${RBV_OTEL_VARIANTS_ALWAYS:-0}" != 1 ]; then
		return 0
	fi
	for v in $VARIANTS; do analyze_variant "$W" "$v" || true; done
}

summarize() {
	local W m v entries=() vs
	for m in $MIXES; do
		W=$OUT/$m
		[ -f "$W/window.json" ] || continue
		vs=()
		for v in captured $VARIANTS; do
			local V=$W/v-$v
			[ -f "$V/cut.json" ] || continue
			vs+=("$(jq -n --arg name "$v" --arg text "$(variant_text "$v")" \
				--slurpfile cut "$V/cut.json" \
				--slurpfile st <(cat "$V/stats.json" 2>/dev/null || echo null) \
				--slurpfile inf <(cat "$V/infer.json" 2>/dev/null || echo null) \
				--slurpfile pr <(cat "$V/predict.json" 2>/dev/null || echo null) \
				--slurpfile pr95 <(cat "$V/predict-rho95.json" 2>/dev/null || echo null) \
				--rawfile inferr "$V/infer.err" --rawfile prerr "$V/predict.err" \
				--arg pr95err "$(cat "$V/predict-rho95.err" 2>/dev/null)" \
				--arg inrc "$(cat "$V/infer.rc" 2>/dev/null)" --arg prrc "$(cat "$V/predict.rc" 2>/dev/null)" '
				def lines: split("\n") | map(select(length > 0));
				{name: $name, text: $text, cut: $cut[0], stats: $st[0],
					infer: {exit: ($inrc | tonumber? // null), stderr: ($inferr | lines), topology: $inf[0]},
					predict: {exit: ($prrc | tonumber? // null), stderr: ($prerr | lines), report: $pr[0]},
					predict_max_rho_095: (if $pr95[0] == null and $pr95err == "" then null
						else {stderr: ($pr95err | lines), report: $pr95[0]} end)}')")
		done
		entries+=("$(printf '%s\n' "${vs[@]}" | jq -s --slurpfile win "$W/window.json" '{mix: $win[0].mix, window: $win[0], variants: .}')")
	done
	printf '%s\n' "${entries[@]}" | jq -s --rawfile timing <(cat "$OUT/timing.tsv" 2>/dev/null || true) '
		{windows: ., timing: ($timing | split("\n") | map(select(length > 0) | split("\t") | {step: .[0], unix: (.[1] | tonumber), utc: .[2]}))}' \
		>"$OUT/summary.json"

	jq -r --arg ver "$OTEL_VERSION" '
		def f(n; d): if n == null then "-" else (n * pow(10; d) | round / pow(10; d) | tostring) end;
		def pct(n): if n == null then "-" else f(n * 100; 1) + "%" end;
		def cell: tostring | gsub("\\|"; "/") | gsub("\n"; " ");
		def kindname: {"0": "unspecified", "1": "internal", "2": "server", "3": "client", "4": "producer", "5": "consumer"}[tostring] // tostring;
		def refusal(r): (r.stderr | map(select(startswith("rhobound:"))) | .[0]) // (r.stderr | .[0]) // "-";
		.timing as $tm
		| def at(s): ([$tm[] | select(.step == s) | .unix] | .[-1]); # the latest run of a step
		def span(a; b): if at(a) == null or at(b) == null then "-" else "\(at(b) - at(a)) s" end;
		"# Phase B: the OpenTelemetry Demo \($ver) with rhobound",
		"",
		"Each window: the trace file of the demo'"'"'s Collector, cut to the traces that start inside the window (otelcap",
		"cut), then `rhobound infer` and `rhobound predict` on it. Every refusal and warning is quoted as the CLI printed",
		"it. When the CLI refuses the capture as captured, diagnostic variants of the same window follow, each named",
		"with what it changed; they are not the capture'"'"'s result. The capture tables come from otelcap stats (the CLI'"'"'s",
		"own reader; descriptive, the CLI'"'"'s rules decide).",
		"",
		"Time: prepull \(span("prepull-start"; "prepull-end")), deploy \(span("deploy-start"; "deploy-ready"))\([.windows[] | .mix as $m | ", mix \($m) \(span("\($m)-start"; "\($m)-copied"))"] | join("")).",
		"",
		(.windows[] | . as $e | $e.window as $w | ($e.variants[] | select(.name == "captured")) as $c |
		"## Mix `\($w.mix)`: \($w.users) Locust users, \($w.window_s) s from \($w.t0_unix | todate)",
		"",
		"- capture: \($c.cut.traces_kept) whole traces, \($c.cut.spans_kept) spans (\($c.cut.traces_before) traces started before the window, \($c.cut.traces_after) after it; \($c.cut.bad_lines) undecodable and \($c.cut.partial_lines) partial lines dropped)",
		"- load generator on \($w.load_generator_node), Collector on \($w.collector_node)",
		"- containers restarted in the window: \(if ($w.restarted_in_window | length) == 0 then "none" else ($w.restarted_in_window | map("\(.pod)/\(.container) (\(.restarts), \(.reason // "?")\(if .on_a_request_path then "" else ", on no request path" end))") | join(", ")) end)\(if (($w.pods_new_in_window // []) | length) > 0 or (($w.pods_gone_in_window // []) | length) > 0 then "; pods replaced in the window: new \($w.pods_new_in_window | join(", ")), gone \($w.pods_gone_in_window | join(", "))" else "" end)",
		"- Collector log in the run: \($w.collector_log.memory_limiter_lines) memory-limiter lines, \($w.collector_log.dropping_lines) dropping lines, export failures by exporter: \($w.collector_log.export_failures_by_exporter | if length == 0 then "none" else to_entries | map("\(.key) \(.value)") | join(", ") end) (the capture is file/rhobound)",
		(if $c.stats == null then "- otelcap stats: none" else
		"- entries (SERVER visits with no caller in the capture): " + ([$c.stats.entries[] | "\(.service) \(f(.rate_per_s; 2))/s (\($c.stats.bucket_s)-s counts: CV \(f(.bucket_cv; 3)); a Poisson stream: \(f(.poisson_cv; 3)))"] | join("; ")) end),
		"",
		($e.variants[] | . as $v | $v.predict.report as $p |
		"### \(if $v.name == "captured" then "What the CLI said" else "Variant `\($v.name)`" end): \($v.text)",
		"",
		(if $v.name == "captured" then empty else
			"- changed: " + ([($v.cut.nested_spans_made_internal // {} | to_entries[] | "\(.value) nested spans of \(.key) made internal"),
				($v.cut.dropped_service_spans // {} | to_entries[] | "\(.value) spans of \(.key) left out")] | if length == 0 then "nothing" else join(", ") end)
				+ (if ($v.cut.spans_whose_parent_was_dropped // 0) > 0 then "; \($v.cut.spans_whose_parent_was_dropped) kept spans lost their parent to it" else "" end) end),
		"- `rhobound infer`: \(if $v.infer.exit == 0 then "inferred \($v.infer.topology.services | length) services, entries \($v.infer.topology.entry | to_entries | map("\(.key) \(f(.value; 3))") | join(", "))" else "exit \($v.infer.exit): " + (refusal($v.infer) | cell) end)",
		"- `rhobound predict`: \(if $v.predict.exit == 0 then "\(f($p.window_s; 0)) s, \($p.requests) entry requests (\(f($p.external_rps; 1))/s) in \($p.traces) traces, \($p.broken_traces) broken; busiest \($p.busiest_service) at \(pct($p.max_utilization))" else "exit \($v.predict.exit): " + (refusal($v.predict) | cell) end)",
		(if $v.predict_max_rho_095 != null then "- diagnostic, `--max-rho 0.95`: " + (if $v.predict_max_rho_095.report != null then "busiest \($v.predict_max_rho_095.report.busiest_service) at \(pct($v.predict_max_rho_095.report.max_utilization))" else (refusal($v.predict_max_rho_095) | cell) end) else empty end),
		"",
		(($p // $v.predict_max_rho_095.report) as $r | if $r == null then empty else
		(if $p == null then "Services (from the `--max-rho 0.95` diagnostic, not the default run):" else "Services:" end),
		"",
		"| service | entry | rps | pods x w | own ms | cs2 | util | wait ms | seen wait | model ms | seen ms | err % |",
		"|---|---|---|---|---|---|---|---|---|---|---|---|",
		($r.services[] | "| \(.name)\(if .external then " (outside peer)" else "" end) | \(if .entry then "yes" else "" end) | \(f(.rate_rps; 2)) | \(.replicas) x \(.workers_per_pod)\(if .workers_are_a_lower_bound then "+" else "" end) | \(f(.own_ms; 2)) | \(f(.own_cs2; 2)) | \(pct(.utilization)) | \(f(.model_wait_ms; 2)) | \(f(.observed_wait_ms; 2)) | \(f(.model_ms; 2)) | \(f(.observed_ms; 2)) | \(f(.error_pct; 1)) |"),
		"",
		"Warnings:",
		"",
		(($r.warnings // []) | if length == 0 then "- none" else .[] | "- \(cell)" end),
		"" end),
		(if $v.predict.exit != 0 and ($v.predict.stderr | length) > 0 then "Refusal, in full:", "", "```", ($v.predict.stderr[]), "```", "" else empty end)),
		(if $c.stats == null then empty else
		"### What the CLI needs, and what the demo gave (as captured)",
		"",
		"| service | spans | server | client | internal | producer | consumer | pods | spans with k8s.pod.name | SERVER /s | SERVER mean ms |",
		"|---|---|---|---|---|---|---|---|---|---|---|",
		([$c.cut.resources[]? | {key: .service, value: .}] | from_entries) as $rc |
		($c.stats.services[] | . as $s | ($rc[$s.name]) as $r |
			"| \(.name) | \(.spans) | \(.kinds.server // 0) | \(.kinds.client // 0) | \(.kinds.internal // 0) | \(.kinds.producer // 0) | \(.kinds.consumer // 0) | \(.pods) | \(if $r == null or $r.spans == 0 then "-" else pct($r.with_k8s_pod_name / $r.spans) end) | \(f(.server_rps; 2)) | \(f(.server_mean_ms; 2)) |"),
		"",
		"- where traces start: " + ([$c.stats.roots[] | "\(.service) \(.kind) \(.spans)"] | join(", ")),
		"- spans whose parent is not in the capture: " + (if ($c.stats.spans_with_parent_not_in_capture | length) == 0 then "none" else [$c.stats.spans_with_parent_not_in_capture[] | "\(.service) \(.kind) \(.spans)"] | join(", ") end),
		"- health probe spans the reader dropped: \($c.stats.probe_spans_dropped); spans skipped (no id, service or time): \($c.stats.skipped_spans)",
		"- a service calling itself (often a framework'"'"'s SERVER span inside the HTTP one): " + ([$c.stats.edges[] | select(.caller == .callee) | "\(.caller) on \(f(.share_of_visits_calling * 100; 1))% of its visits"] | if length == 0 then "none" else join(", ") end),
		"- calls per visit that are neither one count nor one count plus one on some visits (99% of visits):",
		([$c.stats.edges[] | select(.shape == "varies")] | if length == 0 then "  none" else .[] | "  - \(.caller) -> \(.callee): \(.calls_per_visit | to_entries | sort_by(.key | tonumber? // 1e9) | map("\(.key) calls on \(.value)") | join(", ")) of \(.caller_visits) visits" end),
		"- spans with an error status (the 12 most; timeouts show here as long means):",
		($c.cut.spans_with_errors | if length == 0 then "  none" else .[0:12][] | "  - \(.service) \(.kind | kindname) `\(.name | cell)`: \(.error_spans) of \(.spans) with an error, mean \(f(.mean_ms; 2)) ms" end),
		"" end)
		)' "$OUT/summary.json" >"$OUT/summary.md"
}

cmd_analyze() {
	[ "$DRY" = 1 ] && { cmd_plan; say "RBV_DRYRUN=1: stopping after the plan"; return 0; }
	build_tools
	stamp analyze-start
	local m any=0
	for m in $MIXES; do
		if [ ! -f "$OUT/$m/window.json" ] || [ ! -f "$OUT/$m/raw/spans.jsonl.gz" ]; then
			say "mix $m: no window copied; skipping"
			continue
		fi
		analyze_mix "$OUT/$m"
		any=1
	done
	[ "$any" = 1 ] || die "no window to analyze under $OUT (run.sh capture)"
	stamp analyze-end
	summarize
	cat "$OUT/summary.md"
	say "summary: $OUT/summary.md and summary.json"
}

# --- down ---------------------------------------------------------------------------------------------------------
cmd_down() {
	[ "$DRY" = 1 ] && { say "RBV_DRYRUN=1: nothing deleted"; return 0; }
	need_cluster
	[ -f "$MAN/rendered.yaml" ] || cmd_plan
	say "deleting the demo (namespace $NS and its cluster-wide objects)"
	k delete -f "$MAN/rendered.yaml" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	k delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null || say "warning: namespace $NS is still terminating"
	stamp down
}

cmd_all() {
	cmd_deploy
	[ "$DRY" = 1 ] && return 0
	cmd_capture
	cmd_analyze
	if [ "${RBV_KEEP_NS:-0}" != 1 ]; then cmd_down; else say "RBV_KEEP_NS=1: the demo keeps running"; fi
}

case ${1:-all} in
plan) cmd_plan ;;
prepull) cmd_prepull ;;
deploy) cmd_deploy ;;
capture) cmd_capture ;;
analyze) cmd_analyze ;;
down) cmd_down ;;
all) cmd_all ;;
*) die "unknown subcommand '$1' (plan, prepull, deploy, capture, analyze, down, all)" ;;
esac
