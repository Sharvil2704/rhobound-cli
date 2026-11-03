#!/usr/bin/env python3
"""p4_score.py: DECLARE-4's checks of the multi-image gate and parallel A/Bs, from local copies (state/p4/<run>/ and the
sequential gates and train brackets of experiment 2b part 3, state/p3/). Run with python3 -I.

  p4_score.py --run v1:p4-m3:m3 --run v2:p4-m3n:m3n [--v3 state/p4/v3] --out JSON [--md MD]

A run is NAME:BRANCH:TRAIN; TRAIN names the part-3 train whose gates (state/p3/trains/TRAIN/gates.txt) and bracket
(state/p3/trains/TRAIN/regress.json) the run is compared with. The checks (DECLARE-4 items 1 to 6):
  1 one PR, three images: three distinct candidate digests, one verdict, every image attested (sign.json images)
  2 the A/Bs at once: ab-all.json parallel 3, three distinct nodes, the A/B windows overlap
  3 CI's A/B step <= 640 s (1.3 x 490 s), against the part-3 gates' summed A/B steps
  4 the verdict: v1 pass; v2 block with utilization_after and mean_change
  5 each service's own-time delta within 3 combined standard errors of its sequential gate's
  6 each entry's predicted band contains the train bracket's change (and V3's, when given); one-model vs additive centre
"""
import argparse
import datetime as dt
import json
import math
import os
import re
import sys

PREV_MAX_AB_S = 490
WANT_VERDICT = {"v1": "pass", "v2": "block", "v1b": "pass", "v4": "pass"}


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def ts(s):   # RFC 3339, any fraction (the A/B windows carry nanoseconds): cut to microseconds
    s = re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00"))
    return dt.datetime.fromisoformat(s)


def step_seconds(jobs, prefix):
    for s in jobs["jobs"][0]["steps"]:
        if s["name"].startswith(prefix) and s.get("started_at") and s.get("completed_at"):
            return int(round((ts(s["completed_at"]) - ts(s["started_at"])).total_seconds()))
    return None


def ab_step_seconds(jobs):
    return step_seconds(jobs, "A/B in the cluster")


def r_total_seconds(jobs):
    """R's own CI time: the first A/B step's start to the signature's end (abx and predict included)"""
    st = jobs["jobs"][0]["steps"]
    a = next((x for x in st if x["name"].startswith("A/B in the cluster")), None)
    b = next((x for x in st if x["name"].startswith("sign the verdict")), None)
    if not a or not b or not a.get("started_at") or not b.get("completed_at"):
        return None
    return int(round((ts(b["completed_at"]) - ts(a["started_at"])).total_seconds()))


def own(rec, svc):
    row = [x for x in rec["services"] if x["service"] == svc][0]["own_ms"]
    return row["delta"], row["se"]


