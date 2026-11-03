#!/usr/bin/env python3
"""p3_score.py: experiment 2b part 3 (DECLARE-3): the deploy time of R (rhobound's gate, then one direct rollout), B (a
big-bang bake) and S (a staged bake) for each change, from local copies of what was measured. Run with python3 -I.

  p3_score.py --row NAME:DIR [--row ...] --out JSON [--md MD]

Each DIR holds:
  ci-jobs.json   the CI job of the gated head (gh api .../actions/runs/RUN/jobs): R's A/B, abx, predict and sign steps
  gate.json      the gate's record: verdict, entries[] {entry, band_ms {lo, hi}, change_ms, effect}
  truth.json     bed 1's truthx bracket of every listed service (B, and the truth of R's prediction)
  regress.json   verify/regress.py on that bracket's b0/c windows
  staged/        optional: bed 2's stagedx bracket: truth.json and regress-cK.json (cK against B0) for K = 1..n
Times are whole seconds from the records' UTC stamps. The build is common to all three strategies and left out.
"""
import argparse
import datetime as dt
import json
import os
import sys

THRESHOLD_MS = 4.0


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def secs(a, b):
    return int(round((ts(b) - ts(a)).total_seconds()))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def r_steps(jobs):
    """R's own CI time: the A/B step(s), abx, predict and sign (every step from the first A/B to the signature)."""
    steps = jobs["jobs"][0]["steps"]
    keep, on = [], False
    for s in steps:
        name = s["name"]
        if name.startswith("A/B in the cluster"):
            on = True
        if on and s.get("started_at") and s.get("completed_at"):
            keep.append({"name": name, "seconds": secs(s["started_at"], s["completed_at"]), "conclusion": s.get("conclusion")})
        if on and name.startswith("sign the verdict"):
            break
    return keep


def bracket_phases(t):
    """B's phases from a truthx truth.json: b0 window, rollout, warm-up, c window."""
    tm = t["times"]
    return {
        "b0": secs(tm["b0_start"], tm["b0_end"]),
        "rollout": secs(tm["deploy_started"], tm["deploy_done"]),
        "warm": secs(tm["deploy_done"], tm["c_window_start"]),
        "c": secs(tm["c_window_start"], tm["c_window_end"]),
    }


def staged_phases(t):
    tm, out = t["times"], []
    for st in t["stages"]:
        k = st["k"]
        out.append({"k": k, "service": st["service"],
                    "rollout": secs(tm[f"s{k}_deploy_started"], tm[f"s{k}_deploy_done"]),
                    "warm": secs(tm[f"s{k}_deploy_done"], tm[f"s{k}_c_start"]),
                    "c": secs(tm[f"s{k}_c_start"], tm[f"s{k}_c_end"])})
    return secs(tm["b0_start"], tm["b0_end"]), out


def worst_over(reg):
    """the worst entry's change in ms, and whether it is over the threshold"""
    es = [e for e in reg["entries"] if e.get("change_ms") is not None]
    w = max(es, key=lambda e: e["change_ms"]) if es else None
    return (w["entry"], w["change_ms"]) if w else (None, None)


def compose(gates):
    """a train's R from its images' gates (DECLARE-3, amended 12:01Z): pass iff every gate passes, block if any blocks,
    otherwise inconclusive; per entry, the change and band are the sums of the gates' (additive: no interactions)"""
    vs = [g["verdict"] for _, g in gates]
    verdict = "pass" if all(v == "pass" for v in vs) else ("block" if "block" in vs else "inconclusive")
    ent = {}
    for _, g in gates:
        for e in g.get("entries", []):
            b, c = e.get("band_ms") or {}, e.get("change_ms") or {}
            if b.get("lo") is None:
                continue
            a = ent.setdefault(e["entry"], {"lo": 0.0, "hi": 0.0, "centre": 0.0})
            a["lo"] += b["lo"]
            a["hi"] += b["hi"]
            if c.get("lo") is not None:
                a["centre"] += (c["lo"] + c["hi"]) / 2
    return verdict, vs, ent


