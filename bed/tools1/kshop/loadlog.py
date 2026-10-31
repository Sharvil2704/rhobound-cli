"""The window and the request count of one production window, from the kshop-load Job's log (SPEC 0b rule 2).

    python3 -I loadlog.py LOAD_JSON --seconds N --out request-count.json

LOAD_JSON is `kubectl logs job/kshop-load` (stderr and stdout interleaved): one line
"YYYY/MM/DD HH:MM:SS kshop-load: N requests over S s (R rps), seed X" (Go's log, UTC in the scratch image) and one JSON
line per URL {"url", "ok", "errors", "mean_ms", ...}. The window is ONE source of truth: start = that line's timestamp
(second resolution), end = start + N s; the same two RFC 3339 strings go to `rhobound check --window S,E`. Entries are
named by the entry service (the URL's first host label: storefront = /browse; checkout = /buy/card + /buy/wallet), count
= ok + errors. Writes request-count.json (rhobound.request-count/v1, source loadgen) and prints one JSON line
{"start", "end", "since_ns", "until_ns", "requests", "entries"}. Exit 0; 1 when the log is not one finished window.
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.parse

START = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) kshop-load: (\d+) requests over (\d+) s \(([\d.]+) rps\), seed (\d+)\s*$")


def parse(text: str, seconds: int) -> tuple[dict, dict]:
    starts, rows = [], []
    for line in text.splitlines():
        line = line.strip()
        m = START.match(line)
        if m:
            starts.append(m)
        elif line.startswith("{"):
            try:
                d = json.loads(line)
            except ValueError:
                raise SystemExit(f"loadlog: not JSON: {line[:120]}")
            if isinstance(d, dict) and "url" in d:
                rows.append(d)
    if len(starts) != 1:
        raise SystemExit(f"loadlog: {len(starts)} 'kshop-load: N requests over' lines (want exactly 1)")
    m = starts[0]
    if int(m.group(3)) != seconds:
        raise SystemExit(f"loadlog: the load ran {m.group(3)} s, the window is {seconds} s")
    if not rows:
        raise SystemExit("loadlog: no per-URL result line (did the Job finish?)")
    start = datetime.datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    end = start + datetime.timedelta(seconds=seconds)
    counts: dict[str, int] = {}
    for r in rows:
        host = urllib.parse.urlsplit(r["url"]).hostname or ""
        entry = host.split(".")[0]
        if not entry or not isinstance(r.get("ok"), int) or not isinstance(r.get("errors"), int):
            raise SystemExit(f"loadlog: bad result line for {r.get('url')!r}")
        counts[entry] = counts.get(entry, 0) + r["ok"] + r["errors"]
    total, want = sum(counts.values()), int(m.group(2))
    if total != want:
        raise SystemExit(f"loadlog: the result lines count {total} requests, the start line {want}")
    iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
    rc = {"schema": "rhobound.request-count/v1", "window": {"start": iso(start), "end": iso(end)}, "source": "loadgen",
          "entries": [{"entry": k, "count": v} for k, v in counts.items()]}
    info = {"start": iso(start), "end": iso(end), "since_ns": int(start.timestamp()) * 10**9,
            "until_ns": int(end.timestamp()) * 10**9, "requests": total, "rps": float(m.group(4)),
            "seed": int(m.group(5)), "entries": counts}
    return rc, info


def main():
    p = argparse.ArgumentParser()
    p.add_argument("log")
    p.add_argument("--seconds", type=int, required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    with open(a.log, encoding="utf-8", errors="replace") as f:
        rc, info = parse(f.read(), a.seconds)
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rc, f)
    os.replace(tmp, a.out)
    print(json.dumps(info, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            sys.exit(1)
        raise
