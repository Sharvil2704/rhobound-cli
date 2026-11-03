"""verify/regress.py: did a deployed change regress production? From truthx (or truth) runs' B0 and C windows (maze-load's
own client-side means), per entry: the mean change in ms with a standard error, and the verdict against the threshold.
Files only, nothing run; the inputs are data (python3 -I).

  python3 -I verify/regress.py RUN_DIR [RUN_DIR ...] [options]      each RUN_DIR holds b0.load.json and c.load.json
  python3 -I verify/regress.py --b0 FILE --c FILE [--b0 FILE --c FILE ...] [options]
  options: --threshold MS [4.0: policy/gate.json's max_entry_mean_change_ms] | --policy FILE (rhobound.policy/v1: its
           max_entry_mean_change_ms, and when it has max_entry_mean_change_pct the gate's rule per entry: the smaller of the
           ms limit and pct/100 x the B0 mean), --noise MS [2.0: the bed's single-bracket truth noise], --max-err-pct PP [1.0],
           --out FILE (the JSON, also printed)

load.json (maze-load's log, as state/ct3_score.py reads it): JSON lines {url, ok, errors, mean_ms, ...}; mean_ms is over the
ok requests. The entry is the first label of the URL's host (http://web:8080/browse -> web); several URLs of one host are
one entry, their means weighted by ok. The 'maze-load: N requests over S s (R rps), seed K' and 'maze-load: done in' lines
and part B's rbd.load/v1 line (the load setting) are checked: both windows of a pair must have finished, at the same load
setting (rps and mix; else exit 2), with the same entries.

Per entry, over the n (B0, C) pairs: change_ms = mean over pairs of (C mean - B0 mean); se_ms = noise / sqrt(n). load.json
has no per-request data, so the standard error is the bed's measured noise of one bracket's difference (about +-2 ms, which
already holds the windows' own sampling error), not a guess from percentiles; with n >= 2 the pairs' own spread is reported
too (sd_ms). over = change_ms > threshold; resolved = |change_ms - threshold| >= se_ms (an unresolved entry is within noise
of the threshold: its 'over' could flip in a re-run). errors_up: the C window's error share exceeds B0's by more than
--max-err-pct points, or C answered nothing ok (its mean_ms is then 0, which would read as a speed-up).

Output (rbd.regress/v1): {regressed: any entry over the threshold, regressed_resolved: any entry over it by at least se_ms,
errors_up: [entries], production_ok: not regressed and no errors_up, worst: the entry with the largest change - threshold,
entries: [...], unresolved: [entries], threshold_ms, noise_ms, n, se_ms, pairs: [...], warnings: [...]}.
Exit 0 production_ok; 1 regressed or errors_up; 2 cannot read or compare (the reason on stderr and in {"error"}).
"""
import argparse
import datetime
import json
import math
import os
import re
import sys
import urllib.parse

SCHEMA = "rbd.regress/v1"
RE_START = re.compile(r"(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)\S* maze-load: (\d+) requests over ([\d.]+) s "
                      r"\(([\d.]+) rps\), seed (-?\d+)")
RE_DONE = re.compile(r"maze-load: done in ([\d.]+) s")
MAX_BYTES = 8 << 20   # a load.json is a few kB; refuse anything absurd rather than read it


class Unusable(Exception):
    pass


def num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) else None


def entry_of(url):
    host = urllib.parse.urlparse(str(url)).hostname or ""
    label = host.split(".")[0]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", label):
        raise Unusable(f"url {url!r}: no plain host name")
    return label


def parse_load(path):
    """maze-load's log -> {file, entries: {entry: {ok, errors, mean_ms, urls}}, requests, seconds, rps, seed, done, load}."""
    try:
        if os.path.getsize(path) > MAX_BYTES:
            raise Unusable(f"{path}: larger than {MAX_BYTES} bytes: not a load.json")
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise Unusable(f"{path}: {e}") from None
    w = {"file": path, "entries": {}, "start": None, "requests": None, "seconds": None, "rps": None, "seed": None,
         "done": False, "load": None}
    urls = set()
    for ln in lines:
        m = RE_START.search(ln)
        if m:
            t = datetime.datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S")
            w["start"] = t.strftime("%Y-%m-%dT%H:%M:%SZ")
            w["requests"], w["seconds"] = int(m.group(2)), float(m.group(3))
            w["rps"], w["seed"] = float(m.group(4)), int(m.group(5))
            continue
        if RE_DONE.search(ln):
            w["done"] = True
            continue
        s = ln.strip()
        if not (s.startswith("{") and s.endswith("}")):
            continue
        try:
            row = json.loads(s)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        if row.get("schema") == "rbd.load/v1":
            w["load"] = {"rps": num(row.get("rps")), "shares": row.get("shares") if isinstance(row.get("shares"), dict) else None,
                         "summary": row.get("summary") if isinstance(row.get("summary"), str) else None}
            continue
        if "url" not in row:
            continue
        ok, err, mean = row.get("ok"), row.get("errors"), num(row.get("mean_ms"))
        if not isinstance(ok, int) or isinstance(ok, bool) or ok < 0 or not isinstance(err, int) or isinstance(err, bool) \
                or err < 0 or mean is None:
            raise Unusable(f"{path}: {row.get('url')!r}: ok/errors/mean_ms missing or not numbers")
        if row["url"] in urls:
            raise Unusable(f"{path}: two result lines for {row['url']!r}")
        urls.add(row["url"])
        e = w["entries"].setdefault(entry_of(row["url"]), {"ok": 0, "errors": 0, "sum_ms": 0.0, "urls": []})
        e["ok"] += ok
        e["errors"] += err
        e["sum_ms"] += float(mean) * ok
        e["urls"].append(urllib.parse.urlparse(str(row["url"])).path or "/")
    if not w["done"]:
        raise Unusable(f"{path}: no 'maze-load: done' line (the window did not finish)")
    if not w["entries"]:
        raise Unusable(f"{path}: no result lines")
    for e in w["entries"].values():
        e["mean_ms"] = e["sum_ms"] / e["ok"] if e["ok"] else None
        e["err_pct"] = 100.0 * e["errors"] / (e["ok"] + e["errors"]) if e["ok"] + e["errors"] else 0.0
        del e["sum_ms"]
    return w


