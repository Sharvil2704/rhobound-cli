"""Kubernetes manifests for maze (spec.json) and its trace pipeline.

    python maze/render.py app [--image auth=maze/auth:1.1 ...]   > app.yaml
    python maze/render.py obs [--sample PCT]                      > obs.yaml
    python maze/render.py load --seconds 660 --seed 7 [--rps R] [--name JOB]   > load.yaml

app: one Deployment + ClusterIP Service per service, image maze/<name>:<base version>, the
     behaviour in MAZE_CONFIG, standard OpenTelemetry environment (service name, pod name
     through the Downward API, OTLP endpoint).
obs: the OpenTelemetry Collector (contrib) in namespace maze-obs: OTLP/HTTP in, the
     k8sattributes processor (deployment, image), the file exporter out to the node's
     /var/lib/maze-traces (one ExportTraceServiceRequest per line). --sample PCT (round 30): the
     Collector's probabilistic_sampler at PCT% in its default mode (hash_seed, seed 0) on that
     pipeline -- what the consumer submits -- and a second, unsampled pipeline to
     /var/lib/maze-traces/full/ (ground truth for the test; e2e.capture moves it out of the capture).
load: the maze-load Job (open-loop Poisson at spec.load.rps).
"""
import argparse
import json
import os
import pathlib

SPEC = json.loads((pathlib.Path(__file__).parent / "spec.json").read_text())
NS = SPEC["namespace"]
OBS = "maze-obs"
OTLP = f"http://otel-collector.{OBS}.svc.cluster.local:4318"
# demo/ (round 211): images from a registry ("localhost:5001/" on the demo cluster), pulled like a real cluster pulls
# them; unset (the default), images are kind-loaded and never pulled
REGISTRY = os.environ.get("MAZE_REGISTRY", "")
PULL = "IfNotPresent" if REGISTRY else "Never"
# demo/ (round 211): MAZE_ENVFROM=1 writes the pod specs a real team would: each service's configuration from a
# ConfigMap (envFrom), payments' API token from a Secret and its risk rules as a mounted ConfigMap. The services read
# MAZE_CONFIG either way, and ignore the token and the rules
ENVFROM = os.environ.get("MAZE_ENVFROM") == "1"


def _svc_config(name, sv):
    return {"workers": sv["workers"], "work": sv["work"], "code_paths": sv.get("code_paths", []),
            "mode": sv.get("mode", "sequential"),
            "calls": [{"url": f"http://{c['to']}:8080{c['path']}", "p": c.get("p", 1.0),
                       "fresh_conn": c.get("fresh_conn", False)} for c in sv.get("calls", [])]}


def app(images: dict[str, str]) -> list[dict]:
    docs = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}}]
    for name, sv in SPEC["services"].items():
        labels = {"app": name, "app.kubernetes.io/part-of": "maze"}
        image = images.get(name, f"{REGISTRY}maze/{name}:{SPEC['versions']['base']}")
        env = [{"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}},
               {"name": "OTEL_SERVICE_NAME", "value": name},
               {"name": "OTEL_RESOURCE_ATTRIBUTES", "value": f"k8s.pod.name=$(POD_NAME),k8s.namespace.name={NS}"},
               {"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": OTLP},
               {"name": "MAZE_CONFIG", "value": json.dumps(_svc_config(name, sv), separators=(",", ":"))}]
        extra, pod_extra = {}, {}
        if ENVFROM:
            docs.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": f"{name}-config", "namespace": NS},
                         "data": {"MAZE_CONFIG": env.pop()["value"]}})
            extra["envFrom"] = [{"configMapRef": {"name": f"{name}-config"}}]
            if name == "payments":
                env.append({"name": "MAZE_API_TOKEN", "valueFrom": {"secretKeyRef": {"name": "payments-token",
                                                                                       "key": "token"}}})
                extra["volumeMounts"] = [{"name": "rules", "mountPath": "/etc/maze/rules", "readOnly": True}]
                pod_extra["volumes"] = [{"name": "rules", "configMap": {"name": "risk-rules"}}]
                docs += [{"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "payments-token", "namespace": NS},
                          "stringData": {"token": "demo-not-a-secret"}},
                         {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "risk-rules", "namespace": NS},
                          "data": {"rules.json": '{"blocked": ["blocked"]}'}}]
        docs.append({"apiVersion": "apps/v1", "kind": "Deployment",
                     "metadata": {"name": name, "namespace": NS, "labels": labels},
                     "spec": {"replicas": sv.get("replicas", 1), "selector": {"matchLabels": {"app": name}},
                              "template": {"metadata": {"labels": labels}, "spec": {
                                  "terminationGracePeriodSeconds": 30, **pod_extra,
                                  "containers": [{"name": name, "image": image, "imagePullPolicy": PULL,
                                                  "ports": [{"containerPort": 8080, "name": "http"}], "env": env,
                                                  **extra,
                                                  "resources": {"requests": {"cpu": "50m", "memory": "32Mi"}},
                                                  "readinessProbe": {"httpGet": {"path": "/healthz", "port": 8080},
                                                                     "periodSeconds": 2}}]}}}})
        docs.append({"apiVersion": "v1", "kind": "Service", "metadata": {"name": name, "namespace": NS, "labels": labels},
                     "spec": {"selector": {"app": name}, "ports": [{"name": "http", "port": 8080, "targetPort": 8080}]}})
    return docs