def row(name, gates, truth, reg, sdir):
    """gates: [(ci-jobs, gate)], one per image (one for a single-image change); truth, reg: B's bracket and its
    regress.json on bed 1; sdir: the stagedx folder (S measured) or None (S computed)"""
    services = truth.get("services") or [truth.get("service")]
    n = len(services)
    steps = [st for jobs, _ in gates for st in r_steps(jobs)]
    r_ci = sum(st["seconds"] for st in steps)
    bp = bracket_phases(truth)
    verdict, gate_verdicts, pred = compose(gates)
    regressed = bool(reg.get("regressed"))
    went, wms = worst_over(reg)

    # the prediction against the truth
    truth_by = {e["entry"]: e.get("change_ms") for e in reg["entries"]}
    mags = []
    for entry, b in sorted(pred.items()):
        m = truth_by.get(entry)
        if m is None:
            continue
        mags.append({"entry": entry, "truth_ms": round(m, 2), "centre_ms": round(b["centre"], 2),
                     "band": [round(b["lo"], 2), round(b["hi"], 2)], "inside": b["lo"] <= m <= b["hi"]})
    if verdict == "pass":
        vtrue = not regressed
    elif verdict == "block":
        vtrue = regressed
    else:
        vtrue = None

    # B: the big-bang bake; with and without its B0 window
    b_with = bp["b0"] + bp["rollout"] + bp["warm"] + bp["c"]
    b_without = bp["rollout"] + bp["warm"] + bp["c"]
    # R: the gate, then (on a pass) one rollout; an inconclusive verdict falls back to B
    if verdict == "pass":
        r_lead, r_occ, r_note = r_ci + bp["rollout"], bp["rollout"], "deployed on the gate's pass"
    elif verdict == "block":
        r_lead, r_occ, r_note = r_ci, 0, "rejected before production"
    else:
        r_lead, r_occ, r_note = r_ci + b_with, b_with, "inconclusive: the gate, then B"

    # S: measured (stagedx on bed 2) or computed from this change's B phases
    s = {"measured": False}
    if sdir and os.path.isfile(os.path.join(sdir, "truth.json")):
        st = load(os.path.join(sdir, "truth.json"))
        b0, stages = staged_phases(st)
        t_run, stop = b0, None
        for sp in stages:
            t_run += sp["rollout"] + sp["warm"] + sp["c"]
            rk = load(os.path.join(sdir, f"regress-c{sp['k']}.json"))
            sp["regressed"] = bool(rk.get("regressed"))
            sp["worst"] = worst_over(rk)
            if sp["regressed"] and stop is None:
                stop = sp["k"]
                s["lead_s"] = t_run
        if stop is None:
            s["lead_s"] = t_run
        s.update(measured=True, b0_s=b0, stages=stages, stop_stage=stop,
                 culprit=(stages[stop - 1]["service"] if stop else None), order=[x["service"] for x in stages])
        if stop:   # S ran the regressing stage for its warm-up and window before it stopped
            sp = stages[stop - 1]
            s["exposure"] = {"minutes": round((sp["warm"] + sp["c"]) / 60, 1), "worst_entry": sp["worst"][0],
                             "worst_ms": round(sp["worst"][1], 2), "over_ms": round(sp["worst"][1] - THRESHOLD_MS, 2)}
    else:
        stage = bp["rollout"] + bp["warm"] + bp["c"]
        s.update(lead_s=bp["b0"] + n * stage, stop_stage=None, note="computed: B0 + n stages of this change's B phases")
        if regressed:   # the stop is unknown without per-stage windows: give the range over the stage orders
            s.update(lead_s_range=[bp["b0"] + stage, bp["b0"] + n * stage], lead_s=None)
    s["occupancy_s"] = s.get("lead_s")

    exposure = None
    if regressed:   # B ran the regressing change for its warm-up and C window (DECLARE-2's exposure)
        exposure = {"minutes": round((bp["warm"] + bp["c"]) / 60, 1), "worst_entry": went, "worst_ms": round(wms, 2),
                    "over_ms": round(wms - THRESHOLD_MS, 2)}
    return {
        "row": name, "services": services, "n": n, "verdict": verdict, "gate_verdicts": gate_verdicts,
        "verdict_true": vtrue,
        "truth": {"regressed": regressed, "production_ok": reg.get("production_ok"), "worst_entry": went,
                  "worst_ms": None if wms is None else round(wms, 2),
                  "entries": {k: (None if v is None else round(v, 2)) for k, v in truth_by.items()}},
        "magnitude": {"inside": sum(m["inside"] for m in mags), "of": len(mags), "entries": mags},
        "R": {"ci_steps": steps, "ci_s": r_ci, "lead_s": r_lead, "occupancy_s": r_occ, "note": r_note,
              "attribution": "per service A/B" if verdict == "block" else None},
        "B": {"phases_s": bp, "lead_s": b_with, "lead_s_without_b0": b_without, "occupancy_s": b_with,
              "exposure": exposure, "attribution": "none (the services were deployed together)" if regressed else None},
        "S": s,
        "saving_s": None if vtrue is not True else {
            "vs_B": b_with - r_lead, "vs_B_without_b0": b_without - r_lead,
            "vs_S": (s["lead_s"] - r_lead) if s.get("lead_s") is not None else None,
            "occupancy_vs_B": b_with - r_occ},
    }


