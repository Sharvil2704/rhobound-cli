"""Kubernetes manifests for maze (spec.json) on the bed cluster (adapted from the kshop kit's render.py).

    python3 -I render.py app --image auth=REF@sha256:... (every service)            > app.yaml
    python3 -I render.py load --load-image REF@sha256:... --seconds 600 --seed 7 [--rps R] [--name JOB]   > load.yaml
        [--mix-weights browse=W,feed=W,q=W,buy=W,bulk=W]   (SPEC3 F6a) the mix by name: every URL of spec.json's load.mix, named by
        its last path segment, exactly once, W a plain decimal >= 0 that a float holds (not past 1.8e308, not a non-zero
        that rounds to 0), summing > 0 and to a float (relative: maze-load normalises); a 0 leaves the URL out of the Job.
        Without --rps/--mix/--mix-weights the Job is exactly spec.json's load (LOAD_RPS "120").

app: one Deployment + ClusterIP Service per service, image by digest from ECR (imagePullSecrets ecr), on the app pool
     (nodeSelector rhobound.io/pool=app), the behaviour in MAZE_CONFIG (service, workers, routes), standard
     OpenTelemetry environment (service name, pod name through the Downward API, k8s.container.name = the service, so the
     Collector's k8sattributes can add the container's image digest; OTLP/HTTP to our Collector in maze-obs).
load: the maze-load Job (open-loop Poisson at spec.load.rps) on the load pool (nodeSelector + toleration), image by digest.
The Collector's manifests are tools1/k8s/ (render.py obs of the original is not used here).
"""
import argparse
import json
import math
import pathlib
import re
import sys

SPEC = json.loads((pathlib.Path(__file__).parent / "spec.json").read_text())
NS = SPEC["namespace"]
OBS = "maze-obs"
OTLP = f"http://otel-collector.{OBS}.svc.cluster.local:4318"
POOL = "rhobound.io/pool"
PULL_SECRET = "ecr"
DIGEST_REF = re.compile(r"^[a-z0-9][a-z0-9.:/_-]*@sha256:[0-9a-f]{64}$")


def _svc_config(name, sv):
    """MAZE_CONFIG (internal/rt Config): the service's name, workers and routes as spec.json gives them; peers default to
    http://NAME:8080 (the Service of each name in this namespace)."""
    return {"service": name, "workers": sv["workers"], "routes": sv["routes"]}


def _ref(what: str, ref: str) -> str:
    if not DIGEST_REF.match(ref):
        sys.exit(f"render.py: {what}: {ref!r} is not REF@sha256:<64 hex> (images go by digest)")
    return ref


def app(images: dict[str, str]) -> list[dict]:
    missing = sorted(set(SPEC["services"]) - set(images))
    extra = sorted(set(images) - set(SPEC["services"]))
    if missing or extra:
        sys.exit(f"render.py app: --image for every service and no other (missing {missing}, unknown {extra})")
    docs = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}}]
    for name, sv in SPEC["services"].items():
        labels = {"app": name, "app.kubernetes.io/part-of": "maze"}
        env = [{"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}},
               {"name": "OTEL_SERVICE_NAME", "value": name},
               {"name": "OTEL_RESOURCE_ATTRIBUTES",
                "value": f"k8s.pod.name=$(POD_NAME),k8s.namespace.name={NS},k8s.container.name={name}"},
               {"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": OTLP},
               {"name": "MAZE_CONFIG", "value": json.dumps(_svc_config(name, sv), separators=(",", ":"))}]
        docs.append({"apiVersion": "apps/v1", "kind": "Deployment",
                     "metadata": {"name": name, "namespace": NS, "labels": labels},
                     "spec": {"replicas": sv.get("replicas", 1), "selector": {"matchLabels": {"app": name}},
                              "template": {"metadata": {"labels": labels}, "spec": {
                                  "terminationGracePeriodSeconds": 30,
                                  "nodeSelector": {POOL: "app"},
                                  "imagePullSecrets": [{"name": PULL_SECRET}],
                                  "containers": [{"name": name, "image": _ref(name, images[name]),
                                                  "imagePullPolicy": "IfNotPresent",
                                                  "ports": [{"containerPort": 8080, "name": "http"}], "env": env,
                                                  "resources": {"requests": {"cpu": "50m", "memory": "32Mi"}},
                                                  "readinessProbe": {"httpGet": {"path": "/healthz", "port": 8080},
                                                                     "periodSeconds": 2}}]}}}})
        docs.append({"apiVersion": "v1", "kind": "Service", "metadata": {"name": name, "namespace": NS, "labels": labels},
                     "spec": {"selector": {"app": name}, "ports": [{"name": "http", "port": 8080, "targetPort": 8080}]}})
    return docs


def load(image: str, seconds: float, seed: int, rps: float | None, name: str = "maze-load", ns: str = NS,
         mix: list | None = None, pattern: str | None = None) -> list[dict]:
    env = [{"name": "LOAD_RPS", "value": str(rps or SPEC["load"]["rps"])},
           {"name": "LOAD_SECONDS", "value": str(seconds)}, {"name": "LOAD_SEED", "value": str(seed)},
           {"name": "LOAD_MIX", "value": json.dumps(mix or SPEC["load"]["mix"], separators=(",", ":"))}]
    if pattern:                            # mmpp:BURST:HIGH_S:LOW_S, ramp:FROM:TO, step:AT_S:FACTOR
        env.append({"name": "LOAD_PATTERN", "value": pattern})
    labels = {"app": "maze-load", "rbd.load": name}
    return [{"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": ns, "labels": labels},
             "spec": {"backoffLimit": 0, "template": {"metadata": {"labels": labels}, "spec": {
                 "restartPolicy": "Never",
                 "nodeSelector": {POOL: "load"},
                 "tolerations": [{"key": POOL, "operator": "Equal", "value": "load", "effect": "NoSchedule"}],
                 "imagePullSecrets": [{"name": PULL_SECRET}],
                 "containers": [{"name": "load", "image": _ref("load", image), "imagePullPolicy": "IfNotPresent",
                                 "env": env, "resources": {"requests": {"cpu": "100m"}}}]}}}}]


