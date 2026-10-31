"""mkscore.py: writes the synthetic scoreboard inputs beside itself (state/, tasks/, truth/) for t_bench_score.py.

    python3 -I tools1/tests/bench/fixtures/score/mkscore.py     (re-run after changing it; the output is committed)

Three tasks in the shared schemas (funnel.json rbd.bench-funnel/v1, timeline.json, pr.json, task.json) with every stage firing:
  T1-rank   model: m1 compile cut (S1), m2 selected after a judge revise (a rescue), m3 hidden-test cut (S2), m4 goroutine fan-out
            cut by rhobound (S4 utilization_after) although its microbench is FASTER (B4 says pass); references good/slow/
            latency-bad/wrong. Gate pass, merged, deployed; the gate's artifacts (predict, gate, prediction, ab-catalog).
  T2-round  the decoy: latency does not separate; m-b hidden cut, m-c outranked; the gate says inconclusive, not merged.
  T3-fold   everything cut: m-perdoc and m-maprune by rhobound, m-once vetoed by the judge after a rhobound pass, m-bad hidden.
            Its m-perdoc is the truth bracket t3-perdoc (deployed on purpose: +6 ms at storefront).
Calibration: cal-aa (catalog, same digest) and cal-ref (T1's good reference). prodcheck.json is NOT here: the test makes it
with tools1/bench/prodcheck.py from the ci fixture fit, so the two programs' key names are checked together.
"""
import json
import os

H = os.path.dirname(os.path.abspath(__file__))
H1 = "1" * 40
H2 = "2" * 40
LOAD = os.path.join(H, "..", "..", "..", "..", "..", "verify", "tests", "fixtures", "rs2-base-poisson100-r1.load.json")