def same_setting(a, b):
    """None if the two windows ran at one load setting, else the reason."""
    if a["rps"] is not None and b["rps"] is not None and abs(a["rps"] - b["rps"]) > 1e-6:
        return f"rate {a['rps']} rps vs {b['rps']} rps"
    la, lb = a["load"], b["load"]
    if la and lb:
        if la["rps"] is not None and lb["rps"] is not None and abs(la["rps"] - lb["rps"]) > 1e-6:
            return f"load setting rps {la['rps']} vs {lb['rps']}"
        if la["shares"] is not None and lb["shares"] is not None and la["shares"] != lb["shares"]:
            return f"load mix {la['shares']} vs {lb['shares']}"
    return None


def policy_limits(path):
    try:
        with open(path, encoding="utf-8") as f:
            p = json.load(f)
    except (OSError, ValueError) as e:
        raise Unusable(f"--policy {path}: {e}") from None
    ms = num(p.get("max_entry_mean_change_ms")) if isinstance(p, dict) else None
    if ms is None or ms <= 0:
        raise Unusable(f"--policy {path}: no positive max_entry_mean_change_ms")
    pct = num(p.get("max_entry_mean_change_pct"))
    return float(ms), (float(pct) if pct is not None and pct > 0 else None)


def analyse(pairs, threshold, pct, noise, max_err_pct):
    """pairs: [(label, b0 window, c window)] -> the rbd.regress/v1 document."""
    warn = []
    names = None
    for label, b, c in pairs:
        why = same_setting(b, c)
        if why:
            raise Unusable(f"{label}: B0 and C ran at different load settings ({why}): not comparable")
        if b["load"] is None or c["load"] is None:
            warn.append(f"{label}: no rbd.load/v1 line in {'B0' if b['load'] is None else 'C'}: the load setting is not checked")
        if b["seconds"] is not None and c["seconds"] is not None and b["seconds"] != c["seconds"]:
            warn.append(f"{label}: windows of {b['seconds']:g} s (B0) and {c['seconds']:g} s (C)")
        if set(b["entries"]) != set(c["entries"]):
            raise Unusable(f"{label}: B0 entries {sorted(b['entries'])} vs C entries {sorted(c['entries'])}")
        if names is None:
            names = sorted(b["entries"])
        elif sorted(b["entries"]) != names:
            raise Unusable(f"{label}: entries {sorted(b['entries'])}, the first pair's {names}")
        for e in names:
            if not b["entries"][e]["ok"]:
                raise Unusable(f"{label}: B0 {e} answered no request ok: production was broken before the change")
    n = len(pairs)
    se = noise / math.sqrt(n)
    rows, errors_up = [], []
    for e in names:
        ch, broken = [], False
        for label, b, c in pairs:
            bb, cc = b["entries"][e], c["entries"][e]
            if cc["ok"] == 0:
                broken = True
            else:
                ch.append(cc["mean_ms"] - bb["mean_ms"])
        b0m = sum(p[1]["entries"][e]["mean_ms"] for p in pairs) / n
        thr = threshold if pct is None else min(threshold, pct / 100.0 * b0m)
        b0_err = sum(p[1]["entries"][e]["err_pct"] for p in pairs) / n
        c_err = sum(p[2]["entries"][e]["err_pct"] for p in pairs) / n
        up = broken or c_err - b0_err > max_err_pct
        row = {"entry": e, "urls": pairs[0][1]["entries"][e]["urls"], "threshold_ms": round(thr, 4),
               "b0_mean_ms": round(b0m, 4),
               "c_mean_ms": None if broken else round(sum(p[2]["entries"][e]["mean_ms"] for p in pairs) / n, 4),
               "change_ms": None, "changes_ms": [round(x, 4) for x in ch], "se_ms": round(se, 4), "sd_ms": None,
               "margin_ms": None, "over": None, "resolved": None, "broken": broken, "errors_up": up,
               "b0_ok": sum(p[1]["entries"][e]["ok"] for p in pairs), "c_ok": sum(p[2]["entries"][e]["ok"] for p in pairs),
               "b0_errors": sum(p[1]["entries"][e]["errors"] for p in pairs),
               "c_errors": sum(p[2]["entries"][e]["errors"] for p in pairs),
               "b0_err_pct": round(b0_err, 4), "c_err_pct": round(c_err, 4)}
        if not broken:
            d = sum(ch) / n
            row["change_ms"], row["margin_ms"] = round(d, 4), round(d - thr, 4)
            row["over"], row["resolved"] = d > thr, abs(d - thr) >= se
            if n >= 2:
                row["sd_ms"] = round(math.sqrt(sum((x - d) ** 2 for x in ch) / (n - 1)), 4)
        if up:
            errors_up.append(e)
            warn.append(f"{e}: " + ("C answered no request ok" if broken else
                                    f"errors {c_err:.2f}% in C vs {b0_err:.2f}% in B0 (means are over ok only)"))
        rows.append(row)
    measured = [r for r in rows if r["change_ms"] is not None]
    worst = max(measured, key=lambda r: r["margin_ms"]) if measured else None
    regressed = any(r["over"] for r in measured)
    return {
        "schema": SCHEMA, "regressed": regressed,
        "regressed_resolved": any(r["over"] and r["resolved"] for r in measured),
        "errors_up": errors_up, "production_ok": not regressed and not errors_up,
        "worst": None if worst is None else {k: worst[k] for k in ("entry", "change_ms", "threshold_ms", "margin_ms", "se_ms",
                                                                    "over", "resolved")},
        "entries": rows, "unresolved": [r["entry"] for r in measured if not r["resolved"]],
        "threshold_ms": threshold, "threshold_pct": pct, "noise_ms": noise, "max_err_pct": max_err_pct, "n": n,
        "se_ms": round(se, 4),
        "pairs": [{"label": label, "b0": win_meta(b), "c": win_meta(c)} for label, b, c in pairs],
        "warnings": warn,
    }


