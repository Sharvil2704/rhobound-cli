#!/usr/bin/env python3
"""verify/bench_score.py: the rbd-bench scoreboard (SPEC2 section 5) -> reports/demo2-bench.md + reports/demo2-bench.json.

The orchestrator's, on this box: reads files only (python3 -I, stdlib; no rhobound code, no command, no network).

usage:
  python3 -I verify/bench_score.py [--state state/bench] [--tasks tools1/bench/tasks] [--truth verify/data/truth]
                                   [--aa verify/data/aa] [--out-md reports/demo2-bench.md] [--out-json reports/demo2-bench.json]
                                   [--canary-roll-min 3] [--canary-window-min 5] [--gate-min-default 20] [--usd-per-mtok X]
exit 0 written; 1 written, problems listed (an unreadable input, a funnel row that breaks the schema); 2 cannot run.

Reads (every path optional except at least one funnel.json):
  STATE/<task>/funnel.json      rbd.bench-funnel/v1 (tools1/bench/run_task.py): approaches[] with stage_reached, cut, s1..s5,
                                selected; timings S0..S6 (s); started_at/finished_at
  STATE/<task>/timeline.json    orch/automerge.sh: gate_started/ended, verdict, rule, merged_at, merge_sha, deploy_*
  STATE/<task>/pr.json          orch/bench.sh: {task, change, branch, pr, head, run, approach?}
  STATE/<task>/prodcheck.json   tools1/bench/prodcheck.py (rbd.bench-prodcheck/v1): S10, production before/after
  STATE/runs/<head>/{predict.json, gate/gate.json, prediction.json?, ab*/ab.json}   the gate's artifacts (orch/bench.sh fetches)
  STATE/calibration.json        rbd.bench-calibration/v1 {runs: [{name, kind: aa|reference, run, service, microbench_delta_ms?}]}:
                                the A/A A/B and the reference A/B (each run's ab*/ab.json under STATE/runs/<run>/)
  STATE/truth-map.json          rbd.bench-truth-map/v1 {brackets: [{name, task, approach}]}: which CUT approach each truth
                                bracket deployed on purpose; the bracket itself is TRUTH/<name>/{truth.json, b0.load.json, c.load.json}
                                (verify/truth.sh + collect.sh, as verify/score.py's bundle), scored with score.py's own parsing
  TASKS/<id>/task.json          refs[].kind (good|slow|latency-bad|wrong), visits_per_entry
  AA/*.load.json                optional A/A production windows: the truth arm's noise floor (verify/score.py's aa_floor)

Definitions (also written into the report):
  cut attribution  S1 compile/visible tests and S2 hidden tests = correctness (NEVER credited to rhobound); S3 = microbench;
                   S4 = rhobound (the preview: block or saturation); S5 = judge (reject); S6 = not selected (outranked).
  gate-minutes     the serial cluster time a gate holds (gate.yml run, gate_started -> gate_ended of the timeline).
                   B1 = every MODEL approach that passed S2 gated: n(S2 pass) x the mean measured gate minutes (else
                   --gate-min-default). B3 = every such approach canaried in production: n x (roll + window + rollback) =
                   n x (2 x --canary-roll-min + --canary-window-min).
  B4               naive additive: microbench delta per call x visits_per_entry, no queueing; decides block when it exceeds
                   the S4 entry threshold. Compared with S4's verdict and, where measured, the A/B and production.
  B5               the coder's own estimate: s1.estimate_ms when the funnel carries it, else n/a.
  efficiency       EvalPerf/EffiBench-style time ratio cand/ref = (base + d_cand)/(base + d_ref) when s3 carries base_ms
                   (or base_ns), else the saving ratio d_cand/d_ref (1.0 = the reference's saving; > 1 saves more).
  judge            reviewed = an s5 record; rescue = revised and then not cut (reached S6); veto = cut at S5.
  time to production  funnel started_at -> deploy_ended of a deploy_ok timeline; verified = a prodcheck.json too.
"""
import argparse
import calendar
import glob
import hashlib
import json
import math
import os
import sys
import time

sys.dont_write_bytecode = True   # no __pycache__ beside the kit's files
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # score.py, beside this file: its load.json parsing
import score  # noqa: E402  (verify/score.py: no rhobound code)

SCHEMA = "rbd.bench-score/v1"
STAGES = ["S1", "S2", "S3", "S4", "S5", "S6"]
WHO = {"S1": "correctness", "S2": "correctness", "S3": "microbench", "S4": "rhobound", "S5": "judge", "S6": "not selected"}
INPUTS = []
PROBLEMS = []


def num(x):
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) else None


def g(d, path, default=None):
    for k in path.split("."):
        if not isinstance(d, dict):
            return default
        d = d.get(k)
    return default if d is None else d


def load(path, required=False):
    if not os.path.isfile(path):
        if required:
            PROBLEMS.append("missing: %s" % path)
        return None
    try:
        with open(path, "rb") as f:
            b = f.read()
        d = json.loads(b)
    except (OSError, ValueError) as e:
        PROBLEMS.append("unreadable: %s: %s" % (path, e))
        return None
    rel = os.path.relpath(path)
    INPUTS.append({"path": path if rel.startswith("..") else rel, "sha256": "sha256:" + hashlib.sha256(b).hexdigest()})
    return d


