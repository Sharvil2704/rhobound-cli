"""test_render.py: the kit's render.py against maze's own spec (github.com/Sharvil2704/rhobound-maze spec.json, the
config its local/run.py gives each process): every service, MAZE_CONFIG = {service, workers, routes}, the OpenTelemetry
endpoint and the load env; plus the k3s adaptations (images by digest from --image, pool nodeSelector,
imagePullSecrets ecr, IfNotPresent, k8s.container.name; load Job on the load pool with its toleration) and the refusals.
    python3 -I orch/tests/test_render.py
"""
import json
import os
import pathlib
import subprocess
import sys

DEMO = pathlib.Path(__file__).resolve().parents[2]
KIT = DEMO / "tools1/maze/render.py"
# the maze generator's own spec.json, when RBD_MAZE_SPEC names it (it is not part of this repository): the kit's must hold
# its services, load rate and mix; without it only the kit's own mix URLs are checked
MAZE = pathlib.Path(os.environ["RBD_MAZE_SPEC"]) if os.environ.get("RBD_MAZE_SPEC") else None
ECR = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze"
SPEC = json.loads((DEMO / "tools1/maze/spec.json").read_text())
fails = 0


def check(what, cond):
    global fails
    print(("  ok   " if cond else "  FAIL ") + what)
    fails += 0 if cond else 1


def run(script, *args, ok=True):
    r = subprocess.run([sys.executable, "-I", str(script), *args], capture_output=True, text=True, cwd="/")
    if ok and r.returncode != 0:
        raise SystemExit(f"{script} {args}: {r.stderr}")
    return r


def docs(text):
    return [json.loads(d) for d in text.split("\n---\n") if d.strip()]


def dig(i):
    return "sha256:" + f"{i:02d}" * 32


images = {s: f"{ECR}@{dig(i)}" for i, s in enumerate(sorted(SPEC["services"]))}
if MAZE is not None:
    orig = json.loads(MAZE.read_text())
    check("kit spec.json has maze's services and load rate", SPEC["services"] == orig["services"] and SPEC["load"]["rps"] == orig["load"]["rps"])
    check("kit spec.json's mix is maze's plus each entry's URL", [{k: v for k, v in m.items() if k != "url"} for m in SPEC["load"]["mix"]]
          == orig["load"]["mix"])
check("kit spec.json: each mix entry's URL is its service and path", all(m["url"] == f"http://{m['service']}:8080{m['path']}" for m in SPEC["load"]["mix"]))
check("kit spec.json is the repo's main (repo/maze/spec.json)", SPEC == json.loads((DEMO / "repo/maze/spec.json").read_text()))
kit = docs(run(KIT, "app", *[f"--image={k}={v}" for k, v in images.items()]).stdout)
kd = {d["metadata"]["name"]: d for d in kit if d["kind"] == "Deployment"}
ks = {d["metadata"]["name"]: d for d in kit if d["kind"] == "Service"}
check(f"one Deployment and one Service per service ({len(SPEC['services'])})", sorted(kd) == sorted(ks) == sorted(SPEC["services"]))
for name, d in kd.items():
    pk = d["spec"]["template"]["spec"]
    ck = pk["containers"][0]
    ek = {e["name"]: e for e in ck["env"]}
    sv = SPEC["services"][name]
    good = (json.loads(ek["MAZE_CONFIG"]["value"]) == {"service": name, "workers": sv["workers"], "routes": sv["routes"]}
            and ek["OTEL_SERVICE_NAME"]["value"] == name and "MAZE_PEERS" not in ek
            and ek["OTEL_RESOURCE_ATTRIBUTES"]["value"] == f"k8s.pod.name=$(POD_NAME),k8s.namespace.name=maze,k8s.container.name={name}"
            and d["spec"]["replicas"] == 1 and ck["name"] == name and ck["ports"] == [{"containerPort": 8080, "name": "http"}]
            and ck["readinessProbe"]["httpGet"] == {"path": "/healthz", "port": 8080}
            and ks[name]["spec"]["ports"] == [{"name": "http", "port": 8080, "targetPort": 8080}])
    check(f"{name}: MAZE_CONFIG = spec's workers and routes, service name, pod name attribute, port 8080, /healthz", good)
    adapted = (ck["image"] == images[name] and ck["imagePullPolicy"] == "IfNotPresent"
               and pk["nodeSelector"] == {"rhobound.io/pool": "app"} and pk["imagePullSecrets"] == [{"name": "ecr"}]
               and "tolerations" not in pk)
    check(f"{name}: image by digest from --image, IfNotPresent, nodeSelector pool=app, imagePullSecrets ecr", adapted)