def mins(x):
    return "" if x is None else f"{x / 60:.1f}"


def markdown(rows):
    out = ["| change | services | verdict | true? | in band | R lead | B lead (no B0) | S lead | R occupancy | B occupancy | saving vs B | vs S |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        sv = r["saving_s"] or {}
        s_lead = mins(r["S"].get("lead_s")) if r["S"].get("lead_s") is not None else \
            "–".join(mins(x) for x in r["S"].get("lead_s_range", []))
        s_lead += "" if r["S"].get("measured") else " (computed)"
        out.append("| {} | {} | {} | {} | {}/{} | {} | {} ({}) | {} | {} s | {} | {} | {} |".format(
            r["row"], ",".join(r["services"]), r["verdict"], {True: "yes", False: "NO", None: "n/a"}[r["verdict_true"]],
            r["magnitude"]["inside"], r["magnitude"]["of"],
            mins(r["R"]["lead_s"]), mins(r["B"]["lead_s"]), mins(r["B"]["lead_s_without_b0"]), s_lead,
            r["R"]["occupancy_s"], mins(r["B"]["occupancy_s"]), mins(sv.get("vs_B")), mins(sv.get("vs_S"))))
    out.append("")
    out.append("Times in minutes unless marked; R occupancy in seconds. Savings only where the verdict came true.")
    return "\n".join(out) + "\n"


def sensitivity(rows, bakes=(5, 15, 30, 60), warm_min=3.0):
    """computed only (DECLARE-3 part 3): R's measured lead time against B and S with longer bakes. B = a B0 window of the
    bake's length + rollout + warm-up + the bake; S = the B0 + n x (rollout + warm-up + bake), with no stop. A longer bake
    detects smaller regressions: these are not equal-power comparisons."""
    out = ["| change | n | R lead | " + " | ".join(f"B / S at {b} min" for b in bakes) + " |",
           "|---|---|---|" + "---|" * len(bakes)]
    for r in rows:
        ro = r["B"]["phases_s"]["rollout"] / 60
        cells = []
        for b in bakes:
            bb = b + ro + warm_min + b
            ss = b + r["n"] * (ro + warm_min + b)
            cells.append(f"{bb:.0f} / {ss:.0f}")
        out.append(f"| {r['row']} | {r['n']} | {r['R']['lead_s'] / 60:.1f} | " + " | ".join(cells) + " |")
    out.append("")
    out.append("Minutes. R is as measured (an inconclusive R includes its fallback bake at this protocol's 5-min windows).")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--row", action="append", default=[], help="NAME:DIR (a single-image change: DIR holds ci-jobs.json, "
                    "gate.json, truth.json, regress.json and optionally staged/)")
    ap.add_argument("--train", action="append", default=[], help="NAME:DIR (a train: DIR holds truth.json, regress.json and "
                    "gates.txt, one SVC:GATE per line; the gates are GATES/GATE/{ci-jobs,gate}.json; S from STAGED/NAME)")
    ap.add_argument("--gates", default="state/p3/gates")
    ap.add_argument("--staged", default="state/p3/staged")
    ap.add_argument("--out", required=True)
    ap.add_argument("--md")
    a = ap.parse_args()
    rows = []
    for spec in a.row:
        name, _, d = spec.partition(":")
        g = [(load(os.path.join(d, "ci-jobs.json")), load(os.path.join(d, "gate.json")))]
        rows.append(row(name, g, load(os.path.join(d, "truth.json")), load(os.path.join(d, "regress.json")),
                        os.path.join(d, "staged")))
    for spec in a.train:
        name, _, d = spec.partition(":")
        with open(os.path.join(d, "gates.txt"), encoding="utf-8") as f:
            names = [ln.strip().partition(":")[2] for ln in f if ln.strip()]
        g = [(load(os.path.join(a.gates, x, "ci-jobs.json")), load(os.path.join(a.gates, x, "gate.json"))) for x in names]
        rows.append(row(name, g, load(os.path.join(d, "truth.json")), load(os.path.join(d, "regress.json")),
                        os.path.join(a.staged, name)))
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump({"schema": "rbd.p3-score/v1", "threshold_ms": THRESHOLD_MS, "rows": rows}, f, indent=1)
        f.write("\n")
    md = markdown(rows) + "\n" + sensitivity(rows)
    if a.md:
        with open(a.md, "w", encoding="utf-8") as f:
            f.write(md)
    sys.stdout.write(md)


if __name__ == "__main__":
    main()
