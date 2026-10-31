#!/usr/bin/env python3
"""verify/score.py: the orchestrator's independent score of rhobound gate verdicts against measured truth (SPEC 7).

Reads files only. Imports no rhobound code and runs no command. Stdlib only (python3 -I).

usage:
  python3 -I score.py --out DIR [--aa LOAD ...] --change NAME B0_LOAD C_LOAD PREDICTION GATE_DIR [TRUTH_JSON] [--change ...]
  python3 -I score.py --out DIR --bundle BUNDLE
    BUNDLE/aa/*.load.json                       A/A production windows (aa.sh, collect.sh aa)
    BUNDLE/truth/NAME/{b0.load.json,c.load.json,truth.json}            truth.sh
    BUNDLE/truth/NAME/{prediction.json,gate/gate.json,gate/verdict.txt} collect.sh run
exit: 0 report written, no failure listed; 1 report written, failures listed (wrong verdicts, input problems, band
      misses); 2 cannot run (arguments, an unreadable A/A window).
writes: DIR/score.json (rbd.verify-score/v1), DIR/report.md

Fields read, nothing else:
  load.json   kshop-load's job log: JSON lines {url, ok, errors, mean_ms} (mean_ms is over ok requests only), the line
              'kshop-load: N requests over S s (R rps), seed K' and the line 'kshop-load: done in S s'.
  prediction  rhobound-cli.report/v2: version, fit_digest, items[].service, entries[].{name, before_ms, change_ms.lo/hi,
              band_ms.lo/hi}; a refusal {"error": {"code"}} is accepted (the gate turns it into inconclusive).
  gate.json   rhobound.gate/v1: schema, verdict, exit_code, advisory, digests.fit,
              policy.{max_entry_mean_change_pct, max_entry_mean_change_ms}, rules[].{number, rule, effect, entry, value,
              threshold}.
  verdict.txt the verdict word.
  truth.json  rbd.truth/v1 (truth.sh): status, service, base_digest, cand_digest, keep, warnings (listed as problems).
              --bundle skips a bracket whose status is not ok/ok-kept (a failed attempt; re-run under a new name).

Definitions:
  entry mean   storefront = /browse mean_ms; checkout = /buy/card and /buy/wallet mean_ms weighted by ok.
  observed     C - B0 of the entry mean, ms and % of B0.
  A/A floor    per entry, p90 (nearest rank) of |mean_i - mean_j| over all pairs i<j of A/A windows; n = pairs.
  T            the gate's threshold: min(policy ms, policy pct/100 * prediction before_ms) (policy.go Threshold), from
               gate.json's effective policy; checked against rule 10's threshold for the entry that row names.
  truth class  unresolved if |observed - T| < floor; else regression if observed > T; else clean. A change takes its
               worst entry: regression > unknown > unresolved > clean.
  score        pass+clean right-pass, pass+regression WRONG-PASS, block+regression right-block, block+clean wrong-block,
               inconclusive reported as such, unresolved truth not scored.
"""
import argparse
import datetime
import glob
import hashlib
import json
import math
import os
import re
import sys
import urllib.parse

SCHEMA = "rbd.verify-score/v1"
ENTRIES = {"storefront": ("/browse",), "checkout": ("/buy/card", "/buy/wallet")}
EXIT_OF = {"pass": 0, "block": 1, "inconclusive": 3}
ERR_PCT_MAX = 1.0
RE_START = re.compile(r"(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)\S* kshop-load: (\d+) requests over ([\d.]+) s "
                      r"\(([\d.]+) rps\), seed (-?\d+)")
RE_DONE = re.compile(r"kshop-load: done in ([\d.]+) s")
TRUTH_RANK = {"regression": 3, "unknown": 2, "unresolved": 1, "clean": 0}


class Unusable(Exception):
    pass


def sha256_file(path):
    with open(path, "rb") as f:
        return "sha256:" + hashlib.sha256(f.read()).hexdigest()


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Unusable(f"{path}: {e}") from None


def num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) else None


def rng(x):
    if not isinstance(x, dict) or num(x.get("lo")) is None or num(x.get("hi")) is None:
        return None
    return {"lo": float(x["lo"]), "hi": float(x["hi"])}