check("OTLP endpoint is our Collector (maze-obs)", all(
    {e["name"]: e.get("value") for e in d["spec"]["template"]["spec"]["containers"][0]["env"]}["OTEL_EXPORTER_OTLP_ENDPOINT"]
    == "http://otel-collector.maze-obs.svc.cluster.local:4318" for d in kd.values()))

LOAD = f"{ECR}@{dig(42)}"
jk = docs(run(KIT, "load", "--load-image", LOAD, "--seconds", "600", "--seed", "7", "--name", "maze-load").stdout)[0]
ps = jk["spec"]["template"]["spec"]
env = {e["name"]: e["value"] for e in ps["containers"][0]["env"]}
check("load: env LOAD_RPS 120, LOAD_SECONDS, LOAD_SEED, LOAD_MIX = spec's mix (url, w)",
      env["LOAD_RPS"] == "120" and env["LOAD_SECONDS"] == "600.0" and env["LOAD_SEED"] == "7"
      and [(m["url"], m["w"]) for m in json.loads(env["LOAD_MIX"])] == [(m["url"], m["w"]) for m in SPEC["load"]["mix"]])
check("load: Job maze-load, backoffLimit 0, restartPolicy Never", jk["metadata"]["name"] == "maze-load"
      and jk["spec"]["backoffLimit"] == 0 and ps["restartPolicy"] == "Never")
check("load: image by digest, nodeSelector pool=load, toleration pool=load:NoSchedule, imagePullSecrets ecr",
      ps["containers"][0]["image"] == LOAD and ps["nodeSelector"] == {"rhobound.io/pool": "load"}
      and ps["tolerations"] == [{"key": "rhobound.io/pool", "operator": "Equal", "value": "load", "effect": "NoSchedule"}]
      and ps["imagePullSecrets"] == [{"name": "ecr"}] and ps["containers"][0]["imagePullPolicy"] == "IfNotPresent")
mw = docs(run(KIT, "load", "--load-image", LOAD, "--mix-weights", "browse=1,feed=0,q=2,buy=0,bulk=1").stdout)[0]
mix = json.loads({e["name"]: e["value"] for e in mw["spec"]["template"]["spec"]["containers"][0]["env"]}["LOAD_MIX"])
check("load --mix-weights by the URLs' last segments (browse feed q buy bulk); a 0 leaves the URL out",
      mix == [{"url": "http://web:8080/browse", "w": 1.0}, {"url": "http://search-api:8080/q", "w": 2.0},
              {"url": "http://partner:8080/bulk", "w": 1.0}])
bg = docs(run(KIT, "load", "--load-image", LOAD, "--seconds", "43200", "--seed", "1001", "--name", "maze-bgload").stdout)[0]
check("bgload: its own Job name and seconds", bg["metadata"]["name"] == "maze-bgload"
      and {e["name"]: e["value"] for e in bg["spec"]["template"]["spec"]["containers"][0]["env"]}["LOAD_SECONDS"] == "43200.0")

# refusals
r = run(KIT, "app", *[f"--image={k}={v}" for k, v in list(images.items())[:-1]], ok=False)
check("app with all but one image is refused", r.returncode != 0 and "missing" in r.stderr)
r = run(KIT, "app", *[f"--image={k}={v}" for k, v in images.items()], "--image=nosuch=" + images["auth"], ok=False)
check("an unknown service is refused", r.returncode != 0 and "unknown" in r.stderr)
bad = dict(images, auth=f"{ECR}:auth-latest")
r = run(KIT, "app", *[f"--image={k}={v}" for k, v in bad.items()], ok=False)
check("an image by tag (not digest) is refused", r.returncode != 0 and "digest" in r.stderr)
r = run(KIT, "load", "--seconds", "600", ok=False)
check("load without --load-image is refused", r.returncode != 0)
print(f"test_render.py: {'0 failed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
