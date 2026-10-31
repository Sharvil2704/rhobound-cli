# The two workflows parsed (PyYAML when present, else a structural line check) and held to SPEC 6: triggers, permissions,
# concurrency, the self-hosted runner, the pinned checkout, every step through sudo -n -u rbd /opt/rbd/ci/<step>.sh, no
# ${{ }} inside a run script, the status/summary plumbing; deploy.yml's merge-parent lookup; CI v2 (SPEC2 4): services out of
# pr-check, one build, one ab.sh per service (AB_DIR ab-<service>), run with a stub sudo. Prints the structure.
#   python3 -I tools1/tests/ci/t_workflows.py
import json
import os
import re
import sys

KIT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
WF = os.path.join(KIT, "repo", ".github", "workflows")
fails = []
passes = 0


def check(desc, cond):
    global passes
    if cond:
        passes += 1
        print("  ok   " + desc)
    else:
        fails.append(desc)
        print("  FAIL " + desc)


try:
    import yaml
except ImportError:
    yaml = None
print("== workflows (%s)" % ("PyYAML %s" % yaml.__version__ if yaml else "no PyYAML: line checks only"))
text = {n: open(os.path.join(WF, n)).read() for n in ("gate.yml", "deploy.yml")}
for n, t in text.items():
    check("%s: no tabs, no trailing spaces" % n, "\t" not in t and not re.search(r" +$", t, re.M))
    check("%s: actions/checkout pinned by a full commit sha" % n,
          re.search(r"uses: actions/checkout@[0-9a-f]{40} # v\d", t) is not None and "@v" not in t.split("checkout")[1][:3])
    check("%s: no account id or IP" % n, not re.search(r"\b\d{12}\b|\b(\d{1,3}\.){3}\d{1,3}\b", t))
if not yaml:
    sys.exit(1 if fails else 0)

g = yaml.safe_load(text["gate.yml"])
d = yaml.safe_load(text["deploy.yml"])


def on(w):
    return w.get("on", w.get(True))  # YAML 1.1 reads the key on as True


def runs(job):
    return [s.get("run", "") for s in job["steps"]]


gj, dj = g["jobs"]["gate"], d["jobs"]["deploy"]
check("gate: on pull_request to main", on(g) == {"pull_request": {"branches": ["main"]}})
check("gate: permissions contents read, statuses write", g["permissions"] == {"contents": "read", "statuses": "write"})
check("gate: one concurrency group per PR, no cancel (2026-10-31: a shared group dropped a pending run)",
      g["concurrency"] == {"group": "rbd-gate-${{ github.event.pull_request.number }}", "cancel-in-progress": False})
check("gate: runs-on [self-hosted, rbd-demo]", gj["runs-on"] == ["self-hosted", "rbd-demo"])
check("gate: bash with pipefail (shell: bash)", gj["defaults"]["run"]["shell"] == "bash")
co = gj["steps"][0]
check("gate: checkout of the PR head, fetch-depth 0, no persisted credentials",
      co["with"] == {"ref": "${{ github.event.pull_request.head.sha }}", "fetch-depth": 0, "persist-credentials": False})
called = [m for r in runs(gj) for m in re.findall(r"sudo -n -u rbd /opt/rbd/ci/([a-z-]+)\.sh", r)]
check("gate: steps in order pr-check, build, ab, predict, sign, report (all via sudo -n -u rbd)",
      called == ["pr-check", "build", "ab", "predict", "sign", "report"])
check("gate: no ${{ }} expression inside any run script (inputs come through env)", all("${{" not in r for r in runs(gj)))
rep = next(s for s in gj["steps"] if s.get("id") == "report")
check("gate: the report goes to GITHUB_STEP_SUMMARY (all but report.sh's JSON line)",
      "sed '$d' \"$RUNNER_TEMP/report.out\" >> \"$GITHUB_STEP_SUMMARY\"" in rep["run"])
st = next(s for s in gj["steps"] if "rhobound/verdict" in s.get("name", ""))
check("gate: commit status rhobound/verdict via the REST API with GITHUB_TOKEN, always()",
      st["if"] == "${{ always() }}" and st["env"]["GITHUB_TOKEN"] == "${{ secrets.GITHUB_TOKEN }}"
      and "/statuses/" in gj["env"]["STATUS_URL"] and 'context:"rhobound/verdict"' in st["run"])