COLLECTOR = """receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317
processors:
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata: [k8s.pod.name, k8s.namespace.name, k8s.deployment.name, k8s.node.name, container.image.name, container.image.tag]
    pod_association:
      - sources:
          - from: connection
  batch:
    send_batch_size: 8192
    timeout: 1s
exporters:
  file:
    path: /data/spans.jsonl
service:
  telemetry:
    logs:
      level: warn
  pipelines:
    traces:
      receivers: [otlp]
      processors: [k8sattributes, batch]
      exporters: [file]
"""


def collector_config(sample: float | None = None, zipkin: bool = False) -> str:
    """The Collector's config; sample: a percentage for the probabilistic sampler + an unsampled truth pipeline;
    zipkin (round 111, Sock Shop): a Zipkin receiver (v1 / v2 JSON on :9411) beside OTLP."""
    if zipkin:
        conf = COLLECTOR.replace("receivers:\n  otlp:", "receivers:\n  zipkin:\n    endpoint: 0.0.0.0:9411\n  otlp:")
        conf = conf.replace("      receivers: [otlp]", "      receivers: [otlp, zipkin]")
        assert "zipkin:" in conf and "[otlp, zipkin]" in conf
        return conf
    if not sample:
        return COLLECTOR
    conf = COLLECTOR.replace("  batch:\n    send_batch_size: 8192",
                             f"  probabilistic_sampler:\n    sampling_percentage: {sample:g}\n"
                             "  batch:\n    send_batch_size: 8192")
    conf = conf.replace("  file:\n    path: /data/spans.jsonl",
                        "  file:\n    path: /data/spans.jsonl\n  file/full:\n    path: /data/full/spans.jsonl")
    conf = conf.replace("      processors: [k8sattributes, batch]\n      exporters: [file]",
                        "      processors: [k8sattributes, probabilistic_sampler, batch]\n      exporters: [file]\n"
                        "    traces/full:\n      receivers: [otlp]\n      processors: [k8sattributes, batch]\n"
                        "      exporters: [file/full]")
    assert "probabilistic_sampler" in conf and "file/full" in conf and "traces/full" in conf
    return conf


