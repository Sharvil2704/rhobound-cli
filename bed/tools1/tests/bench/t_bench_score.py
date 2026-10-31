"""t_bench_score.py: tools1/bench/prodcheck.py (S10) and verify/bench_score.py (SPEC2 section 5) on synthetic inputs.

    python3 -I tools1/tests/bench/t_bench_score.py      (scratch: S8_SCRATCH [$HOME/rbd-dev/tmp/s8]/t-score)

prodcheck: the ci fixture fit (a real rs2 window) against a variant with catalog 4.5 ms faster (own and observed) and storefront
4.2 ms faster; per entry and per service deltas, the predicted band, the notes (same fit, rates differ), a fit folder argument,
exit 2 on an unreadable fit. bench_score: fixtures/score (mkscore.py) plus that prodcheck.json: cut attribution (correctness
never rhobound), model/reference rows apart, gate-minutes vs B1/B3, B4 vs S4, the judge's rescue and veto, efficiency, time to
production, the accuracy chain to production, calibration, the truth arm; a broken funnel row is listed as a problem (exit 1).
"""
import copy
import json
import os
import shutil
import subprocess
import sys

H = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(os.path.dirname(os.path.dirname(H)))
FIT = os.path.join(KIT, "tools1", "tests", "ci", "fixtures", "fit.json")
FX = os.path.join(H, "fixtures", "score")
T = os.path.join(os.environ.get("S8_SCRATCH", "$HOME/rbd-dev/tmp/s8"), "t-score")
PASS = FAIL = 0