WEIGHT = re.compile(r"^[0-9]+(\.[0-9]+)?$")


def mix_targets() -> dict[str, str]:
    """spec.json's load.mix URLs by name, the URL's last path segment (browse, card, wallet), in spec order."""
    out: dict[str, str] = {}
    for m in SPEC["load"]["mix"]:
        name = m["url"].rstrip("/").rsplit("/", 1)[-1]
        if not name or name in out:
            raise ValueError(f"spec.json load.mix: {m['url']!r} has no last path segment of its own")
        out[name] = m["url"]
    return out


def parse_weights(text: str) -> list[tuple[str, str, float]]:
    """'browse=0.7,card=0.18,wallet=0.12' -> [(name, url, w)] in spec order; ValueError (the reason) when it is not
    every URL of spec.json's load.mix named once, with a plain decimal W >= 0 that a float holds, the sum > 0 and finite."""
    targets = mix_targets()
    got: dict[str, float] = {}
    for part in (text or "").split(","):
        name, eq, w = part.strip().partition("=")
        if not eq or not name:
            raise ValueError(f"{part.strip()!r} is not NAME=WEIGHT")
        if name not in targets:
            raise ValueError(f"unknown name {name!r} (spec.json's load.mix: {', '.join(targets)})")
        if name in got:
            raise ValueError(f"{name} named twice")
        if not WEIGHT.match(w):
            raise ValueError(f"{name}={w!r}: the weight is a plain decimal >= 0 (e.g. 0.7, 91)")
        got[name] = float(w)
        if not math.isfinite(got[name]) or (got[name] == 0 and w.strip("0.")):   # 1 and 400 zeros: inf; 0.(400 zeros)1: 0.0
            raise ValueError(f"{name}={w[:24]}{'...' if len(w) > 24 else ''}: too {'large' if got[name] else 'small'} for a float "
                             "(the weights are relative: scale them)")
    missing = [n for n in targets if n not in got]
    if missing:
        raise ValueError(f"no weight for {', '.join(missing)}: name every one of {', '.join(targets)} (0 leaves one out)")
    if not sum(got.values()) > 0:
        raise ValueError("the weights sum to 0")
    if not math.isfinite(sum(got.values())):
        raise ValueError("the weights sum past a float's range (the weights are relative: scale them)")
    return [(n, u, got[n]) for n, u in targets.items()]


def job_mix(weights: list[tuple[str, str, float]]) -> list[dict]:
    """LOAD_MIX for maze-load: [{url, w}] of the weights > 0 (a URL with no requests would print no result line)."""
    return [{"url": u, "w": w} for _, u, w in weights if w > 0]


def dump(docs) -> str:
    return "\n---\n".join(json.dumps(d, indent=1) for d in docs) + "\n"


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("what", choices=("app", "load"))
    p.add_argument("--image", action="append", default=[], help="app: service=REF@sha256:... (every service)")
    p.add_argument("--load-image", help="load: the maze-load image, REF@sha256:...")
    p.add_argument("--seconds", type=float, default=660)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--rps", type=float)
    p.add_argument("--name", default="maze-load")
    p.add_argument("--namespace", default=NS)
    p.add_argument("--mix", help="JSON file: [{url, w}] (default: spec.json's)")
    p.add_argument("--mix-weights", help="load: browse=W,card=W,wallet=W (every URL of spec.json's mix by its last path "
                                         "segment, once; W >= 0, sum > 0; a 0 leaves the URL out)")
    p.add_argument("--pattern", help="load: mmpp:BURST:HIGH_S:LOW_S, ramp:FROM:TO or step:AT_S:FACTOR (default Poisson)")
    a = p.parse_args()
    if a.what == "app":
        pairs = [x.split("=", 1) for x in a.image]
        if any(len(x) != 2 for x in pairs):
            sys.exit("render.py app: --image takes service=REF@sha256:...")
        print(dump(app(dict(pairs))), end="")
    else:
        if not a.load_image:
            sys.exit("render.py load: --load-image REF@sha256:... is required")
        if a.mix and a.mix_weights:
            sys.exit("render.py load: --mix or --mix-weights, not both")
        mix = json.loads(pathlib.Path(a.mix).read_text()) if a.mix else None
        if a.mix_weights:
            try:
                mix = job_mix(parse_weights(a.mix_weights))
            except ValueError as e:
                sys.exit(f"render.py load: --mix-weights: {e}")
        print(dump(load(a.load_image, a.seconds, a.seed, a.rps, a.name, a.namespace, mix, a.pattern)), end="")