def tparse(s):
    """an RFC 3339 UTC time (GitHub's, the funnel's) -> epoch seconds; fractions and a +00:00 suffix ignored."""
    if not isinstance(s, str) or len(s) < 19:
        return None
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def minutes(a, b):
    ta, tb = tparse(a), tparse(b)
    return None if ta is None or tb is None else (tb - ta) / 60.0


def sidx(s):
    return STAGES.index(s) if s in STAGES else -1


def r(x, n=3):
    return None if x is None else round(x, n)


def tokens_of(v):
    """s1.tokens: a number, or {total} or {input, output} (cached and reasoning are parts of those, not added)."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return int(v)
    if isinstance(v, dict):
        if num(v.get("total")) is not None:
            return int(num(v["total"]))
        return int((num(v.get("input")) or 0) + (num(v.get("output")) or 0))
    return 0


# ------------------------------------------------------------------------------------------------------------ gate artifacts
def gate_of(state, head):
    """runs/<head>/: predict.json, gate/gate.json, prediction.json, ab*/ab.json -> one summary."""
    if not head:
        return None
    d = os.path.join(state, "runs", head)
    if not os.path.isdir(d):
        return None
    pj = load(os.path.join(d, "predict.json"))
    gj = load(os.path.join(d, "gate", "gate.json"))
    pr = load(os.path.join(d, "prediction.json"))
    out = {"head": head, "verdict": g(pj, "verdict") or g(gj, "verdict"), "rule": g(pj, "rule"), "entries": [], "ab": []}
    for rule in (gj or {}).get("rules") or []:
        if rule.get("rule") == "mean_change" and rule.get("entry"):
            out["entries"].append({"name": rule["entry"], "band_hi": num(rule.get("value")),
                                   "threshold": num(rule.get("threshold")), "effect": rule.get("effect")})
    for e in (pr or {}).get("entries") or []:
        row = next((x for x in out["entries"] if x["name"] == e.get("name")), None)
        if row is None:
            row = {"name": e.get("name"), "band_hi": None, "threshold": None, "effect": None}
            out["entries"].append(row)
        row.update(band_lo=num(g(e, "band_ms.lo")), band_hi=num(g(e, "band_ms.hi")) if row["band_hi"] is None else row["band_hi"],
                   change_lo=num(g(e, "change_ms.lo")), change_hi=num(g(e, "change_ms.hi")), before_ms=num(e.get("before_ms")))
    for p in sorted(glob.glob(os.path.join(d, "ab*", "ab.json"))):
        a = load(p)
        if not a:
            continue
        svc = g(a, "record.service") or {}
        out["ab"].append({"dir": os.path.basename(os.path.dirname(p)), "service": a.get("service"), "ok": a.get("ok"),
                          "own_ms_delta": num(g(svc, "own_ms.delta")), "own_ms_se": num(g(svc, "own_ms.se")),
                          "seconds": num(a.get("seconds")), "base_digest": a.get("base_digest"), "cand_digest": a.get("cand_digest")})
    return out


# ------------------------------------------------------------------------------------------------------------ per task
def ref_kinds(task):
    return {x.get("name"): x.get("kind") for x in (task or {}).get("refs") or [] if isinstance(x, dict)}


def row_of(a, kinds):
    cut = a.get("cut") if isinstance(a.get("cut"), dict) else None
    st = cut.get("stage") if cut else None
    return {"id": a.get("id"), "origin": a.get("origin"), "strategy": a.get("strategy"),
            "kind": kinds.get(a.get("id")) or kinds.get(a.get("strategy")) if a.get("origin") == "reference" else None,
            "stage_reached": a.get("stage_reached"), "cut_stage": st, "cut_reason": cut.get("reason") if cut else None,
            "cut_by": WHO.get(st) if st else None, "selected": bool(a.get("selected")),
            "compiled": g(a, "s1.compiled"), "visible_pass": g(a, "s1.visible_pass"), "turns": g(a, "s1.turns"),
            "tokens": tokens_of(g(a, "s1.tokens")), "hidden_pass": g(a, "s2.hidden_pass"), "hidden_failed": g(a, "s2.failed"),
            "delta_ms": num(g(a, "s3.delta_ms")), "spread_ms": num(g(a, "s3.spread_ms")), "allocs": g(a, "s3.allocs"),
            "base_ms": num(g(a, "s3.base_ms")) if g(a, "s3.base_ms") is not None else
            (num(g(a, "s3.base_ns")) / 1e6 if num(g(a, "s3.base_ns")) is not None else None),
            "s4_verdict": g(a, "s4.verdict"), "s4_rule": g(a, "s4.binding_rule"), "declared": g(a, "s4.declared") or {},
            "s4_entries": [e for e in g(a, "s4.entries", []) if isinstance(e, dict)],
            "s5_decision": g(a, "s5.decision"), "s5_issues": len(g(a, "s5.issues", []) or []), "s5_revised": g(a, "s5.revised"),
            "estimate_ms": g(a, "s1.estimate_ms")}


def check_row(task, a):
    st = a.get("stage_reached")
    if st not in STAGES:
        PROBLEMS.append("%s/%s: stage_reached %r is not S1..S6" % (task, a.get("id"), st))
    if a.get("origin") not in ("model", "reference"):
        PROBLEMS.append("%s/%s: origin %r is not model|reference" % (task, a.get("id"), a.get("origin")))
    cut = a.get("cut")
    if cut is not None and (not isinstance(cut, dict) or cut.get("stage") not in STAGES):
        PROBLEMS.append("%s/%s: cut %r has no S1..S6 stage" % (task, a.get("id"), cut))
    if isinstance(cut, dict) and a.get("selected"):
        PROBLEMS.append("%s/%s: cut and selected" % (task, a.get("id")))


def stage_counts(rows):
    out = {}
    for origin in ("model", "reference"):
        rs = [x for x in rows if x["origin"] == origin]
        c = {}
        for s in STAGES:
            entered = [x for x in rs if sidx(x["stage_reached"]) >= sidx(s)]
            cut = [x for x in rs if x["cut_stage"] == s]
            c[s] = {"in": len(entered), "cut": len(cut)}
        out[origin] = c
    return out


def b4(row, visits):
    """naive additive: delta per call x visits per entry; block when over the S4 entry threshold."""
    if row["delta_ms"] is None or not visits:
        return None
    out = {"entries": [], "verdict": "pass"}
    for e, v in sorted(visits.items()):
        vv = num(v) if not isinstance(v, dict) else sum(num(x) or 0 for x in v.values())
        if vv is None:
            continue
        est = row["delta_ms"] * vv
        th = next((num(x.get("threshold")) for x in row["s4_entries"] if x.get("name") == e), None)
        over = th is not None and est > th
        out["entries"].append({"name": e, "estimate_ms": r(est, 4), "threshold": th, "over": over})
        if over:
            out["verdict"] = "block"
    return out


def efficiency(rows, kinds):
    good = [x for x in rows if x["origin"] == "reference" and x["delta_ms"] is not None and (x["kind"] in (None, "good"))]
    best = min(good, key=lambda x: x["delta_ms"]) if good else None
    out = []
    for x in rows:
        if x["origin"] != "model" or x["delta_ms"] is None or best is None:
            continue
        e = {"id": x["id"], "ref": best["id"], "selected": x["selected"]}
        base = x["base_ms"] if x["base_ms"] is not None else best["base_ms"]
        if base is not None and base + best["delta_ms"] > 0:
            e["metric"], e["value"] = "time ratio cand/ref", r((base + x["delta_ms"]) / (base + best["delta_ms"]), 4)
        elif best["delta_ms"] < 0 and -best["delta_ms"] > (best["spread_ms"] or 0.0):
            e["metric"], e["value"] = "saving ratio d_cand/d_ref", r(x["delta_ms"] / best["delta_ms"], 4)
        else:
            continue   # no base time and the reference saves nothing measurable: no ratio means anything
        out.append(e)
    return out


def judge(rows):
    rev = [x for x in rows if x["s5_decision"] is not None]
    return {"reviewed": len(rev),
            "accept": sum(1 for x in rev if x["s5_decision"] == "accept"),
            "revise": sum(1 for x in rev if x["s5_decision"] == "revise" or x["s5_revised"]),
            "reject": sum(1 for x in rev if x["s5_decision"] == "reject"),
            "rescues": [x["id"] for x in rows if x["s5_revised"] and x["cut_stage"] is None and x["stage_reached"] == "S6"],
            "vetoes": [x["id"] for x in rows if x["cut_stage"] == "S5"],
            "vetoes_of_rhobound_pass": [x["id"] for x in rows if x["cut_stage"] == "S5" and x["s4_verdict"] == "pass"]}


def chain(row, gate, prod):
    """declared -> microbench -> A/B -> gate prediction -> production, for one gated approach."""
    c = {"approach": row["id"] if row else None, "declared": row["declared"] if row else {},
         "microbench_delta_ms": row["delta_ms"] if row else None, "ab": [], "gate": None, "production": None,
         "transfer": [], "declared_covers_ab": {}}
    if gate:
        c["ab"] = gate["ab"]
        c["gate"] = {"verdict": gate["verdict"], "rule": gate["rule"], "entries": gate["entries"]}
        for a in gate["ab"]:
            if a["own_ms_delta"] is not None and c["microbench_delta_ms"]:
                c["transfer"].append({"service": a["service"], "ab_over_microbench": r(a["own_ms_delta"] / c["microbench_delta_ms"], 3)})
            dec = (c["declared"] or {}).get(a["service"]) if isinstance(c["declared"], dict) else None
            if isinstance(dec, dict) and a["own_ms_delta"] is not None and num(dec.get("lo")) is not None:
                lo, hi = sorted((num(dec.get("lo")), num(dec.get("hi"))))
                c["declared_covers_ab"][a["service"]] = lo <= a["own_ms_delta"] <= hi
    if prod:
        c["production"] = {"entries": [{k: e.get(k) for k in ("name", "delta_ms", "delta_pct", "in_band", "predicted")}
                                       for e in prod.get("entries") or []],
                           "services": [{k: s.get(k) for k in ("name", "delta_own_ms", "delta_observed_ms")}
                                        for s in prod.get("services") or [] if s.get("changed")],
                           "notes": prod.get("notes") or []}
        for s in c["production"]["services"]:
            ab = next((a for a in c["ab"] if a["service"] == s["name"] and a["own_ms_delta"]), None)
            if ab and num(s.get("delta_own_ms")) is not None:
                s["prod_over_ab"] = r(s["delta_own_ms"] / ab["own_ms_delta"], 3)
    return c


def score_task(state, tdir, tasks_dir, opts, gate_mins):
    f = load(os.path.join(tdir, "funnel.json"), required=True)
    if not f:
        return None
    tid = f.get("task") or os.path.basename(tdir)
    task = load(os.path.join(tasks_dir, tid, "task.json")) if tasks_dir else None
    if task is None:
        PROBLEMS.append("%s: no task.json under %s (reference kinds and visits_per_entry unknown)" % (tid, tasks_dir))
    kinds = ref_kinds(task)
    visits = (task or {}).get("visits_per_entry") or {}
    for a in f.get("approaches") or []:
        check_row(tid, a)
    rows = [row_of(a, kinds) for a in f.get("approaches") or [] if isinstance(a, dict)]
    tl = load(os.path.join(tdir, "timeline.json"))
    pr = load(os.path.join(tdir, "pr.json"))
    prod = load(os.path.join(tdir, "prodcheck.json"))
    head = (tl or {}).get("head") or (pr or {}).get("head")
    gate = gate_of(state, head)
    sel = next((x for x in rows if x["selected"]), None)
    if f.get("selected") and (sel is None or sel["id"] != f.get("selected")):
        PROBLEMS.append("%s: funnel selected %r but no approach row says selected" % (tid, f.get("selected")))
    gmin = minutes((tl or {}).get("gate_started"), (tl or {}).get("gate_ended"))
    if gmin is not None:
        gate_mins.append(gmin)
    t = {"id": tid, "category": (task or {}).get("category") or f.get("category"), "coder": f.get("coder"),
         "judge_model": f.get("judge"), "k": f.get("k"), "base_sha": f.get("base_sha"), "selected": f.get("selected"),
         "rows": rows, "stage_counts": stage_counts(rows),
         "cuts_by": {o: {w: sum(1 for x in rows if x["origin"] == o and x["cut_by"] == w) for w in sorted(set(WHO.values()))}
                     for o in ("model", "reference")},
         "rhobound_cuts": [x["id"] for x in rows if x["cut_stage"] == "S4"],
         "correctness_cuts": [x["id"] for x in rows if x["cut_stage"] in ("S1", "S2")],
         "timeline": tl, "gate": gate, "gate_minutes": r(gmin, 2),
         "n_tests_pass": sum(1 for x in rows if x["origin"] == "model" and
                             (sidx(x["stage_reached"]) >= sidx("S3") or x["hidden_pass"] is True)),
         "b4": {x["id"]: b4(x, visits) for x in rows if x["delta_ms"] is not None},
         "b5": {x["id"]: x["estimate_ms"] for x in rows if x["estimate_ms"] is not None},
         "judge": judge(rows), "efficiency": efficiency(rows, kinds),
         "tokens": sum(x["tokens"] for x in rows if x["origin"] == "model"),
         "turns": sum(int(num(x["turns"]) or 0) for x in rows if x["origin"] == "model"),
         "timings_s": f.get("timings") or {}, "prodcheck": prod}
    t["b4_vs_s4"] = [{"id": i, "b4": v["verdict"], "s4": next(x["s4_verdict"] for x in rows if x["id"] == i)}
                     for i, v in t["b4"].items() if v]
    # time to production
    st, fin = f.get("started_at"), f.get("finished_at")
    ttp = {"funnel_min": r(minutes(st, fin), 1), "to_gate_start_min": r(minutes(fin, g(tl, "gate_started")), 1),
           "gate_min": r(gmin, 1), "to_merge_min": r(minutes(g(tl, "gate_ended"), g(tl, "merged_at")), 1),
           "deploy_min": r(minutes(g(tl, "merged_at"), g(tl, "deploy_ended")), 1),
           "total_min": r(minutes(st, g(tl, "deploy_ended")), 1) if g(tl, "deploy_ok") is True else None,
           "deployed": g(tl, "deploy_ok") is True, "verified": g(tl, "deploy_ok") is True and prod is not None}
    t["time_to_production"] = ttp
    t["chain"] = chain(sel, gate, prod) if (gate or prod) else None
    return t


# ------------------------------------------------------------------------------------------------------------ calibration, truth
def calibration(state):
    c = load(os.path.join(state, "calibration.json"))
    if not c:
        return None
    out = {"aa": [], "reference": [], "transfer_range": None}
    for run in c.get("runs") or []:
        gate = gate_of(state, run.get("run"))
        abs_ = [a for a in (gate or {}).get("ab", []) if not run.get("service") or a["service"] == run.get("service")]
        if not abs_:
            PROBLEMS.append("calibration %s: no ab*/ab.json under runs/%s" % (run.get("name"), run.get("run")))
            continue
        a = abs_[0]
        row = {"name": run.get("name"), "service": a["service"], "ab_delta_ms": a["own_ms_delta"], "ab_se_ms": a["own_ms_se"],
               "microbench_delta_ms": num(run.get("microbench_delta_ms"))}
        if run.get("kind") == "aa":
            out["aa"].append(row)
        else:
            if row["microbench_delta_ms"] and row["ab_delta_ms"] is not None:
                row["transfer"] = r(row["ab_delta_ms"] / row["microbench_delta_ms"], 3)
                se = row["ab_se_ms"] or 0.0
                lo, hi = sorted(((row["ab_delta_ms"] - 2 * se) / row["microbench_delta_ms"],
                                 (row["ab_delta_ms"] + 2 * se) / row["microbench_delta_ms"]))
                row["transfer_2se"] = [r(lo, 3), r(hi, 3)]
            out["reference"].append(row)
    ts = [x for y in out["reference"] for x in y.get("transfer_2se", [])]
    if ts:
        out["transfer_range"] = [min(ts), max(ts)]
    return out


def truth_arm(state, truth_dir, aa_dir, tasks_by_id):
    m = load(os.path.join(state, "truth-map.json"))
    if not m:
        return []
    floor = None
    if aa_dir and os.path.isdir(aa_dir):
        wins = []
        for p in sorted(glob.glob(os.path.join(aa_dir, "*.load.json"))):
            try:
                wins.append((os.path.basename(p), score.parse_load(p)))
            except score.Unusable as e:
                PROBLEMS.append("A/A window: %s" % e)
        floor = score.aa_floor(wins) if wins else None
    out = []
    for b in m.get("brackets") or []:
        name, tid, aid = b.get("name"), b.get("task"), b.get("approach")
        d = os.path.join(truth_dir or "", name or "")
        row = {"name": name, "task": tid, "approach": aid, "status": None, "entries": [], "as_predicted": None}
        tj = load(os.path.join(d, "truth.json"), required=True)
        row["status"] = (tj or {}).get("status")
        t = tasks_by_id.get(tid)
        ap = next((x for x in (t or {}).get("rows", []) if x["id"] == aid), None)
        if ap is None:
            PROBLEMS.append("truth %s: no approach %s in task %s's funnel" % (name, aid, tid))
        if row["status"] not in ("ok", "ok-kept"):
            PROBLEMS.append("truth %s: status %r (skipped)" % (name, row["status"]))
            out.append(row)
            continue
        try:
            b0, c = score.parse_load(os.path.join(d, "b0.load.json")), score.parse_load(os.path.join(d, "c.load.json"))
        except score.Unusable as e:
            PROBLEMS.append("truth %s: %s" % (name, e))
            out.append(row)
            continue
        verdicts = []
        for entry in score.ENTRIES:
            sb, _ = score.entry_stats(b0, entry)
            sc, _ = score.entry_stats(c, entry)
            obs = sc["mean_ms"] - sb["mean_ms"] if sb and sc else None
            s4e = next((x for x in (ap or {}).get("s4_entries", []) if x.get("name") == entry), {})
            th, lo, hi = num(s4e.get("threshold")), num(s4e.get("band_lo")), num(s4e.get("band_hi"))
            fl = num(g(floor, "entries.%s.floor_ms" % entry)) or 0.0
            cls = score.truth_class(obs, th, fl)
            verdicts.append(cls)
            row["entries"].append({"name": entry, "observed_ms": r(obs, 3), "threshold": th, "band_lo": lo, "band_hi": hi,
                                   "in_band": None if obs is None or lo is None or hi is None else lo <= obs <= hi,
                                   "floor_ms": r(fl, 3), "truth": cls})
        worst = max(verdicts, key=lambda v: score.TRUTH_RANK.get(v, 0)) if verdicts else "unknown"
        row["truth"] = worst
        s4 = (ap or {}).get("s4_verdict")
        predicted_hurt = s4 in ("block", "saturates") or (ap or {}).get("cut_stage") == "S4"
        if worst in ("regression", "clean"):
            row["as_predicted"] = (worst == "regression") == predicted_hurt
        row["predicted"] = "hurt (cut by rhobound at S4)" if predicted_hurt else "no hurt (S4 %s)" % s4
        out.append(row)
    return out


# ------------------------------------------------------------------------------------------------------------ report
def fmt(x, nd=2, sign=False):
    if x is None:
        return "-"
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, int) and not sign:
        return str(x)
    if isinstance(x, (int, float)):
        return ("%+.*f" if sign else "%.*f") % (nd, x)
    return str(x).replace("|", "/").replace("\n", " ")


def md(doc):
    L = ["# demo2: rbd-bench scoreboard", "",
         "Generated %s by `verify/bench_score.py` from the files listed at the end (reads files only; no rhobound code)." % doc["generated_at"],
         ""]
    if doc["problems"]:
        L += ["**Problems (%d):**" % len(doc["problems"]), ""] + ["- %s" % fmt(p) for p in doc["problems"]] + [""]
    tot = doc["totals"]
    L += ["## Summary", "",
          "| task | category | approaches (model/ref) | correctness cuts (model/ref) | rhobound cuts S4 (model/ref) | judge vetoes | selected | gate | merged | deployed | to production |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for t in doc["tasks"]:
        nm = sum(1 for x in t["rows"] if x["origin"] == "model")
        nr = sum(1 for x in t["rows"] if x["origin"] == "reference")
        tl = t["timeline"] or {}
        cb = t["cuts_by"]
        L.append("| %s | %s | %d/%d | %d/%d | %d/%d | %d | %s | %s | %s | %s | %s |" % (
            t["id"], fmt(t["category"]), nm, nr, cb["model"]["correctness"], cb["reference"]["correctness"],
            cb["model"]["rhobound"], cb["reference"]["rhobound"], len(t["judge"]["vetoes"]),
            fmt(t["selected"]), "%s %s" % (fmt(tl.get("verdict")), fmt(tl.get("rule"))) if tl else "-",
            fmt(bool(tl.get("merge_sha"))) if tl else "-", fmt(tl.get("deploy_ok")) if tl else "-",
            ("%s min%s" % (fmt(t["time_to_production"]["total_min"], 1), ", verified" if t["time_to_production"]["verified"] else ""))
            if t["time_to_production"]["total_min"] is not None else "-"))
    L += ["", "**Serial gate-minutes:** spent %s (%d gate%s, mean %s min) vs B1 (gate every test-passing approach) %s and "
          "B3 (canary every test-passing approach in production) %s." % (
              fmt(tot["gate_minutes"], 1), tot["gates"], "" if tot["gates"] == 1 else "s", fmt(tot["gate_min_mean"], 1),
              fmt(tot["b1_minutes"], 1), fmt(tot["b3_minutes"], 1)),
          "Tokens: %d over %d coder turns%s." % (tot["tokens"], tot["turns"],
                                               "; about $%.2f at $%s per Mtok" % (tot["usd"], doc["params"]["usd_per_mtok"]) if tot["usd"] is not None else ""),
          ""]
    for t in doc["tasks"]:
        L += ["## %s (%s)" % (t["id"], fmt(t["category"])), "",
              "Coder %s, judge %s, K=%s, base %s. Selected: **%s**." % (fmt(t["coder"]), fmt(t["judge_model"]), fmt(t["k"]),
                                                                        fmt((t["base_sha"] or "")[:12] or None), fmt(t["selected"])), ""]
        sc = t["stage_counts"]
        L += ["| stage | model in | model cut | reference in | reference cut | a cut here is credited to |", "|---|---|---|---|---|---|"]
        for s in STAGES:
            L.append("| %s | %d | %d | %d | %d | %s |" % (s, sc["model"][s]["in"], sc["model"][s]["cut"], sc["reference"][s]["in"],
                                                         sc["reference"][s]["cut"], WHO[s]))
        for origin, title in (("model", "Model approaches"), ("reference", "Reference rows (the kit's, never mixed with the model's)")):
            rs = [x for x in t["rows"] if x["origin"] == origin]
            if not rs:
                continue
            L += ["", "**%s**" % title, "",
                  "| id | strategy%s | reached | cut (by) | tests vis/hidden | microbench d ms (spread) | allocs | S4 verdict (rule) | B4 | judge | selected |" %
                  (" | kind" if origin == "reference" else ""),
                  "|---|---|%s---|---|---|---|---|---|---|---|---|" % ("---|" if origin == "reference" else "")]
            for x in rs:
                b = t["b4"].get(x["id"])
                L.append("| %s | %s%s | %s | %s | %s/%s | %s (%s) | %s | %s (%s) | %s | %s%s | %s |" % (
                    fmt(x["id"]), fmt(x["strategy"]), " | %s" % fmt(x["kind"]) if origin == "reference" else "", fmt(x["stage_reached"]),
                    "%s: %s (%s)" % (x["cut_stage"], fmt(x["cut_reason"]), x["cut_by"]) if x["cut_stage"] else "-",
                    fmt(x["visible_pass"]), fmt(x["hidden_pass"]), fmt(x["delta_ms"], 3, True), fmt(x["spread_ms"], 3),
                    fmt(x["allocs"]), fmt(x["s4_verdict"]), fmt(x["s4_rule"]), fmt(b["verdict"]) if b else "-",
                    fmt(x["s5_decision"]), " (revised)" if x["s5_revised"] else "", fmt(x["selected"])))
        j = t["judge"]
        L += ["", "Judge: %d reviewed (accept %d, revise %d, reject %d); rescues %s; vetoes %s (of a rhobound pass: %s)." % (
            j["reviewed"], j["accept"], j["revise"], j["reject"], fmt(", ".join(j["rescues"]) or None),
            fmt(", ".join(j["vetoes"]) or None), fmt(", ".join(j["vetoes_of_rhobound_pass"]) or None))]
        dis = [x for x in t["b4_vs_s4"] if x["b4"] != x["s4"] and x["s4"] is not None]
        L.append("B4 (naive additive, no queueing) vs S4: %d compared, %d disagree%s." % (
            len(t["b4_vs_s4"]), len(dis), (": " + ", ".join("%s (B4 %s, S4 %s)" % (x["id"], x["b4"], x["s4"]) for x in dis)) if dis else ""))
        L.append("B5 (the coder's own estimate): %s." % (
            ", ".join("%s %s" % (k, json.dumps(v)) for k, v in t["b5"].items()) if t["b5"] else "n/a (the funnel carries no s1.estimate_ms)"))
        if t["efficiency"]:
            L.append("Efficiency vs the best good reference: %s." % ", ".join(
                "%s%s %s %s" % (e["id"], " (shipped)" if e["selected"] else "", e["metric"], fmt(e["value"], 3)) for e in t["efficiency"]))
        L.append("Serial gate-minutes: spent %s; B1 %s (%d test-passing approaches gated); B3 %s (each canaried in production)." % (
            fmt(t["gate_minutes"], 1), fmt(t["b1_minutes"], 1), t["n_tests_pass"], fmt(t["b3_minutes"], 1)))
        tt = t["time_to_production"]
        L += ["", "Time to production: funnel %s min, then %s min to the gate, gate %s min, %s min to the merge, deploy + refit %s min: "
              "total %s min (%s)." % (fmt(tt["funnel_min"], 1), fmt(tt["to_gate_start_min"], 1), fmt(tt["gate_min"], 1),
                                       fmt(tt["to_merge_min"], 1), fmt(tt["deploy_min"], 1), fmt(tt["total_min"], 1),
                                       "deployed and production-checked" if tt["verified"] else "deployed" if tt["deployed"] else "not deployed")]
        if t["timings_s"]:
            L.append("Funnel stage seconds: %s." % ", ".join("%s %s" % (k, fmt(num(v), 0)) for k, v in sorted(t["timings_s"].items())))
        c = t["chain"]
        if c:
            L += ["", "**Accuracy chain** (%s): declared %s -> microbench %s ms/call -> A/B %s -> gate %s %s -> production %s." % (
                fmt(c["approach"]), json.dumps(c["declared"]) if c["declared"] else "-", fmt(c["microbench_delta_ms"], 4, True),
                ", ".join("%s %s +- %s ms" % (a["service"], fmt(a["own_ms_delta"], 3, True), fmt(a["own_ms_se"], 3)) for a in c["ab"]) or "-",
                fmt((c["gate"] or {}).get("verdict")), fmt((c["gate"] or {}).get("rule")),
                ", ".join("%s %s ms%s" % (e["name"], fmt(e["delta_ms"], 3, True),
                                          "" if e["in_band"] is None else " (in band)" if e["in_band"] else " (OUT of band)")
                          for e in (c["production"] or {}).get("entries", [])) or "-")]
            if c["transfer"]:
                L.append("Transfer A/B / microbench: %s; declared band covers the A/B: %s." % (
                    ", ".join("%s %s" % (x["service"], fmt(x["ab_over_microbench"], 3)) for x in c["transfer"]),
                    ", ".join("%s %s" % (k, fmt(v)) for k, v in c["declared_covers_ab"].items()) or "-"))
            if c["production"]:
                ps = [s for s in c["production"]["services"] if s.get("prod_over_ab") is not None]
                if ps:
                    L.append("Production own-time / A/B: %s." % ", ".join("%s %s" % (s["name"], fmt(s["prod_over_ab"], 3)) for s in ps))
                for n in c["production"]["notes"]:
                    L.append("Production note: %s" % fmt(n))
        L.append("")
    cal = doc["calibration"]
    L += ["## Calibration (before the first task gate)", ""]
    if cal:
        for a in cal["aa"]:
            L.append("- A/A A/B %s (%s, same digest both arms): %s +- %s ms own time." % (a["name"], a["service"], fmt(a["ab_delta_ms"], 3, True), fmt(a["ab_se_ms"], 3)))
        for a in cal["reference"]:
            L.append("- reference A/B %s (%s): A/B %s +- %s ms vs microbench %s ms/call: transfer %s (2 SE %s)." % (
                a["name"], a["service"], fmt(a["ab_delta_ms"], 3, True), fmt(a["ab_se_ms"], 3), fmt(a["microbench_delta_ms"], 4, True),
                fmt(a.get("transfer"), 3), fmt(json.dumps(a.get("transfer_2se")) if a.get("transfer_2se") else None)))
        L.append("- microbench -> A/B transfer range: %s." % (fmt(json.dumps(cal["transfer_range"])) if cal["transfer_range"] else "-"))
    else:
        L.append("No calibration.json.")
    L += ["", "## Truth arm (cut approaches deployed on purpose, then rolled back)", ""]
    if doc["truth"]:
        L += ["| bracket | task/approach | status | predicted | entries: observed ms vs threshold (band) | truth | as predicted |",
              "|---|---|---|---|---|---|---|"]
        for b in doc["truth"]:
            L.append("| %s | %s/%s | %s | %s | %s | %s | %s |" % (
                fmt(b["name"]), fmt(b["task"]), fmt(b["approach"]), fmt(b["status"]), fmt(b.get("predicted")),
                "; ".join("%s %s vs %s (%s..%s)" % (e["name"], fmt(e["observed_ms"], 2, True), fmt(e["threshold"], 2),
                                                    fmt(e["band_lo"], 2), fmt(e["band_hi"], 2)) for e in b["entries"]) or "-",
                fmt(b.get("truth")), fmt(b["as_predicted"])))
    else:
        L.append("No truth-map.json (or no bracket).")
    L += ["", "## Definitions", ""] + ["- **%s**: %s" % (k, v) for k, v in doc["definitions"].items()]
    L += ["", "## Inputs", ""] + ["- `%s` %s" % (i["path"], i["sha256"][:19]) for i in doc["inputs"]]
    return "\n".join(L) + "\n"


DEFS = {
    "cut attribution": "S1 (compile, visible tests) and S2 (hidden tests) are correctness cuts, never credited to rhobound; S3 microbench; "
                       "S4 rhobound (preview block or saturation); S5 judge (reject); S6 not selected (outranked).",
    "gate-minutes": "serial cluster time of a gate run (timeline gate_started -> gate_ended). B1 = n(model approaches passing S2) x "
                    "mean gate minutes; B3 = the same n x (2 x canary roll + canary window) minutes (reference rows not counted).",
    "B4": "naive additive estimate: microbench delta per call x visits_per_entry, no queueing; block when over the S4 entry threshold.",
    "B5": "the coder's own estimate (s1.estimate_ms) when the funnel records it.",
    "efficiency": "time ratio (base + d_cand)/(base + d_ref) against the best good reference when s3 has base_ms/base_ns, else the "
                  "saving ratio d_cand/d_ref.",
    "judge": "rescue = revised and then reached S6 uncut; veto = cut at S5.",
    "time to production": "funnel started_at -> deploy_ended of a successful deploy.yml run; verified = prodcheck.json present.",
    "truth arm": "observed C - B0 per entry (kshop-load client means, verify/score.py's parsing) against the S4 entry threshold; "
                 "unresolved within the A/A floor; as predicted = (regression) equals (rhobound cut it at S4).",
}


def main(argv):
    kit = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state", default=os.path.join(kit, "state", "bench"))
    ap.add_argument("--tasks", default=os.path.join(kit, "tools1", "bench", "tasks"))
    ap.add_argument("--truth", default=os.path.join(kit, "verify", "data", "truth"))
    ap.add_argument("--aa", default=os.path.join(kit, "verify", "data", "aa"))
    ap.add_argument("--out-md", default=os.path.join(kit, "reports", "demo2-bench.md"))
    ap.add_argument("--out-json", default=os.path.join(kit, "reports", "demo2-bench.json"))
    ap.add_argument("--canary-roll-min", type=float, default=3.0)
    ap.add_argument("--canary-window-min", type=float, default=5.0)
    ap.add_argument("--gate-min-default", type=float, default=20.0)
    ap.add_argument("--usd-per-mtok", type=float)
    ap.add_argument("--now")
    a = ap.parse_args(argv)
    tdirs = sorted(d for d in glob.glob(os.path.join(a.state, "*")) if os.path.isfile(os.path.join(d, "funnel.json")))
    if not tdirs:
        print("bench_score: no STATE/<task>/funnel.json under %s" % a.state, file=sys.stderr)
        return 2
    gate_mins = []
    tasks = [t for t in (score_task(a.state, d, a.tasks, a, gate_mins) for d in tdirs) if t]
    by_id = {t["id"]: t for t in tasks}
    gmean = sum(gate_mins) / len(gate_mins) if gate_mins else None
    gm = gmean if gmean is not None else a.gate_min_default
    ntp = sum(t["n_tests_pass"] for t in tasks)
    toks = sum(t["tokens"] for t in tasks)
    for t in tasks:
        t["b1_minutes"] = r(t["n_tests_pass"] * gm, 1)
        t["b3_minutes"] = r(t["n_tests_pass"] * (2 * a.canary_roll_min + a.canary_window_min), 1)
    doc = {"schema": SCHEMA, "generated_at": a.now or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "params": {"canary_roll_min": a.canary_roll_min, "canary_window_min": a.canary_window_min,
                      "gate_min_default": a.gate_min_default, "gate_min_used": r(gm, 2),
                      "gate_min_measured": gmean is not None, "usd_per_mtok": a.usd_per_mtok},
           "tasks": tasks, "calibration": calibration(a.state), "truth": truth_arm(a.state, a.truth, a.aa, by_id),
           "totals": {"gate_minutes": r(sum(gate_mins), 2), "gates": len(gate_mins), "gate_min_mean": r(gmean, 2),
                      "tests_pass": ntp, "b1_minutes": r(ntp * gm, 1),
                      "b3_minutes": r(ntp * (2 * a.canary_roll_min + a.canary_window_min), 1),
                      "rhobound_cuts": sum(len(t["rhobound_cuts"]) for t in tasks),
                      "correctness_cuts": sum(len(t["correctness_cuts"]) for t in tasks),
                      "tokens": toks, "turns": sum(t["turns"] for t in tasks),
                      "usd": r(toks / 1e6 * a.usd_per_mtok, 2) if a.usd_per_mtok is not None else None,
                      "deployed": sum(1 for t in tasks if t["time_to_production"]["deployed"])},
           "definitions": DEFS, "problems": PROBLEMS, "inputs": INPUTS}
    for p, text in ((a.out_json, json.dumps(doc, indent=1, sort_keys=True) + "\n"), (a.out_md, md(doc))):
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
        with open(p + ".tmp", "w") as f:
            f.write(text)
        os.replace(p + ".tmp", p)
    print("bench_score: %d task(s), %d problem(s): %s, %s" % (len(tasks), len(PROBLEMS), a.out_md, a.out_json), file=sys.stderr)
    return 1 if PROBLEMS else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