def check(what, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   " + what)
    else:
        FAIL += 1
        print("  FAIL " + what)


def run(*args):
    p = subprocess.run([sys.executable, "-I"] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def jl(p):
    with open(p) as f:
        return json.load(f)


shutil.rmtree(T, ignore_errors=True)
os.makedirs(T)
print("== prodcheck.py")
PC = os.path.join(KIT, "tools1", "bench", "prodcheck.py")
fit = jl(FIT)
cur = copy.deepcopy(fit)
for s in cur["inference"]["stats"]:
    if s["name"] == "catalog":
        s["own_mean_ms"] -= 4.5
        s["observed_server_ms"] -= 4.5
    if s["name"] == "storefront":
        s["observed_server_ms"] -= 4.2
cur["window"]["start"] = "2026-10-30T22:02:00Z"
os.makedirs(os.path.join(T, "cur"))
with open(os.path.join(T, "cur", "fit.json"), "w") as f:
    json.dump(cur, f)
PRED = os.path.join(FX, "state", "runs", "1" * 40, "prediction.json")
out = os.path.join(T, "prodcheck.json")
rc, so, se = run(PC, "--previous", FIT, "--current", os.path.join(T, "cur"), "--services", "catalog", "--prediction", PRED, "--out", out)
check("exit 0, written (rc %d %s)" % (rc, se.strip()[:200]), rc == 0 and os.path.isfile(out))
d = jl(out)
ent = {e["name"]: e for e in d["entries"]}
svc = {s["name"]: s for s in d["services"]}
check("schema rbd.bench-prodcheck/v1, report_only", d["schema"] == "rbd.bench-prodcheck/v1" and d["report_only"] is True)
check("entries: the fit's two entry services (checkout, storefront)", sorted(ent) == ["checkout", "storefront"])
check("storefront: -4.2 ms observed, in the predicted band (-6.4..-3.9)", abs(ent["storefront"]["delta_ms"] + 4.2) < 1e-6 and ent["storefront"]["in_band"] is True)
check("checkout: unchanged, in its band", abs(ent["checkout"]["delta_ms"]) < 1e-9 and ent["checkout"]["in_band"] is True)
check("services: all 10, catalog marked changed with own -4.5 ms", len(svc) == 10 and svc["catalog"]["changed"] is True
      and abs(svc["catalog"]["delta_own_ms"] + 4.5) < 1e-6 and svc["auth"]["changed"] is False)
check("previous/current carry path, sha256 digest, capture, window", d["previous"]["digest"].startswith("sha256:")
      and d["previous"]["digest"] != d["current"]["digest"] and d["current"]["window"]["start"] == "2026-10-30T22:02:00Z")
check("services_changed = [catalog], no notes", d["services_changed"] == ["catalog"] and d["notes"] == [])
rc, so, se = run(PC, "--previous", FIT, "--current", FIT)
d2 = json.loads(so) if rc == 0 else {}
check("the same fit twice: stdout JSON, zero deltas, a note says so", rc == 0 and all(e["delta_ms"] == 0 for e in d2["entries"])
      and any("same fit" in n for n in d2["notes"]))
fast = copy.deepcopy(fit)
for s in fast["inference"]["stats"]:
    s["rate_rps"] *= 1.2
with open(os.path.join(T, "fast.json"), "w") as f:
    json.dump(fast, f)
rc, so, se = run(PC, "--previous", FIT, "--current", os.path.join(T, "fast.json"))
check("windows whose entry rates differ by 20%: noted (the comparison is weaker)", rc == 0 and any("rates differ" in n for n in json.loads(so)["notes"]))
rc, so, se = run(PC, "--previous", os.path.join(T, "nope.json"), "--current", FIT)
check("an unreadable fit: exit 2 (rc %d)" % rc, rc == 2)
with open(os.path.join(T, "notfit.json"), "w") as f:
    json.dump({"schema": "rhobound.prediction/v1"}, f)
rc, so, se = run(PC, "--previous", os.path.join(T, "notfit.json"), "--current", FIT)
check("not a rhobound.fit/v1: exit 2 (rc %d)" % rc, rc == 2)

print("== bench_score.py")
BS = os.path.join(KIT, "verify", "bench_score.py")
ST = os.path.join(T, "state")
shutil.copytree(os.path.join(FX, "state"), ST)
shutil.copy(out, os.path.join(ST, "T1-rank", "prodcheck.json"))
MD, JS = os.path.join(T, "demo2-bench.md"), os.path.join(T, "demo2-bench.json")
args = ["--state", ST, "--tasks", os.path.join(FX, "tasks"), "--truth", os.path.join(FX, "truth"), "--aa", os.path.join(T, "no-aa"),
        "--out-md", MD, "--out-json", JS, "--now", "2026-10-31T03:00:00Z", "--usd-per-mtok", "2"]
rc, so, se = run(BS, *args)
check("exit 0, both reports written (rc %d %s)" % (rc, se.strip()[:300]), rc == 0 and os.path.isfile(MD) and os.path.isfile(JS))
doc = jl(JS)
tk = {t["id"]: t for t in doc["tasks"]}
md = open(MD).read()
check("schema rbd.bench-score/v1, three tasks, no problems", doc["schema"] == "rbd.bench-score/v1" and sorted(tk) == ["T1-rank", "T2-round", "T3-fold"]
      and doc["problems"] == [])
t1, t2, t3 = tk["T1-rank"], tk["T2-round"], tk["T3-fold"]
check("T1 cut attribution: correctness (S1 m1, S2 m3 + ref-wrong) is never credited to rhobound",
      sorted(t1["correctness_cuts"]) == ["m1", "m3", "ref-wrong"] and t1["cuts_by"]["model"]["correctness"] == 2
      and t1["cuts_by"]["model"]["rhobound"] == 1 and not set(t1["correctness_cuts"]) & set(t1["rhobound_cuts"]))
check("T1 rhobound cuts: m4 (model), ref-slow and ref-fanout (references), counted apart",
      sorted(t1["rhobound_cuts"]) == ["m4", "ref-fanout", "ref-slow"] and t1["cuts_by"]["reference"]["rhobound"] == 2)
check("T1 stage counts: model S1 in 4 cut 1, S2 in 3 cut 1, S4 in 2 cut 1, S6 in 1",
      [(t1["stage_counts"]["model"][s]["in"], t1["stage_counts"]["model"][s]["cut"]) for s in ("S1", "S2", "S4", "S6")] == [(4, 1), (3, 1), (2, 1), (1, 0)])
check("model rows and reference rows are separate tables in the report", "**Model approaches**" in md and
      "**Reference rows (the kit's, never mixed with the model's)**" in md and md.count("| ref-index | ref-index | good |") == 1)
check("T1 B4 (naive additive) says pass where S4 blocked the fan-out (m4)", {"id": "m4", "b4": "pass", "s4": "block"} in t1["b4_vs_s4"])
check("T3 B4 agrees with S4 on the per-doc fold (block)", {"id": "m-perdoc", "b4": "block", "s4": "block"} in t3["b4_vs_s4"])
check("judge: T1's m2 rescued after a revise; T3's m-once vetoed after a rhobound pass",
      t1["judge"]["rescues"] == ["m2"] and t3["judge"]["vetoes"] == ["m-once"] and t3["judge"]["vetoes_of_rhobound_pass"] == ["m-once"])
check("gate-minutes: 14 + 12 spent, mean 13; B1 = 7 model approaches past S2 x 13 = 91; B3 = 7 x 11 = 77",
      doc["totals"]["gate_minutes"] == 26 and doc["totals"]["gate_min_mean"] == 13 and doc["totals"]["b1_minutes"] == 91
      and doc["totals"]["b3_minutes"] == 77 and t1["b1_minutes"] == 26)
check("efficiency: m2 (shipped) vs ref-index time ratio (6.8-5.2)/(6.8-5.5) = 1.2308",
      any(e["id"] == "m2" and e["selected"] and e["metric"].startswith("time ratio") and abs(e["value"] - 1.2308) < 1e-3 for e in t1["efficiency"]))
check("efficiency: no ratio where the reference saves nothing (T3)", t3["efficiency"] == [])
tt = t1["time_to_production"]
check("T1 time to production 72 min (funnel 35, gate 14, deploy 16), verified by the prodcheck",
      tt["total_min"] == 72 and tt["funnel_min"] == 35 and tt["gate_min"] == 14 and tt["deploy_min"] == 16 and tt["verified"] is True)
check("T2 (inconclusive, not merged) and T3 (nothing selected): not deployed",
      t2["time_to_production"]["deployed"] is False and t3["time_to_production"]["total_min"] is None and t3["chain"] is None)
c = t1["chain"]
check("accuracy chain T1: declared -> microbench -5.2 -> A/B catalog -4.8 +- 0.15 -> gate pass -> production",
      c["approach"] == "m2" and c["microbench_delta_ms"] == -5.2 and c["ab"][0]["own_ms_delta"] == -4.8 and c["gate"]["verdict"] == "pass"
      and c["production"] is not None)
check("...transfer A/B / microbench 0.923; the declared band (-10.4..-4.16) covers the A/B",
      c["transfer"] == [{"service": "catalog", "ab_over_microbench": 0.923}] and c["declared_covers_ab"] == {"catalog": True})
pe = {e["name"]: e for e in c["production"]["entries"]}
check("...production (prodcheck.json): storefront -4.2 ms in the band; catalog own-time / A/B = 0.9375",
      abs(pe["storefront"]["delta_ms"] + 4.2) < 1e-6 and pe["storefront"]["in_band"] is True
      and c["production"]["services"][0]["prod_over_ab"] == 0.938)
cal = doc["calibration"]
check("calibration: the A/A A/B (+0.03 +- 0.12) and the reference transfer 0.909, range [0.855, 0.964]",
      cal["aa"][0]["ab_delta_ms"] == 0.03 and cal["reference"][0]["transfer"] == 0.909 and cal["transfer_range"] == [0.855, 0.964])
tr = doc["truth"][0]
check("truth arm: t3-perdoc (cut at S4) observed +6 ms at storefront over 3.40: regression, as predicted",
      tr["truth"] == "regression" and tr["as_predicted"] is True and tr["entries"][0]["name"] in ("storefront", "checkout")
      and any(e["name"] == "storefront" and abs(e["observed_ms"] - 6.0) < 1e-3 and e["in_band"] is True for e in tr["entries"]))
check("cost: model tokens 235000 over 69 turns, $0.47 at $2/Mtok (references not counted)",
      doc["totals"]["tokens"] == 235000 and doc["totals"]["turns"] == 69 and doc["totals"]["usd"] == 0.47)
check("the report has every section", all(h in md for h in ("## Summary", "## T1-rank (perf-opt)", "**Accuracy chain**",
                                                             "## Calibration", "## Truth arm", "## Definitions", "## Inputs")))
check("the report says correctness cuts are never credited to rhobound", "never credited to rhobound" in md)
check("B5 is reported as n/a when the funnel has no estimate", "n/a (the funnel carries no s1.estimate_ms)" in md)
check("no rhobound code imported by bench_score.py", "import rhobound" not in open(BS).read() and "from rhobound" not in open(BS).read())

# a broken funnel row and a missing task.json are problems (exit 1), the report is still written
f = jl(os.path.join(ST, "T2-round", "funnel.json"))
f["approaches"][1]["stage_reached"] = "S9"
f["approaches"][2]["origin"] = "human"
with open(os.path.join(ST, "T2-round", "funnel.json"), "w") as fh:
    json.dump(f, fh)
os.rename(os.path.join(ST, "T2-round"), os.path.join(ST, "T9-x"))
rc, so, se = run(BS, *args)
doc = jl(JS)
check("a broken funnel row: exit 1, the problems listed, the report still written (rc %d)" % rc,
      rc == 1 and any("S9" in p for p in doc["problems"]) and any("origin 'human'" in p for p in doc["problems"])
      and "**Problems (" in open(MD).read())
rc, so, se = run(BS, "--state", os.path.join(T, "empty"), "--out-md", MD, "--out-json", JS)
check("no funnel.json at all: exit 2 (rc %d)" % rc, rc == 2)
print("  -- %d passed, %d failed" % (PASS, FAIL))
if not os.environ.get("KEEP"):
    shutil.rmtree(T, ignore_errors=True)
sys.exit(1 if FAIL else 0)