check("gate: status success on pass, failure on block|inconclusive, description 'verdict: rule'",
      "pass) state=success" in st["run"] and "block | inconclusive) state=failure" in st["run"] and 'desc="$VERDICT: $RULE"' in st["run"])
pr = next(s for s in gj["steps"] if s.get("id") == "predict")
check("gate: predict keeps going on block (1) and inconclusive (3), stops on anything else",
      "rc=${PIPESTATUS[0]}" in pr["run"] and "0 | 1 | 3) ;;" in pr["run"])
last = gj["steps"][-1]
check("gate: the job fails unless pass, with the verdict as the error title",
      'echo "::error title=rhobound gate: $VERDICT::' in last["run"] and "exit 1" in last["run"])
check("deploy: on push to main", on(d) == {"push": {"branches": ["main"]}})
check("deploy: permissions contents read only", d["permissions"] == {"contents": "read"})
check("deploy: runs-on [self-hosted, rbd-demo]", dj["runs-on"] == ["self-hosted", "rbd-demo"])
check("deploy: checkout of the merge commit with its parents (fetch-depth 2)", dj["steps"][0]["with"]["fetch-depth"] == 2)
check("deploy: the PR head = the merge commit's second parent", 'git rev-parse -q --verify "$GITHUB_SHA^2"' in dj["steps"][1]["run"])
called = [m for r in runs(dj) for m in re.findall(r"sudo -n -u rbd /opt/rbd/ci/([a-z-]+\.sh[^|\n]*)", r)]
check("deploy: report.sh then deploy.sh --run <PR head>", called == ['report.sh "$PR_HEAD" ',
                                                                   'deploy.sh --run "$PR_HEAD" '])
check("deploy: no ${{ }} expression inside any run script", all("${{" not in r for r in runs(dj)))
check("deploy: bash with pipefail (shell: bash)", dj["defaults"]["run"]["shell"] == "bash")
# the runner's sudoers line lists exactly these steps (part B); refit, capture and judge are never called through sudo
ALLOWED = {"pr-check", "build", "ab", "predict", "sign", "report", "deploy"}
allrun = runs(gj) + runs(dj)
sudos = [l for r in allrun for l in r.splitlines() if "sudo" in l]
calls = [m for l in sudos for m in re.findall(r"sudo -n -u rbd /opt/rbd/ci/([a-z-]+)\.sh", l)]
check("every sudo call is sudo -n -u rbd /opt/rbd/ci/<step>.sh of the sudoers list (%s)" % ", ".join(sorted(set(calls))),
      len(calls) == len(sudos) == sum(l.count("sudo") for l in sudos) and set(calls) <= ALLOWED)
check("no run script calls judge.sh, capture.sh or refit.sh", not any(x in r for r in allrun for x in ("judge.sh", "capture.sh", "refit.sh")))
# GITHUB_TOKEN never in a command line: curl reads it from a mktemp (0600) config file, removed on exit
tok = [r for r in allrun if "GITHUB_TOKEN" in r or "curl" in r]
check("the token reaches curl only through -K <0600 mktemp file> (%d scripts), never in a command's arguments" % len(tok),
      len(tok) == 2 and all(not ("curl" in l and ("GITHUB_TOKEN" in l or "Authorization" in l)) for r in tok for l in r.splitlines())
      and all('curl -fsS -K "$cfg"' in r and 'cfg=$(mktemp "$RUNNER_TEMP/' in r and "trap 'rm -f \"$cfg\"' EXIT" in r for r in tok))
