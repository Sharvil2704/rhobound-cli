#!/usr/bin/env python3
"""prodcheck.py (SPEC2 S10, report-only): the production fit after a deploy against the one before it, per entry and per service.

On rbd-tools1 as rbd (orch/bench.sh runs it after automerge.sh recorded a successful deploy.yml run, whose deploy.sh refit):

  python3 -I /opt/rbd/bench/prodcheck.py --previous FIT --current FIT [--services a,b] [--prediction PRED] [--out FILE]

FIT: a rhobound.fit/v1 fit.json, or the folder holding it (baseline.json's fit.dir). Reads the fits' own observations only, no
CLI and no model: entries = inference.stats[] with entry true (observed_server_ms: the entry's observed mean), services = every
inference.stats[] row (observed_server_ms, own_mean_ms, rate_rps, workers_per_pod x pods). --services names the services the
change touched (rhobound-change.json); --prediction is the gate's prediction.json (rhobound-cli.report/v2: entries[].band_ms,
change_ms) for the entry's predicted band and whether production's change fell inside it (the accuracy chain's last link).
It decides nothing: two production windows differ by load noise too (no A/A floor is applied here; verify/score.py has one),
and the notes say when the two windows' entry rates differ by more than 5% (the comparison is then weaker).
Writes rbd.bench-prodcheck/v1 (atomic replace) to --out, else stdout. Exit 0 written, 2 cannot read a fit or the prediction.
"""
import argparse
import hashlib
import json
import math
import os
import sys
import time

SCHEMA = "rbd.bench-prodcheck/v1"


def num(x):
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) else None


def fit_of(arg):
    p = os.path.join(arg, "fit.json") if os.path.isdir(arg) else arg
    with open(p, "rb") as f:
        b = f.read()
    d = json.loads(b)
    if d.get("schema") != "rhobound.fit/v1":
        raise ValueError("%s: schema %r, not rhobound.fit/v1" % (p, d.get("schema")))
    stats = {}
    for s in (d.get("inference") or {}).get("stats") or []:
        if isinstance(s, dict) and isinstance(s.get("name"), str):
            pods, wpp = s.get("pods"), s.get("workers_per_pod")
            stats[s["name"]] = {"entry": s.get("entry") is True, "observed_ms": num(s.get("observed_server_ms")),
                                "own_ms": num(s.get("own_mean_ms")), "rate_rps": num(s.get("rate_rps")),
                                "workers": pods * wpp if isinstance(pods, int) and isinstance(wpp, int) else None}
    if not stats:
        raise ValueError("%s: no inference.stats" % p)
    w = d.get("window") or {}
    meta = {"path": os.path.abspath(p), "digest": "sha256:" + hashlib.sha256(b).hexdigest(), "capture": d.get("capture"),
            "window": {"start": w.get("start"), "end": w.get("end"), "window_s": num(w.get("window_s"))}}
    return meta, stats


def delta(a, b):
    return None if a is None or b is None else b - a


def pct(a, b):
    return None if a is None or b is None or a == 0 else 100.0 * (b - a) / a


def rnd(x, n=4):
    return None if x is None else round(x, n)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--previous", required=True)
    ap.add_argument("--current", required=True)
    ap.add_argument("--services", default="")
    ap.add_argument("--prediction")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    try:
        pm, ps = fit_of(a.previous)
        cm, cs = fit_of(a.current)
        pred = {}
        if a.prediction:
            pr = json.load(open(a.prediction))
            for e in pr.get("entries") or []:
                band, ch = e.get("band_ms") or {}, e.get("change_ms") or {}
                pred[e.get("name")] = {"band_lo": num(band.get("lo")), "band_hi": num(band.get("hi")),
                                       "change_lo": num(ch.get("lo")), "change_hi": num(ch.get("hi"))}
    except (OSError, ValueError, AttributeError) as e:
        print("prodcheck: cannot read: %s" % e, file=sys.stderr)
        return 2
    changed = [s for s in a.services.split(",") if s]
    notes = []
    for s in changed:
        if s not in ps or s not in cs:
            notes.append("changed service %s is missing from the %s fit" % (s, "previous" if s not in ps else "current"))
    entries = []
    for name in sorted(set(n for n, s in ps.items() if s["entry"]) | set(n for n, s in cs.items() if s["entry"])):
        p, c = ps.get(name, {}), cs.get(name, {})
        d = delta(p.get("observed_ms"), c.get("observed_ms"))
        e = {"name": name, "previous_ms": rnd(p.get("observed_ms")), "current_ms": rnd(c.get("observed_ms")),
             "delta_ms": rnd(d), "delta_pct": rnd(pct(p.get("observed_ms"), c.get("observed_ms")), 3),
             "previous_rps": rnd(p.get("rate_rps"), 3), "current_rps": rnd(c.get("rate_rps"), 3), "predicted": None,
             "in_band": None}
        rp = pct(p.get("rate_rps"), c.get("rate_rps"))
        if rp is not None and abs(rp) > 5:
            notes.append("%s: the two windows' rates differ by %.1f%%: the load differed, the comparison is weaker" % (name, rp))
        q = pred.get(name)
        if q:
            e["predicted"] = q
            if d is not None and q["band_lo"] is not None and q["band_hi"] is not None:
                e["in_band"] = q["band_lo"] <= d <= q["band_hi"]
        if not p or not c:
            notes.append("entry %s is in only one of the fits" % name)
        entries.append(e)
    services = []
    for name in sorted(set(ps) | set(cs)):
        p, c = ps.get(name), cs.get(name)
        row = {"name": name, "changed": name in changed,
               "previous": {k: rnd(v) for k, v in p.items() if k != "entry"} if p else None,
               "current": {k: rnd(v) for k, v in c.items() if k != "entry"} if c else None,
               "delta_observed_ms": rnd(delta((p or {}).get("observed_ms"), (c or {}).get("observed_ms"))),
               "delta_own_ms": rnd(delta((p or {}).get("own_ms"), (c or {}).get("own_ms"))),
               "delta_own_pct": rnd(pct((p or {}).get("own_ms"), (c or {}).get("own_ms")), 3)}
        services.append(row)
    if pm["digest"] == cm["digest"]:
        notes.append("previous and current are the same fit: no refit since the deploy?")
    doc = {"schema": SCHEMA, "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "report_only": True,
           "previous": pm, "current": cm, "services_changed": changed, "entries": entries, "services": services,
           "notes": notes}
    text = json.dumps(doc, indent=1, sort_keys=True) + "\n"
    if a.out:
        tmp = a.out + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, a.out)
        for e in entries:
            print("prodcheck: %s %s -> %s ms (%+.3f ms)%s" % (e["name"], e["previous_ms"], e["current_ms"], e["delta_ms"] or 0,
                  "" if e["in_band"] is None else ", in the predicted band" if e["in_band"] else ", OUTSIDE the predicted band"),
                  file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