def obs(sample: float | None = None, zipkin: bool = False) -> list[dict]:
    rules = [{"apiGroups": [""], "resources": ["pods", "namespaces", "nodes"], "verbs": ["get", "watch", "list"]},
             {"apiGroups": ["apps"], "resources": ["replicasets", "deployments"], "verbs": ["get", "watch", "list"]}]
    return [
        {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": OBS}},
        {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "otel-collector", "namespace": OBS}},
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "maze-otel-collector"},
         "rules": rules},
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
         "metadata": {"name": "maze-otel-collector"},
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "maze-otel-collector"},
         "subjects": [{"kind": "ServiceAccount", "name": "otel-collector", "namespace": OBS}]},
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "otel-collector", "namespace": OBS},
         "data": {"config.yaml": collector_config(sample, zipkin)}},
        {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "otel-collector", "namespace": OBS},
         "spec": {"replicas": 1, "strategy": {"type": "Recreate"}, "selector": {"matchLabels": {"app": "otel-collector"}},
                  "template": {"metadata": {"labels": {"app": "otel-collector"}}, "spec": {
                      "serviceAccountName": "otel-collector",
                      "securityContext": {"runAsUser": 0},
                      "containers": [{"name": "otelcol", "image": "otel/opentelemetry-collector-contrib:latest",
                                      "imagePullPolicy": "IfNotPresent",
                                      "args": ["--config=/conf/config.yaml"],
                                      "ports": [{"containerPort": 4318, "name": "otlp-http"},
                                                {"containerPort": 4317, "name": "otlp-grpc"}]
                                      + ([{"containerPort": 9411, "name": "zipkin"}] if zipkin else []),
                                      "resources": {"requests": {"cpu": "200m", "memory": "256Mi"}},
                                      "volumeMounts": [{"name": "conf", "mountPath": "/conf"},
                                                       {"name": "data", "mountPath": "/data"}]}],
                      "volumes": [{"name": "conf", "configMap": {"name": "otel-collector"}},
                                  {"name": "data", "hostPath": {"path": "/var/lib/maze-traces",
                                                                "type": "DirectoryOrCreate"}}]}}}},
        {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "otel-collector", "namespace": OBS},
         "spec": {"selector": {"app": "otel-collector"}, "ports": [{"name": "otlp-http", "port": 4318},
                                                                    {"name": "otlp-grpc", "port": 4317}]
                  + ([{"name": "zipkin", "port": 9411}] if zipkin else [])}},
    ]


def load(seconds: float, seed: int, rps: float | None, name: str = "maze-load", ns: str = NS,
         mix: list | None = None, pattern: str | None = None) -> list[dict]:
    env = [{"name": "LOAD_RPS", "value": str(rps or SPEC["load"]["rps"])},
           {"name": "LOAD_SECONDS", "value": str(seconds)}, {"name": "LOAD_SEED", "value": str(seed)},
           {"name": "LOAD_MIX", "value": json.dumps(mix or SPEC["load"]["mix"], separators=(",", ":"))}]
    if pattern:                            # round 211: mmpp:BURST:HIGH_S:LOW_S, ramp:FROM:TO, step:AT_S:FACTOR
        env.append({"name": "LOAD_PATTERN", "value": pattern})
    return [{"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": ns},
             "spec": {"backoffLimit": 0, "template": {"spec": {
                 "restartPolicy": "Never",
                 "containers": [{"name": "load", "image": f"{REGISTRY}maze/load:1.0", "imagePullPolicy": PULL, "env": env,
                                 "resources": {"requests": {"cpu": "100m"}}}]}}}}]


def dump(docs) -> str:
    return "\n---\n".join(json.dumps(d, indent=1) for d in docs) + "\n"


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("what", choices=("app", "obs", "load"))
    p.add_argument("--image", action="append", default=[], help="service=image override")
    p.add_argument("--seconds", type=float, default=660)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--rps", type=float)
    p.add_argument("--name", default="maze-load")
    p.add_argument("--namespace", default=NS)
    p.add_argument("--mix", help="JSON file: [{url, w}] (default: spec.json's)")
    p.add_argument("--pattern", help="load: mmpp:BURST:HIGH_S:LOW_S, ramp:FROM:TO or step:AT_S:FACTOR (default Poisson)")
    p.add_argument("--sample", type=float, help="obs: the Collector samples PCT%% (and keeps an unsampled truth copy)")
    p.add_argument("--zipkin", action="store_true", help="obs: a Zipkin receiver on :9411 too (round 111, Sock Shop)")
    a = p.parse_args()
    if a.what == "app":
        print(dump(app(dict(x.split("=", 1) for x in a.image))), end="")
    elif a.what == "obs":
        print(dump(obs(a.sample, a.zipkin)), end="")
    else:
        mix = json.loads(pathlib.Path(a.mix).read_text()) if a.mix else None
        print(dump(load(a.seconds, a.seed, a.rps, a.name, a.namespace, mix, a.pattern)), end="")