import shutil, subprocess, tempfile
with tempfile.TemporaryDirectory(dir=os.environ.get("SCRATCH", "$HOME/rbd-dev/tmp")) as td:
    os.makedirs(os.path.join(td, "bin"))
    with open(os.path.join(td, "bin", "curl"), "w") as f:
        f.write('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$LOGD/argv"\n'
                'while [ $# -gt 0 ]; do if [ "$1" = -K ]; then stat -c %a "$2" > "$LOGD/mode"; cp "$2" "$LOGD/cfg"; shift; fi; shift; done\n'
                'cat > "$LOGD/body"\n')
    os.chmod(os.path.join(td, "bin", "curl"), 0o755)
    good = []
    for i, r in enumerate(tok):
        logd, rt = os.path.join(td, "log%d" % i), os.path.join(td, "rt%d" % i)
        os.makedirs(logd), os.makedirs(rt)
        f = os.path.join(td, "step%d.sh" % i)
        open(f, "w").write(r)
        env = dict(os.environ, PATH=os.path.join(td, "bin") + ":" + os.environ["PATH"], LOGD=logd, RUNNER_TEMP=rt,
                   GITHUB_TOKEN="ghs_TESTTOKEN0123456789", RUN_URL="https://github.com/o/r/actions/runs/1",
                   STATUS_URL="https://api.github.com/repos/o/r/statuses/" + "a" * 40,
                   OUTCOMES="pr-check=success build=success ab=success predict=success sign=success report=success",
                   VERDICT="pass", RULE="mean_change@storefront")
        out = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", f], env=env, capture_output=True, text=True)
        rd = lambda n: open(os.path.join(logd, n)).read() if os.path.exists(os.path.join(logd, n)) else ""
        good.append(out.returncode == 0 and "ghs_TESTTOKEN" not in rd("argv") and rd("mode").strip() == "600"
                    and rd("cfg") == 'header = "Authorization: Bearer ghs_TESTTOKEN0123456789"\n' and not os.listdir(rt)
                    and '"context":"rhobound/verdict"' in rd("body"))
        if not good[-1]:
            print("     step %d: rc %d argv=%r mode=%r cfg=%r left=%r err=%s" % (i, out.returncode, rd("argv"), rd("mode"),
                  rd("cfg"), os.listdir(rt), out.stderr[-300:]))
    check("the status steps run (stub curl): token not in curl's argv, config file mode 600 then removed, body sent",
          len(good) == 2 and all(good))
# CI v2: pr-check -> service + services outputs; ONE build for all services (its baselines map); one ab.sh per service
step = {s.get("id"): s for s in gj["steps"] if s.get("id")}
check("gate: pr-check writes service (the first) and services (a comma list) to GITHUB_OUTPUT",
      'echo "service=$(jq -r .service <<< "$last")"' in step["prc"]["run"]
      and """echo "services=$(jq -r '.services // [.service] | join(",")' <<< "$last")\"""" in step["prc"]["run"])
check("gate: build once with the first service, every listed service must have a production digest, outputs digest + baselines",
      step["build"]["env"] == {"SERVICE": "${{ steps.prc.outputs.service }}", "SERVICES": "${{ steps.prc.outputs.services }}"}
      and step["build"]["run"].count("/opt/rbd/ci/build.sh") == 1 and 'echo "baselines=$bases"' in step["build"]["run"]
      and "::error title=no production image::" in step["build"]["run"])
check("gate: one ab.sh per listed service, AB_DIR ab-<service>, that service's production digest, the one candidate",
      step["ab"]["env"] == {"SERVICES": "${{ steps.prc.outputs.services }}", "BASES": "${{ steps.build.outputs.baselines }}",
                            "CAND": "${{ steps.build.outputs.digest }}"}
      and 'for svc in "${svcs[@]}"; do' in step["ab"]["run"]
      and 'sudo -n -u rbd /opt/rbd/ci/ab.sh "$HEAD_SHA" "$svc" "$base" "$CAND" "ab-$svc"' in step["ab"]["run"])