def win_meta(w):
    return {"file": w["file"], "start": w["start"], "requests": w["requests"], "seconds": w["seconds"], "rps": w["rps"],
            "seed": w["seed"], "load": (w["load"] or {}).get("summary")}


def main(argv):
    ap = argparse.ArgumentParser(description="per-entry mean change of a deployed change (truthx B0 vs C), and its verdict")
    ap.add_argument("runs", nargs="*", help="truthx/truth run folders (b0.load.json, c.load.json)")
    ap.add_argument("--b0", action="append", default=[], help="a B0 load.json (paired in order with --c)")
    ap.add_argument("--c", action="append", default=[], help="a C load.json")
    ap.add_argument("--threshold", type=float, default=None, help="ms [4.0, the bed policy]")
    ap.add_argument("--policy", help="a rhobound.policy/v1 file to take the threshold from")
    ap.add_argument("--noise", type=float, default=2.0, help="single-bracket noise, ms [2.0]")
    ap.add_argument("--max-err-pct", type=float, default=1.0, help="error share rise that counts, points [1.0]")
    ap.add_argument("--out", help="also write the JSON here")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        if a.threshold is not None and a.policy:
            raise Unusable("--threshold or --policy, not both")
        thr, pct = (policy_limits(a.policy) if a.policy else (4.0 if a.threshold is None else a.threshold, None))
        for v, nm in ((thr, "--threshold"), (a.noise, "--noise"), (a.max_err_pct, "--max-err-pct")):
            if not math.isfinite(v) or v <= 0:
                raise Unusable(f"{nm} must be a positive number")
        if len(a.b0) != len(a.c):
            raise Unusable("--b0 and --c come in pairs")
        files = [(d, os.path.join(d, "b0.load.json"), os.path.join(d, "c.load.json")) for d in a.runs]
        files += [(f"pair {i + 1}", b, c) for i, (b, c) in enumerate(zip(a.b0, a.c))]
        if not files:
            raise Unusable("no run: give RUN_DIR(s) or --b0/--c pairs")
        pairs = [(label, parse_load(b), parse_load(c)) for label, b, c in files]
        doc = analyse(pairs, thr, pct, a.noise, a.max_err_pct)
    except Unusable as e:
        print(f"regress: cannot judge: {e}", file=sys.stderr)
        print(json.dumps({"schema": SCHEMA, "error": str(e)}))
        return 2
    text = json.dumps(doc, indent=1) + "\n"
    if a.out:
        tmp = a.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, a.out)
    sys.stdout.write(text)
    w = doc["worst"]
    print(f"regress: {'REGRESSED' if doc['regressed'] else 'no entry over the threshold'}"
          + (f"; errors up at {', '.join(doc['errors_up'])}" if doc["errors_up"] else "")
          + (f"; worst {w['entry']} {w['change_ms']:+.2f} ms (threshold {w['threshold_ms']:g}, se {w['se_ms']:.2f}"
             f"{', within noise' if not w['resolved'] else ''})" if w else ""), file=sys.stderr)
    return 0 if doc["production_ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