def parse_load(path):
    """kshop-load's log -> {urls: {path: row}, start, requests, seconds, seed, done, problems}."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise Unusable(f"{path}: {e}") from None
    w = {"file": path, "urls": {}, "start": None, "requests": None, "seconds": None, "seed": None, "done": False,
         "problems": []}
    for ln in lines:
        m = RE_START.search(ln)
        if m:
            t = datetime.datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S")
            w["start"] = t.strftime("%Y-%m-%dT%H:%M:%SZ")
            w["requests"], w["seconds"], w["seed"] = int(m.group(2)), float(m.group(3)), int(m.group(5))
            continue
        if RE_DONE.search(ln):
            w["done"] = True
            continue
        i = ln.find("{")
        if i < 0 or not ln.rstrip().endswith("}"):
            continue
        try:
            row = json.loads(ln[i:])
        except ValueError:
            continue
        if not isinstance(row, dict) or "url" not in row:
            continue
        p = urllib.parse.urlparse(str(row["url"])).path
        ok, err, mean = row.get("ok"), row.get("errors"), num(row.get("mean_ms"))
        if not isinstance(ok, int) or not isinstance(err, int) or mean is None:
            w["problems"].append(f"{p}: ok/errors/mean_ms missing or not numbers")
            continue
        if p in w["urls"]:
            w["problems"].append(f"{p}: two result lines")
        w["urls"][p] = {"ok": ok, "errors": err, "mean_ms": float(mean)}
    if not w["done"]:
        w["problems"].append("no 'kshop-load: done' line (window incomplete?)")
    if w["requests"] is None:
        w["problems"].append("no 'kshop-load: N requests over' line")
    elif w["urls"]:
        total = sum(r["ok"] + r["errors"] for r in w["urls"].values())
        if total != w["requests"]:
            w["problems"].append(f"result lines count {total} requests, the start line {w['requests']}")
    return w


def entry_stats(w, entry):
    rows = []
    for p in ENTRIES[entry]:
        r = w["urls"].get(p)
        if r is None:
            return None, f"{entry}: no {p} result line in {w['file']}"
        rows.append(r)
    ok = sum(r["ok"] for r in rows)
    err = sum(r["errors"] for r in rows)
    if ok == 0:
        return None, f"{entry}: 0 ok requests in {w['file']}"
    mean = sum(r["mean_ms"] * r["ok"] for r in rows) / ok
    return {"mean_ms": mean, "ok": ok, "errors": err, "err_pct": 100.0 * err / (ok + err)}, None


def p90(xs):
    s = sorted(xs)
    return s[max(1, math.ceil(0.9 * len(s))) - 1]


def aa_floor(windows):
    """windows: [(name, parsed)] -> per entry floor."""
    out = {"windows": [], "entries": {}, "problems": []}
    for name, w in windows:
        out["windows"].append({"name": name, "start": w["start"], "seed": w["seed"], "file": w["file"]})
        for pr in w["problems"]:
            out["problems"].append(f"A/A {name}: {pr}")
    for entry in ENTRIES:
        means = []
        for name, w in windows:
            st, why = entry_stats(w, entry)
            if st is None:
                out["problems"].append(f"A/A {name}: {why}")
                continue
            if st["err_pct"] > ERR_PCT_MAX:
                out["problems"].append(f"A/A {name}: {entry} errors {st['err_pct']:.2f}%")
            means.append((name, st["mean_ms"]))
        pairs = [{"a": means[i][0], "b": means[j][0], "abs_ms": abs(means[i][1] - means[j][1])}
                 for i in range(len(means)) for j in range(i + 1, len(means))]
        e = {"n": len(pairs), "windows": len(means), "pairs": pairs, "floor_ms": None, "floor_pct": None,
             "mean_ms": None}
        if pairs:
            e["floor_ms"] = p90([p["abs_ms"] for p in pairs])
            e["mean_ms"] = sum(m for _, m in means) / len(means)
            e["floor_pct"] = 100.0 * e["floor_ms"] / e["mean_ms"]
        out["entries"][entry] = e
    if not any(e["n"] for e in out["entries"].values()):
        out["problems"].append("no A/A pair: truth classes use floor 0 (window noise unprotected)")
    elif any(e["n"] < 2 for e in out["entries"].values()):
        out["problems"].append("fewer than 2 A/A pairs: the floor is a single difference")
    return out


def threshold(policy, before_ms):
    """policy.go Threshold: the smaller of the ms limit and pct of before; (ms, key)."""
    t, key = None, None
    ms = num(policy.get("max_entry_mean_change_ms")) if isinstance(policy, dict) else None
    pct = num(policy.get("max_entry_mean_change_pct")) if isinstance(policy, dict) else None
    if ms is not None:
        t, key = float(ms), "max_entry_mean_change_ms"
    if pct is not None and before_ms is not None:
        v = pct / 100.0 * before_ms
        if t is None or v < t:
            t, key = v, "max_entry_mean_change_pct"
    return t, key


def truth_class(obs, t, floor):
    if obs is None or t is None:
        return "unknown"
    if abs(obs - t) < floor:
        return "unresolved"
    return "regression" if obs > t else "clean"


def score_of(verdict, truth):
    if verdict == "inconclusive":
        return "inconclusive"
    if verdict not in ("pass", "block") or truth == "unknown":
        return "unscored"
    if truth == "unresolved":
        return "unresolved"
    return {("pass", "clean"): "right-pass", ("pass", "regression"): "wrong-pass",
            ("block", "regression"): "right-block", ("block", "clean"): "wrong-block"}[(verdict, truth)]


def read_gate(gate_dir, ch):
    gj = os.path.join(gate_dir, "gate.json")
    vt = os.path.join(gate_dir, "verdict.txt")
    g, verdict = None, None
    if os.path.isfile(gj):
        ch["inputs"]["gate.json"] = sha256_file(gj)
        try:
            g = read_json(gj)
        except Unusable as e:
            ch["problems"].append(str(e))
        if g is not None and g.get("schema") != "rhobound.gate/v1":
            ch["problems"].append(f"gate.json schema {g.get('schema')!r}, not rhobound.gate/v1")
    else:
        ch["problems"].append(f"no {gj}")
    if os.path.isfile(vt):
        ch["inputs"]["verdict.txt"] = sha256_file(vt)
        with open(vt, encoding="utf-8", errors="replace") as f:
            words = f.read().split()
        verdict = words[0] if words else None
        if verdict not in EXIT_OF:
            ch["problems"].append(f"verdict.txt says {verdict!r}")
            verdict = None
    else:
        ch["problems"].append(f"no {vt}")
    if g is not None:
        gv = g.get("verdict")
        if verdict is None and gv in EXIT_OF:
            verdict = gv
        elif gv != verdict:
            ch["problems"].append(f"verdict.txt {verdict!r} and gate.json {gv!r} differ")
        if verdict in EXIT_OF and g.get("exit_code") != EXIT_OF[verdict]:
            ch["problems"].append(f"gate.json exit_code {g.get('exit_code')!r} does not match {verdict}")
    return g, verdict


def score_change(name, b0p, cp, predp, gate_dir, truthp, aa):
    ch = {"name": name, "service": None, "verdict": None, "advisory": None, "rules_fired": [], "decided_by": None,
          "truth_class": "unknown", "score": "unscored", "entries": [], "problems": [], "truth": None, "inputs": {}}
    wins = {}
    for k, p in (("b0", b0p), ("c", cp)):
        try:
            wins[k] = parse_load(p)
            ch["inputs"][f"{k}.load.json"] = sha256_file(p)
            for pr in wins[k]["problems"]:
                ch["problems"].append(f"{k} window: {pr}")
        except Unusable as e:
            ch["problems"].append(str(e))
    ch["windows"] = {k: {"start": w["start"], "seed": w["seed"], "requests": w["requests"]} for k, w in wins.items()}
    if wins.get("b0") and wins.get("c") and wins["b0"]["seed"] is not None and wins["b0"]["seed"] == wins["c"]["seed"]:
        ch["problems"].append("b0 and c windows have the same seed (same file twice?)")
    pred = None
    if predp and os.path.isfile(predp):
        ch["inputs"]["prediction.json"] = sha256_file(predp)
        try:
            pred = read_json(predp)
        except Unusable as e:
            ch["problems"].append(str(e))
    else:
        ch["problems"].append(f"no prediction.json ({predp})")
    refused = isinstance(pred, dict) and "error" in pred and "entries" not in pred
    if refused:
        err = pred.get("error")
        ch["refusal"] = err.get("code") if isinstance(err, dict) else str(err)
    elif isinstance(pred, dict) and pred.get("version") != "rhobound-cli.report/v2":
        ch["problems"].append(f"prediction version {pred.get('version')!r}, not rhobound-cli.report/v2")
    g, verdict = read_gate(gate_dir, ch) if gate_dir else (None, None)
    if not gate_dir:
        ch["problems"].append("no gate dir")
    ch["verdict"] = verdict
    policy = g.get("policy") if isinstance(g, dict) else None
    if isinstance(g, dict):
        ch["advisory"] = g.get("advisory")
        gfit = (g.get("digests") or {}).get("fit")
        pfit = pred.get("fit_digest") if isinstance(pred, dict) else None
        if gfit and pfit and gfit != pfit:
            ch["problems"].append(f"gate.json fit {gfit} and prediction fit {pfit} differ (wrong pair of files?)")
        for r in g.get("rules") or []:
            if isinstance(r, dict) and r.get("effect") in ("block", "inconclusive"):
                ch["rules_fired"].append({k: r.get(k) for k in ("number", "rule", "effect", "entry", "value",
                                                                 "threshold")})
        if verdict in ("block", "inconclusive"):
            hit = [r for r in ch["rules_fired"] if r["effect"] == verdict]
            ch["decided_by"] = hit[0] if hit else None
        else:
            r10 = [r for r in g.get("rules") or [] if isinstance(r, dict) and r.get("number") == "10"]
            ch["decided_by"] = {k: r10[0].get(k) for k in ("number", "rule", "effect", "entry", "value",
                                                           "threshold")} if r10 else None
    if truthp:
        try:
            t = read_json(truthp)
            ch["inputs"]["truth.json"] = sha256_file(truthp)
            ch["truth"] = {k: t.get(k) for k in ("status", "service", "base_digest", "cand_digest", "keep")}
            ch["service"] = t.get("service")
            if t.get("status") not in ("ok", "ok-kept"):
                ch["problems"].append(f"truth.json status {t.get('status')!r} (bracket did not complete)")
            for w in t.get("warnings") or []:
                ch["problems"].append(f"truth bracket: {w}")
        except Unusable as e:
            ch["problems"].append(str(e))
    if isinstance(pred, dict) and not refused:
        svcs = sorted({i.get("service") for i in pred.get("items") or [] if isinstance(i, dict)})
        if ch["service"] and svcs and ch["service"] not in svcs:
            ch["problems"].append(f"truth bracket changed {ch['service']}, the prediction's items change {svcs}")
        ch["service"] = ch["service"] or (svcs[0] if len(svcs) == 1 else None)
    pentries = {}
    if isinstance(pred, dict):
        for e in pred.get("entries") or []:
            if isinstance(e, dict) and e.get("name"):
                pentries[e["name"]] = e
    r10 = None
    if isinstance(g, dict):
        r10 = next((r for r in g.get("rules") or [] if isinstance(r, dict) and r.get("number") == "10"), None)
    for entry in ENTRIES:
        row = {"name": entry, "b0_ms": None, "c_ms": None, "observed_ms": None, "observed_pct": None,
               "b0_ok": None, "c_ok": None, "b0_err_pct": None, "c_err_pct": None, "floor_ms": None, "floor_n": 0,
               "before_ms": None, "threshold_ms": None, "threshold_key": None, "threshold_source": None,
               "predicted_change_ms": None, "band_ms": None, "covered": None, "covered_within_floor": None,
               "in_predicted_range": None, "band_vs_t": None, "truth_class": "unknown"}
        st = {}
        for k in ("b0", "c"):
            if k not in wins:
                continue
            s, why = entry_stats(wins[k], entry)
            if s is None:
                ch["problems"].append(why)
                continue
            st[k] = s
            row[f"{k}_ms"], row[f"{k}_ok"], row[f"{k}_err_pct"] = s["mean_ms"], s["ok"], s["err_pct"]
            if s["err_pct"] > ERR_PCT_MAX:
                ch["problems"].append(f"{k} window: {entry} errors {s['err_pct']:.2f}% (means are over ok only)")
        if "b0" in st and "c" in st:
            row["observed_ms"] = st["c"]["mean_ms"] - st["b0"]["mean_ms"]
            row["observed_pct"] = 100.0 * row["observed_ms"] / st["b0"]["mean_ms"]
        a = aa["entries"].get(entry) or {}
        floor = a.get("floor_ms")
        row["floor_ms"], row["floor_n"] = floor, a.get("n", 0)
        floor = floor or 0.0
        pe = pentries.get(entry)
        if pe is not None:
            row["before_ms"] = num(pe.get("before_ms"))
            row["predicted_change_ms"] = rng(pe.get("change_ms"))
            row["band_ms"] = rng(pe.get("band_ms"))
        elif not refused and isinstance(pred, dict):
            ch["problems"].append(f"prediction has no entry {entry}")
        if row["before_ms"] is not None and policy is not None:
            row["threshold_ms"], row["threshold_key"] = threshold(policy, row["before_ms"])
            row["threshold_source"] = "gate policy x prediction before_ms"
        elif policy is not None and "b0" in st:
            row["threshold_ms"], row["threshold_key"] = threshold(policy, st["b0"]["mean_ms"])
            row["threshold_source"] = "gate policy x observed B0 (no prediction entry)"
        if (row["threshold_source"] == "gate policy x prediction before_ms" and isinstance(r10, dict)
                and r10.get("entry") == entry and num(r10.get("threshold")) is not None):
            rt = float(r10["threshold"])
            if row["threshold_ms"] is None or abs(rt - row["threshold_ms"]) > 1e-6 * max(1.0, rt):
                ch["problems"].append(f"{entry}: T {row['threshold_ms']} differs from gate rule 10's {rt}")
        obs, t, band = row["observed_ms"], row["threshold_ms"], row["band_ms"]
        if obs is not None and band is not None:
            row["covered"] = band["lo"] <= obs <= band["hi"]
            row["covered_within_floor"] = band["lo"] - floor <= obs <= band["hi"] + floor
        if obs is not None and row["predicted_change_ms"] is not None:
            pr = row["predicted_change_ms"]
            row["in_predicted_range"] = pr["lo"] <= obs <= pr["hi"]
        if band is not None and t is not None:
            row["band_vs_t"] = "pass" if band["hi"] <= t else ("block" if band["lo"] > t else "inconclusive")
        row["truth_class"] = truth_class(obs, t, floor)
        ch["entries"].append(row)
    ch["truth_class"] = max((r["truth_class"] for r in ch["entries"]), key=lambda c: TRUTH_RANK[c])
    ch["score"] = score_of(verdict, ch["truth_class"])
    return ch


def failures_of(changes, aa):
    """Ranked: wrong pass, wrong block, input problems, band misses."""
    out = []
    for ch in changes:
        ent = ", ".join(f"{e['name']} {fmt(e['observed_ms'], True)} ms vs T {fmt(e['threshold_ms'])}"
                        for e in ch["entries"])
        if ch["score"] == "wrong-pass":
            out.append({"rank": 0, "kind": "wrong-pass", "change": ch["name"],
                        "what": f"gate passed a regression ({ent}; truth {ch['truth_class']})"})
        if ch["score"] == "wrong-block":
            out.append({"rank": 1, "kind": "wrong-block", "change": ch["name"],
                        "what": f"gate blocked a clean change ({ent}; decided by {rule_txt(ch['decided_by'])})"})
        for p in ch["problems"]:
            out.append({"rank": 2, "kind": "input", "change": ch["name"], "what": p})
        for e in ch["entries"]:
            if e["covered"] is False:
                b = e["band_ms"]
                near = " (inside the band widened by the A/A floor)" if e["covered_within_floor"] else ""
                out.append({"rank": 3, "kind": "band-miss", "change": ch["name"],
                            "what": f"{e['name']}: observed {fmt(e['observed_ms'], True)} ms outside band "
                                    f"{fmt(b['lo'], True)}..{fmt(b['hi'], True)} ms{near}"})
    for p in aa["problems"]:
        out.append({"rank": 2, "kind": "input", "change": None, "what": p})
    out.sort(key=lambda f: f["rank"])
    return out


def fmt(x, sign=False, nd=2):
    if x is None:
        return "-"
    return f"{x:+.{nd}f}" if sign else f"{x:.{nd}f}"


def rule_txt(r):
    if not r:
        return "-"
    s = f"rule {r.get('number')} {r.get('rule')}"
    if r.get("entry"):
        s += f" at {r['entry']}"
    if num(r.get("value")) is not None and num(r.get("threshold")) is not None:
        s += f" ({r['value']:.3f} vs {r['threshold']:.3f})"
    return s


def report_md(doc):
    L = []
    c = doc["counts"]
    L.append("# Independent verification of the gate's verdicts")
    L.append("")
    L.append(f"Generated {doc['generated_at']} by `verify/score.py` from files only (kshop-load's own client-side "
             "means, the run's prediction.json and gate/). No rhobound code was run or imported.")
    L.append("")
    L.append(f"**{len(doc['changes'])} changes:** " + ", ".join(f"{k} {v}" for k, v in c.items()) + ".")
    L.append("")
    L.append("## Failures (worst first)")
    L.append("")
    if not doc["failures"]:
        L.append("None.")
    for i, f in enumerate(doc["failures"], 1):
        who = f"`{f['change']}` " if f["change"] else ""
        L.append(f"{i}. **{f['kind']}** {who}{f['what']}")
    L.append("")
    ns = [ch for ch in doc["changes"] if ch["score"] in ("inconclusive", "unresolved", "unscored")]
    L.append("## Not scored")
    L.append("")
    if not ns and not doc.get("skipped"):
        L.append("None.")
    for sk in doc.get("skipped") or []:
        L.append(f"- `{sk['name']}`: bracket status {sk['status']}, skipped (a failed attempt; see its truth.json)")
    for ch in ns:
        why = {"inconclusive": f"the gate said inconclusive ({rule_txt(ch['decided_by'])}); measured truth: "
                               f"{ch['truth_class']}",
               "unresolved": f"verdict {ch['verdict']}, but the observed change is within the A/A floor of T",
               "unscored": f"verdict {ch['verdict']}, truth {ch['truth_class']}: inputs missing (see failures)"}
        L.append(f"- `{ch['name']}`: {why[ch['score']]}")
    L.append("")
    L.append("## Per change")
    for ch in doc["changes"]:
        L.append("")
        adv = " (advisory)" if ch["advisory"] else ""
        L.append(f"### {ch['name']} ({ch['service'] or '?'}): verdict {ch['verdict'] or '-'}{adv}, "
                 f"truth {ch['truth_class']}, score **{ch['score']}**")
        L.append("")
        L.append(f"Decided by {rule_txt(ch['decided_by'])}.")
        if ch.get("refusal"):
            L.append(f"The prediction was a refusal: `{ch['refusal']}`.")
        if ch["truth"]:
            t = ch["truth"]
            L.append(f"Truth bracket: status {t.get('status')}, base `{t.get('base_digest')}`, candidate "
                     f"`{t.get('cand_digest')}`, kept {t.get('keep')}.")
        L.append("")
        L.append("| entry | B0 ms | C ms | observed ms | observed % | A/A floor ms (n) | T ms | predicted ms | band ms "
                 "| covered | truth |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for e in ch["entries"]:
            pr, b = e["predicted_change_ms"], e["band_ms"]
            prs = f"{fmt(pr['lo'], True)}..{fmt(pr['hi'], True)}" if pr else "-"
            bs = f"{fmt(b['lo'], True)}..{fmt(b['hi'], True)}" if b else "-"
            cov = "-" if e["covered"] is None else ("yes" if e["covered"] else
                                                    ("near" if e["covered_within_floor"] else "NO"))
            L.append(f"| {e['name']} | {fmt(e['b0_ms'])} | {fmt(e['c_ms'])} | {fmt(e['observed_ms'], True)} | "
                     f"{fmt(e['observed_pct'], True, 1)} | {fmt(e['floor_ms'])} ({e['floor_n']}) | "
                     f"{fmt(e['threshold_ms'])} | {prs} | {bs} | {cov} | {e['truth_class']} |")
    L.append("")
    L.append("## A/A floor")
    L.append("")
    aa = doc["aa"]
    L.append(f"{len(aa['windows'])} production windows at baseline: " +
             (", ".join(f"{w['name']} ({w['start'] or '?'})" for w in aa["windows"]) or "none") + ".")
    L.append("")
    L.append("| entry | floor ms (p90 of pairs) | floor % | pairs n | pair differences ms |")
    L.append("|---|---|---|---|---|")
    for entry, e in aa["entries"].items():
        ps = ", ".join(fmt(p["abs_ms"]) for p in e["pairs"]) or "-"
        L.append(f"| {entry} | {fmt(e['floor_ms'])} | {fmt(e['floor_pct'], False, 1)} | {e['n']} | {ps} |")
    L.append("")
    L.append("## What this cannot show")
    L.append("")
    n = len(doc["changes"])
    L.append(f"- One 600-s window per state (B0, C): a single difference per entry, judged against an A/A floor of "
             f"{min((e['n'] for e in aa['entries'].values()), default=0)} pair(s) (pairs share windows, so they are "
             "not independent; p90 of few values is close to their maximum).")
    L.append(f"- n = {n} change(s): no rate of wrong verdicts can be estimated from so few; this is a spot check.")
    L.append("- The observed means are the load generator's (client side, network included); T is 5% of the model's "
             "server-side mean. C - B0 cancels a constant network time, but the two are not the same quantity.")
    L.append("- Mean latency only (as the product). Nothing here speaks for tails, bursts or other load levels.")
    L.append("- B0 and C are minutes apart; a drift of the cluster between them reads as the change's effect.")
    L.append("")
    return "\n".join(L)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def from_bundle(bdir):
    aa = sorted(glob.glob(os.path.join(bdir, "aa", "*.load.json")))
    changes, skipped = [], []
    for d in sorted(glob.glob(os.path.join(bdir, "truth", "*", ""))):
        name = os.path.basename(os.path.normpath(d))
        t = os.path.join(d, "truth.json")
        if os.path.isfile(t):
            try:
                st = read_json(t).get("status")
            except (Unusable, AttributeError):
                st = "unreadable"
            if st not in ("ok", "ok-kept"):
                skipped.append({"name": name, "status": st})
                continue
        changes.append([name, os.path.join(d, "b0.load.json"), os.path.join(d, "c.load.json"),
                        os.path.join(d, "prediction.json"), os.path.join(d, "gate"),
                        t if os.path.isfile(t) else None])
    return aa, changes, skipped


def main(argv):
    ap = argparse.ArgumentParser(description="score gate verdicts against measured truth (files only)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--aa", nargs="+", default=[], metavar="LOAD")
    ap.add_argument("--change", nargs="+", action="append", default=[],
                    metavar="ARG", help="NAME B0_LOAD C_LOAD PREDICTION GATE_DIR [TRUTH_JSON]")
    ap.add_argument("--bundle")
    ap.add_argument("--now", help="generated_at (RFC 3339), for reproducible output")
    a = ap.parse_args(argv)
    aa_files, changes, skipped = list(a.aa), [], []
    for c in a.change:
        if len(c) not in (5, 6):
            ap.error(f"--change takes NAME B0_LOAD C_LOAD PREDICTION GATE_DIR [TRUTH_JSON], got {c}")
        changes.append(c if len(c) == 6 else c + [None])
    if a.bundle:
        if not os.path.isdir(a.bundle):
            ap.error(f"--bundle {a.bundle}: not a directory")
        ba, bc, skipped = from_bundle(a.bundle)
        aa_files += ba
        changes += bc
    if not changes:
        ap.error("no change to score (--change or --bundle)")
    names = [c[0] for c in changes]
    if len(set(names)) != len(names):
        ap.error(f"change names repeat: {names}")
    windows = []
    for p in aa_files:
        try:
            windows.append((os.path.basename(p).removesuffix(".load.json").removesuffix(".json"), parse_load(p)))
        except Unusable as e:
            print(f"score.py: A/A window unreadable: {e}", file=sys.stderr)
            return 2
    windows.sort(key=lambda nw: (nw[1]["start"] or "", nw[0]))
    aa = aa_floor(windows)
    scored = [score_change(c[0], c[1], c[2], c[3], c[4], c[5], aa) for c in changes]
    counts = {}
    for k in ("wrong-pass", "wrong-block", "right-pass", "right-block", "inconclusive", "unresolved", "unscored"):
        counts[k] = sum(1 for ch in scored if ch["score"] == k)
    doc = {"schema": SCHEMA,
           "generated_at": a.now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "counts": counts, "failures": [], "changes": scored, "skipped": skipped,
           "aa": {**aa, "inputs": {nw[0]: sha256_file(nw[1]["file"]) for nw in windows}}}
    doc["failures"] = failures_of(scored, aa)
    os.makedirs(a.out, exist_ok=True)
    write_atomic(os.path.join(a.out, "score.json"), json.dumps(doc, indent=1, sort_keys=True) + "\n")
    write_atomic(os.path.join(a.out, "report.md"), report_md(doc))
    bad = len(doc["failures"])
    print(json.dumps({"step": "score", "ok": bad == 0, "counts": counts, "failures": bad, "out": a.out},
                     sort_keys=True))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