# and run them (stub sudo prints the step's canned last line): what reaches GITHUB_OUTPUT and ab.sh's arguments
with tempfile.TemporaryDirectory(dir=os.environ.get("SCRATCH", "$HOME/rbd-dev/tmp")) as td:
    os.makedirs(os.path.join(td, "bin"))
    with open(os.path.join(td, "bin", "sudo"), "w") as f:
        f.write('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$LOGD/sudo"\n'
                'case $4 in */pr-check.sh) echo "$PRC_OUT" ;; */build.sh) echo "$BUILD_OUT" ;; *) echo \'{"step":"ab","ok":true}\' ;; esac\n')
    os.chmod(os.path.join(td, "bin", "sudo"), 0o755)
    D = {s: "sha256:" + s[0] * 64 for s in ("catalog", "pricing", "x")}

    def runstep(name, extra, build_out=None):
        logd = tempfile.mkdtemp(dir=td)
        open(os.path.join(logd, "out"), "w").close()
        env = dict(os.environ, PATH=os.path.join(td, "bin") + ":" + os.environ["PATH"], LOGD=logd, RUNNER_TEMP=logd,
                   GITHUB_OUTPUT=os.path.join(logd, "out"), GITHUB_WORKSPACE="/w", HEAD_SHA="a" * 40, BASE_SHA="b" * 40,
                   PRC_OUT=json.dumps({"step": "pr-check", "ok": True, "service": "catalog", "services": ["catalog", "pricing"],
                                       "base": "go127"}),
                   BUILD_OUT=json.dumps(build_out or {"step": "build", "ok": True, "service": "catalog", "digest": D["x"],
                                                      "baseline_digest": D["catalog"],
                                                      "baselines": {"catalog": D["catalog"], "pricing": D["pricing"]}}), **extra)
        f = os.path.join(logd, "step.sh")
        open(f, "w").write(step[name]["run"])
        out = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", f], env=env, capture_output=True, text=True)
        rd = lambda n: open(os.path.join(logd, n)).read() if os.path.exists(os.path.join(logd, n)) else ""
        return out, rd("out"), rd("sudo")

    out, o, _ = runstep("prc", {})
    check("gate (run, stub sudo): pr-check's outputs are service=catalog and services=catalog,pricing",
          out.returncode == 0 and o.splitlines() == ["service=catalog", "services=catalog,pricing"])
    out, o, s = runstep("build", {"SERVICE": "catalog", "SERVICES": "catalog,pricing"})
    check("gate (run): build.sh called once with the first service; outputs digest and the baselines map",
          out.returncode == 0 and s.splitlines() == ["-n -u rbd /opt/rbd/ci/build.sh /w %s catalog" % ("a" * 40)]
          and o.splitlines() == ["digest=" + D["x"], "baselines=" + json.dumps({"catalog": D["catalog"], "pricing": D["pricing"]},
                                                                                  separators=(",", ":"))])
    out, o, s = runstep("build", {"SERVICE": "catalog", "SERVICES": "catalog,pricing"},
                        {"step": "build", "ok": True, "service": "catalog", "digest": D["x"], "baselines": {"catalog": D["catalog"]}})
    check("gate (run): the build step fails when a listed service (pricing) has no production digest",
          out.returncode != 0 and "no digest for pricing" in out.stdout and "baselines=" not in o)
    out, o, s = runstep("build", {"SERVICE": "auth", "SERVICES": "auth"},
                        {"step": "build", "ok": True, "service": "auth", "digest": D["x"], "baseline_digest": D["catalog"]})
    check("gate (run): a build.sh last line without baselines (v1) still gives baselines {auth: baseline_digest}",
          out.returncode == 0 and "baselines=" + json.dumps({"auth": D["catalog"]}, separators=(",", ":")) in o.splitlines())
    out, o, s = runstep("ab", {"SERVICES": "catalog,pricing", "CAND": D["x"],
                               "BASES": json.dumps({"catalog": D["catalog"], "pricing": D["pricing"]})})
    check("gate (run): ab.sh once per service: RUN, the service, its production digest, the one candidate, AB_DIR ab-<service>",
          out.returncode == 0 and s.splitlines() == ["-n -u rbd /opt/rbd/ci/ab.sh %s %s %s %s ab-%s" % ("a" * 40, v, D[v], D["x"], v)
                                                     for v in ("catalog", "pricing")])
if shutil.which("shellcheck"):
    bad = []
    with tempfile.TemporaryDirectory(dir=os.environ.get("SCRATCH", "$HOME/rbd-dev/tmp")) as td:
        for name, job in (("gate", gj), ("deploy", dj)):
            for i, r in enumerate(runs(job)):
                if not r:
                    continue
                f = os.path.join(td, "%s-%d.sh" % (name, i))
                open(f, "w").write("#!/usr/bin/env bash\nset -eo pipefail\n" + r)
                out = subprocess.run(["shellcheck", "-s", "bash", f], capture_output=True, text=True)
                if out.returncode:
                    bad.append("%s step %d:\n%s" % (name, i, out.stdout))
    check("every run script is shellcheck-clean (bash -eo pipefail)", not bad)
    for b in bad:
        print(b)
for name, w, job in (("gate.yml", g, gj), ("deploy.yml", d, dj)):
    print("  %s: on=%s runs-on=%s concurrency=%s" % (name, list(on(w)), job["runs-on"], w.get("concurrency", {}).get("group")))
    for s in job["steps"]:
        print("     - %-55s %s" % (s.get("name", s.get("uses")), ("id=" + s["id"]) if "id" in s else ""))
print("  -- %d passed, %d failed" % (passes, len(fails)))
sys.exit(1 if fails else 0)