def score_run(name, d, train, p3):
    gate = load(os.path.join(d, "gate.json"))
    pr = gate["verdict"]
    allj = load(os.path.join(d, "ab-all.json")) if os.path.exists(os.path.join(d, "ab-all.json")) else None
    svcs = [x["service"] for x in allj["services"]] if allj else []
    cands = {s: load(os.path.join(d, "candidate-%s.json" % s)) for s in svcs}
    digs = {s: c["digest"] for s, c in cands.items()}
    sign = load(os.path.join(d, "sign.json")) if os.path.exists(os.path.join(d, "sign.json")) else {}
    out = {"run": name, "train": train, "services": svcs, "digests": digs, "verdict": pr, "checks": {}}
    c = out["checks"]
    # 1: one image per service (each of these services is its own image) in one PR, one verdict, every image attested
    c["1_three_images"] = {"distinct_digests": len(set(digs.values())), "attested": sorted(sign.get("images") or []),
                           "ok": len(set(digs.values())) == len(svcs) and sorted(sign.get("images") or []) == sorted(set(digs.values()))}
    # 2: at once, on three nodes, overlapping A/B windows
    wins = {}
    for s in svcs:
        ab = load(os.path.join(d, "ab-%s.ab.json" % s))
        w = ab.get("window") or {}
        if w.get("start") and w.get("end"):
            wins[s] = (ts(w["start"]), ts(w["end"]))
    overlap = None
    if len(wins) == len(svcs) and wins:
        overlap = (min(e for _, e in wins.values()) - max(b for b, _ in wins.values())).total_seconds()
    nodes = [x["node"] for x in allj["services"]] if allj else []
    c["2_parallel"] = {"parallel": allj and allj["parallel"], "nodes": nodes,
                       "windows": {s: [b.isoformat(), e.isoformat()] for s, (b, e) in wins.items()},
                       "common_window_s": overlap,
                       "ok": bool(allj and allj["parallel"] == len(svcs) and len(set(nodes)) == len(svcs) and overlap is not None and overlap > 0)}
    # 3: CI's A/B step against the sequential gates' summed A/B steps
    jobs = load(os.path.join(d, "ci-jobs.json"))
    step = ab_step_seconds(jobs)
    gates = [ln.strip().split(":") for ln in open(os.path.join(p3, "trains", train, "gates.txt")) if ln.strip()]
    seq = sum(ab_step_seconds(load(os.path.join(p3, "gates", g, "ci-jobs.json"))) for _, g in gates)
    c["3_time"] = {"ab_step_s": step, "limit_s": round(1.3 * PREV_MAX_AB_S), "sequential_gates_ab_s": seq,
                   "ab_all_s": allj and allj["seconds"], "abx_step_s": step_seconds(jobs, "a longer A/B"),
                   "r_total_s": r_total_seconds(jobs), "build_s": step_seconds(jobs, "build the candidate"),
                   "ok": step is not None and step <= 1.3 * PREV_MAX_AB_S}
    # 4: the verdict
    rules = [r.get("rule") for r in gate.get("rules", []) if r.get("effect") in ("block", "inconclusive")]
    ok4 = pr == WANT_VERDICT.get(name)
    if name == "v2":
        ok4 = ok4 and "utilization_after" in rules and "mean_change" in rules
    c["4_verdict"] = {"verdict": pr, "deciding": rules, "want": WANT_VERDICT.get(name), "ok": ok4}
    # 5: parallel vs sequential own-time deltas
    rows, ok5 = [], True
    for s, g in gates:
        dp, sp = own(load(os.path.join(d, "ab-%s.ab-record.json" % s)), s)
        dq, sq = own(load(os.path.join(p3, "gates", g, "ab-record.json")), s)
        lim = 3 * math.hypot(sp, sq)
        rows.append({"service": s, "gate": g, "parallel": [round(dp, 3), round(sp, 3)], "sequential": [round(dq, 3), round(sq, 3)],
                     "diff": round(dp - dq, 3), "limit": round(lim, 3), "z": round((dp - dq) / math.hypot(sp, sq), 2),
                     "ok": abs(dp - dq) <= lim})
        ok5 = ok5 and abs(dp - dq) <= lim
    c["5_parallel_agrees"] = {"services": rows, "ok": ok5}
    # 6: the one prediction's bands against the train bracket (and V3); one-model centre vs the additive composition
    truth = {e["entry"]: e.get("change_ms") for e in load(os.path.join(p3, "trains", train, "regress.json"))["entries"]}
    sc = load(os.path.join(p3, "score.json"))
    add = {m["entry"]: m["centre_ms"] for r in sc["rows"] if r["row"] == train for m in r["magnitude"]["entries"]}
    ents, ok6 = [], True
    for e in gate["entries"]:
        t = truth.get(e["entry"])
        if t is None:
            continue
        b, ch = e["band_ms"], e["change_ms"]
        mid = (ch["lo"] + ch["hi"]) / 2
        inside = b["lo"] <= t <= b["hi"]
        ok6 = ok6 and inside
        ents.append({"entry": e["entry"], "truth": round(t, 2), "band": [round(b["lo"], 2), round(b["hi"], 2)],
                     "centre": round(mid, 2), "additive_centre": add.get(e["entry"]), "inside": inside,
                     "closer_than_additive": None if add.get(e["entry"]) is None else abs(mid - t) < abs(add[e["entry"]] - t)})
    c["6_prediction"] = {"entries": ents, "ok": ok6}
    out["ok"] = all(v["ok"] for v in c.values())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--run", action="append", required=True)
    ap.add_argument("--p4", default="state/p4")
    ap.add_argument("--p3", default="state/p3")
    ap.add_argument("--v3")
    ap.add_argument("--out", required=True)
    ap.add_argument("--md")
    a = ap.parse_args()
    res = []
    for spec in a.run:
        name, branch, train = spec.split(":")
        res.append(score_run(name, os.path.join(a.p4, name), train, a.p3))
    v3 = None
    if a.v3 and os.path.exists(os.path.join(a.v3, "regress.json")):
        r = load(os.path.join(a.v3, "regress.json"))
        v1 = [x for x in res if x["run"] == "v1"]
        g = load(os.path.join(a.p4, "v1", "gate.json"))
        tv = {e["entry"]: e.get("change_ms") for e in r["entries"]}
        v3 = {"production_ok": r.get("production_ok"), "entries": [
            {"entry": e["entry"], "truth": round(tv[e["entry"]], 2), "band": [round(e["band_ms"]["lo"], 2), round(e["band_ms"]["hi"], 2)],
             "inside": e["band_ms"]["lo"] <= tv[e["entry"]] <= e["band_ms"]["hi"]} for e in g["entries"] if tv.get(e["entry"]) is not None]}
        if v1:
            v1[0]["v3_bracket"] = v3
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump({"schema": "rbd.p4-score/v1", "runs": res}, f, indent=1)
        f.write("\n")
    lines = []
    for r in res:
        lines.append("## %s (%s): %s" % (r["run"], ", ".join(r["services"]), "ALL CHECKS PASS" if r["ok"] else "a check FAILED"))
        for k, v in r["checks"].items():
            lines.append("- %s: %s %s" % (k, "ok" if v["ok"] else "FAIL", json.dumps({x: y for x, y in v.items() if x != "ok"})[:600]))
        if r.get("v3_bracket"):
            lines.append("- v3 bracket of V1's own images: %s" % json.dumps(r["v3_bracket"])[:600])
        lines.append("")
    md = "\n".join(lines)
    if a.md:
        open(a.md, "w", encoding="utf-8").write(md)
    sys.stdout.write(md)


if __name__ == "__main__":
    main()