def w(rel, obj):
    p = os.path.join(H, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(obj if isinstance(obj, str) else json.dumps(obj, indent=1, sort_keys=True) + "\n")


def ap(id_, origin, strategy, reached, cut=None, sel=False, s1=None, s2=None, s3=None, s4=None, s5=None):
    return {"id": id_, "origin": origin, "strategy": strategy, "stage_reached": reached,
            "cut": None if cut is None else {"stage": cut[0], "reason": cut[1]},
            "s1": s1 or ({"compiled": True, "visible_pass": True, "turns": 6, "tokens": 20000} if origin == "model" else
                         {"compiled": True, "visible_pass": True, "turns": 0, "tokens": 0}),
            "s2": s2, "s3": s3, "s4": s4, "s5": s5, "selected": sel}


def s4(verdict, rule, svc, d, band, th=3.397):
    return {"verdict": verdict, "binding_rule": rule, "declared": {svc: {"lo": min(d * 0.8, d * 2.0), "hi": max(d * 0.8, d * 2.0)}},
            "entries": [{"name": "storefront", "band_lo": band[0], "band_hi": band[1], "threshold": th},
                        {"name": "checkout", "band_lo": -0.4, "band_hi": 0.4, "threshold": 4.461}]}


OK2 = {"hidden_pass": True, "failed": []}
task1 = {"id": "T1-rank", "category": "perf-opt", "prompt": "make Rank faster, identical results", "services": ["catalog"],
         "writable": ["kshop/app/internal/hot/"], "hidden": "hidden/", "bench": ["BenchmarkRank"], "k": 4, "base": None,
         "refs": [{"name": "ref-index", "kind": "good", "patch": "refs/ref-index.patch"},
                  {"name": "ref-slow", "kind": "slow", "patch": "refs/ref-slow.patch"},
                  {"name": "ref-fanout", "kind": "latency-bad", "patch": "refs/ref-fanout.patch"},
                  {"name": "ref-wrong", "kind": "wrong", "patch": "refs/ref-wrong.patch"}],
         "visits_per_entry": {"storefront": 1.0}}
f1 = {"schema": "rbd.bench-funnel/v1", "task": "T1-rank", "started_at": "2026-10-30T21:00:00Z", "finished_at": "2026-10-30T21:35:00Z",
      "base_sha": "a" * 40, "coder": "muse-spark-1.3", "judge": "muse-wonder-1.0", "k": 4, "selected": "m2",
      "timings": {"S0": 40, "S1": 900, "S2": 120, "S3": 400, "S4": 20, "S5": 300, "S6": 5},
      "approaches": [
          ap("m1", "model", "precompute-tokens", "S1", ("S1", "does not compile"),
             s1={"compiled": False, "visible_pass": False, "turns": 9, "tokens": {"input": 30000, "output": 5000}}),
          ap("m2", "model", "inverted-index", "S6", sel=True, s2=OK2,
             s3={"delta_ms": -5.2, "spread_ms": 0.3, "allocs": 12, "base_ms": 6.8},
             s4=s4("pass", "mean_change", "catalog", -5.2, (-9.8, -3.1)),
             s5={"decision": "accept", "issues": [{"code": "unbounded-cache", "severity": "major", "fix": "bound it"}], "revised": True}),
          ap("m3", "model", "heap-topk", "S2", ("S2", "hidden: TestRankTies"), s2={"hidden_pass": False, "failed": ["TestRankTies"]}),
          ap("m4", "model", "goroutine-fanout", "S4", ("S4", "rhobound: utilization_after at catalog"), s2=OK2,
             s3={"delta_ms": -2.0, "spread_ms": 0.6, "allocs": 400},
             s4=s4("block", "utilization_after", "catalog", -2.0, (-3.0, 9.5))),
          ap("ref-index", "reference", "ref-index", "S6", s2=OK2, s3={"delta_ms": -5.5, "spread_ms": 0.2, "allocs": 10, "base_ms": 6.8},
             s4=s4("pass", "mean_change", "catalog", -5.5, (-10.1, -3.4))),
          ap("ref-slow", "reference", "ref-slow", "S4", ("S4", "rhobound: mean_change at storefront"), s2=OK2,
             s3={"delta_ms": 3.0, "spread_ms": 0.2, "allocs": 10}, s4=s4("block", "mean_change", "catalog", 3.0, (2.1, 7.9))),
          ap("ref-fanout", "reference", "ref-fanout", "S4", ("S4", "rhobound: saturates"), s2=OK2,
             s3={"delta_ms": -1.5, "spread_ms": 0.5, "allocs": 300}, s4=s4("block", "saturates", "catalog", -1.5, (-2.0, 30.0))),
          ap("ref-wrong", "reference", "ref-wrong", "S2", ("S2", "hidden: TestRankScores"), s2={"hidden_pass": False, "failed": ["TestRankScores"]}),
      ]}
w("tasks/T1-rank/task.json", task1)
w("state/T1-rank/funnel.json", f1)
w("state/T1-rank/pr.json", {"task": "T1-rank", "change": "c7-bench", "branch": "rbd/c7-bench", "pr": 7, "head": H1,
                            "run": "b-T1-rank-302100", "url": "https://github.com/Sharvil2704/rhobound-demo/pull/7"})
w("state/T1-rank/timeline.json", {"task": "T1-rank", "pr": 7, "head": H1, "gate_run": 507, "gate_started": "2026-10-30T21:41:00Z",
                                  "gate_ended": "2026-10-30T21:55:00Z", "verdict": "pass", "rule": "mean_change@storefront",
                                  "merged_at": "2026-10-30T21:56:00Z", "merge_sha": "e" * 40, "deploy_run": 9001,
                                  "deploy_ended": "2026-10-30T22:12:00Z", "deploy_ok": True})
w("state/runs/%s/predict.json" % H1, {"step": "predict", "ok": True, "exit": 0, "verdict": "pass", "rule": "mean_change@storefront",
                                      "service": "catalog", "delta_ms": -4.8})
w("state/runs/%s/gate/gate.json" % H1, {"schema": "rhobound.gate/v1", "verdict": "pass", "exit_code": 0,
                                        "rules": [{"number": "10", "rule": "mean_change", "effect": "pass", "entry": "storefront",
                                                   "value": -3.9, "threshold": 3.397, "evaluated": True}]})
w("state/runs/%s/prediction.json" % H1, {"version": "rhobound-cli.report/v2", "entries": [
    {"name": "storefront", "before_ms": 67.95, "change_ms": {"lo": -5.0, "hi": -4.6}, "band_ms": {"lo": -6.4, "hi": -3.9}},
    {"name": "checkout", "before_ms": 89.22, "change_ms": {"lo": 0.0, "hi": 0.0}, "band_ms": {"lo": -0.5, "hi": 0.5}}]})
w("state/runs/%s/ab-catalog/ab.json" % H1, {"schema": "rbd.ab/v1", "run": H1, "service": "catalog", "ok": True, "seconds": 300,
                                            "base_digest": "sha256:" + "b" * 64, "cand_digest": "sha256:" + "c" * 64,
                                            "record": {"service": {"service": "catalog", "own_ms": {"delta": -4.8, "se": 0.15}}}})

task2 = {"id": "T2-round", "category": "swe-fix", "prompt": "per-line half-to-even", "services": ["pricing"],
         "writable": ["kshop/app/internal/hot/"], "hidden": "hidden/", "bench": ["BenchmarkQuote"], "k": 3, "base": None,
         "refs": [{"name": "ref-good", "kind": "good", "patch": "refs/ref-good.patch"},
                  {"name": "ref-wrong", "kind": "wrong", "patch": "refs/ref-wrong.patch"}], "visits_per_entry": {"checkout": 1.0, "storefront": 1.0}}
f2 = {"schema": "rbd.bench-funnel/v1", "task": "T2-round", "started_at": "2026-10-30T22:20:00Z", "finished_at": "2026-10-30T22:50:00Z",
      "base_sha": "e" * 40, "coder": "muse-spark-1.3", "judge": "muse-wonder-1.0", "k": 3, "selected": "m-a",
      "timings": {"S0": 30, "S1": 700}, "approaches": [
          ap("m-a", "model", "decimal-cents", "S6", sel=True, s2=OK2, s3={"delta_ms": 0.0, "spread_ms": 0.01, "allocs": 3},
             s4=s4("pass", "mean_change", "pricing", 0.0, (-0.3, 0.3)), s5={"decision": "accept", "issues": [], "revised": False}),
          ap("m-b", "model", "round-total", "S2", ("S2", "hidden: TestPerLineRounding"), s2={"hidden_pass": False, "failed": ["TestPerLineRounding"]}),
          ap("m-c", "model", "big-rat", "S6", ("S6", "outranked by m-a"), s2=OK2, s3={"delta_ms": 0.01, "spread_ms": 0.01, "allocs": 30},
             s4=s4("pass", "mean_change", "pricing", 0.01, (-0.3, 0.4)), s5={"decision": "accept", "issues": [], "revised": False}),
          ap("ref-good", "reference", "ref-good", "S6", s2=OK2, s3={"delta_ms": 0.0, "spread_ms": 0.01, "allocs": 3},
             s4=s4("pass", "mean_change", "pricing", 0.0, (-0.3, 0.3))),
          ap("ref-wrong", "reference", "ref-wrong", "S2", ("S2", "hidden: TestPerLineRounding"), s2={"hidden_pass": False, "failed": ["x"]}),
      ]}
w("tasks/T2-round/task.json", task2)
w("state/T2-round/funnel.json", f2)
w("state/T2-round/pr.json", {"task": "T2-round", "change": "c8-bench", "branch": "rbd/c8-bench", "pr": 8, "head": H2, "run": "b-T2-round-302220"})
w("state/T2-round/timeline.json", {"task": "T2-round", "pr": 8, "head": H2, "gate_run": 508, "gate_started": "2026-10-30T23:00:00Z",
                                   "gate_ended": "2026-10-30T23:12:00Z", "verdict": "inconclusive", "rule": "unmeasured_delta",
                                   "merged_at": None, "merge_sha": None, "deploy_run": None, "deploy_ended": None, "deploy_ok": None})

task3 = {"id": "T3-fold", "category": "feature", "prompt": "Fold strips accents", "services": ["catalog", "pricing"],
         "writable": ["kshop/app/internal/hot/"], "hidden": "hidden/", "bench": ["BenchmarkFold"], "k": 3, "base": None,
         "refs": [{"name": "ref-fold-once", "kind": "good", "patch": "refs/ref-fold-once.patch"}], "visits_per_entry": {"storefront": 1.0}}
f3 = {"schema": "rbd.bench-funnel/v1", "task": "T3-fold", "started_at": "2026-10-31T00:00:00Z", "finished_at": "2026-10-31T00:40:00Z",
      "base_sha": "e" * 40, "coder": "muse-spark-1.3", "judge": "muse-wonder-1.0", "k": 3, "selected": None,
      "timings": {"S0": 35}, "approaches": [
          ap("m-perdoc", "model", "fold-every-doc-per-request", "S4", ("S4", "rhobound: mean_change at storefront"), s2=OK2,
             s3={"delta_ms": 6.0, "spread_ms": 0.4, "allocs": 20000}, s4=s4("block", "mean_change", "catalog", 6.0, (4.1, 13.2))),
          ap("m-maprune", "model", "map-per-rune", "S4", ("S4", "rhobound: saturates"), s2=OK2,
             s3={"delta_ms": 9.0, "spread_ms": 0.8, "allocs": 90000}, s4=s4("block", "saturates", "catalog", 9.0, (6.0, 80.0))),
          ap("m-once", "model", "fold-at-build", "S5", ("S5", "judge: reject (changes ASCII ordering)"), s2=OK2,
             s3={"delta_ms": 0.05, "spread_ms": 0.05, "allocs": 4}, s4=s4("pass", "mean_change", "catalog", 0.05, (-0.2, 0.5)),
             s5={"decision": "reject", "issues": [{"code": "ascii-changed", "severity": "blocker", "fix": "keep ASCII"}], "revised": False}),
          ap("m-bad", "model", "nfd-strip", "S2", ("S2", "hidden: TestFoldFullWidth"), s2={"hidden_pass": False, "failed": ["TestFoldFullWidth"]}),
          ap("ref-fold-once", "reference", "ref-fold-once", "S6", s2=OK2, s3={"delta_ms": 0.04, "spread_ms": 0.05, "allocs": 4},
             s4=s4("pass", "mean_change", "catalog", 0.04, (-0.2, 0.5))),
      ]}
w("tasks/T3-fold/task.json", task3)
w("state/T3-fold/funnel.json", f3)

# calibration: the A/A A/B and T1's good reference through ab.sh
w("state/calibration.json", {"schema": "rbd.bench-calibration/v1", "runs": [
    {"name": "cal-aa", "kind": "aa", "run": "cal-aa", "service": "catalog"},
    {"name": "cal-ref", "kind": "reference", "run": "cal-ref", "service": "catalog", "task": "T1-rank", "approach": "ref-index",
     "microbench_delta_ms": -5.5}]})
for run, d, se in (("cal-aa", 0.03, 0.12), ("cal-ref", -5.0, 0.15)):
    w("state/runs/%s/ab-catalog/ab.json" % run, {"schema": "rbd.ab/v1", "run": run, "service": "catalog", "ok": True, "seconds": 300,
                                                 "record": {"service": {"service": "catalog", "own_ms": {"delta": d, "se": se}}}})

# truth arm: T3's m-perdoc deployed on purpose (+6 ms at storefront, +0.2 at checkout)
w("state/truth-map.json", {"schema": "rbd.bench-truth-map/v1", "brackets": [{"name": "t3-perdoc", "task": "T3-fold", "approach": "m-perdoc"}]})
b0 = open(LOAD).read()
c = []
for ln in b0.splitlines():
    if ln.startswith("{"):
        d = json.loads(ln)
        d["mean_ms"] += 6.0 if d["url"].endswith("/browse") else 0.2
        ln = json.dumps(d, sort_keys=True)
    c.append(ln.replace("2026/10/22 05:12:45", "2026/10/22 05:40:00").replace("seed 7", "seed 8"))
w("truth/t3-perdoc/b0.load.json", b0)
w("truth/t3-perdoc/c.load.json", "\n".join(c) + "\n")
w("truth/t3-perdoc/truth.json", {"schema": "rbd.truth/v1", "status": "ok", "service": "catalog", "base_digest": "sha256:" + "b" * 64,
                                 "cand_digest": "sha256:" + "d" * 64, "keep": False, "warnings": []})
print("mkscore: fixtures written under", H)
