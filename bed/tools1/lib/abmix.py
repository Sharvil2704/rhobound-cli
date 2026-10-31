#!/usr/bin/env python3
"""A service's request mix from a cut capture, for the A/B driver (SPEC 5 step 1).

usage: python3 -I abmix.py SERVICE CUT_DIR [--name CAPTURE] > mix.json

Reads CUT_DIR/traces/ (or CUT_DIR) OTLP/JSON lines, plain or gzip. Takes the SERVER spans whose resource service.name
is SERVICE; path = url.path, else http.route, else http.target (no query), else the span name 'GET /x' less its
method. rate_per_pod = those spans per second over the capture's window / distinct k8s.pod.name. The window is
CUT_DIR/manifest.json's (what `rhobound check --cut` writes), else request-count.json's, else the first to last span
start (window_source says which). Writes {"service", "rate_per_pod", "paths": [{"path", "w"}], "from_capture"} plus
"window", "window_source", "spans", "pods". Exit 0 ok, 1 no SERVER span of SERVICE or unreadable input, 2 usage.
"""
import datetime
import gzip
import json
import os
import re
import sys

USAGE = "usage: python3 -I abmix.py SERVICE CUT_DIR [--name CAPTURE] > mix.json"
SERVER = (2, "SPAN_KIND_SERVER")


def files_of(cut):
    root = os.path.join(cut, "traces") if os.path.isdir(os.path.join(cut, "traces")) else cut
    out = []
    for d, dirs, names in os.walk(root):
        dirs.sort()
        for n in sorted(names):
            if not n.startswith(".") and ".json" in n and n not in ("manifest.json", "request-count.json"):
                out.append(os.path.join(d, n))
    return out


def open_text(path):
    with open(path, "rb") as f:
        gz = f.read(2) == b"\x1f\x8b"
    return gzip.open(path, "rt", encoding="utf-8") if gz else open(path, "rt", encoding="utf-8")


def attr_map(lst):
    out = {}
    for a in lst or []:
        v = a.get("value") or {}
        for k in ("stringValue", "intValue"):
            if k in v:
                out[a.get("key")] = str(v[k])
                break
    return out


def path_of(span):
    at = attr_map(span.get("attributes"))
    for k in ("url.path", "http.route"):
        if at.get(k):
            return at[k]
    if at.get("http.target"):
        return at["http.target"].split("?", 1)[0]
    name = span.get("name") or ""
    parts = name.split(" ", 1)
    if len(parts) == 2 and parts[1].startswith("/"):
        return parts[1].split("?", 1)[0]
    return name


def parse_time(s):
    """RFC 3339 (any number of fraction digits; Python 3.12's fromisoformat takes at most 6) -> Unix seconds."""
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$", s or "")
    if not m:
        return None
    tz = "+00:00" if m[3] == "Z" else m[3]
    return datetime.datetime.fromisoformat(m[1] + tz).timestamp() + float("0" + (m[2] or ""))


def window_of(cut):
    """(start_s, end_s, source) from the capture's files, or (None, None, None)."""
    for name, key in (("manifest.json", "window"), ("request-count.json", "window")):
        p = os.path.join(cut, name)
        if os.path.isfile(p):
            try:
                with open(p, encoding="utf-8") as f:
                    w = json.load(f).get(key) or {}
                s, e = parse_time(w.get("start")), parse_time(w.get("end"))
            except (OSError, ValueError, AttributeError):
                continue
            if s is not None and e is not None and e > s:
                return s, e, name
    return None, None, None


def main(argv):
    args = list(argv)
    name = None
    if "--name" in args:
        i = args.index("--name")
        if i + 1 >= len(args):
            print(USAGE, file=sys.stderr)
            return 2
        name = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2 or args[0].startswith("-"):
        print(USAGE, file=sys.stderr)
        return 2
    service, cut = args
    paths = files_of(cut) if os.path.isdir(cut) else []
    if not paths:
        print(f"abmix: no trace file in {cut}", file=sys.stderr)
        return 1
    counts, pods, n = {}, set(), 0
    first = last = None
    try:
        for p in paths:
            with open_text(p) as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    for rs in d.get("resourceSpans") or []:
                        ra = attr_map((rs.get("resource") or {}).get("attributes"))
                        if ra.get("service.name") != service:
                            continue
                        pod = ra.get("k8s.pod.name") or ra.get("service.instance.id") or "unknown"
                        for ss in rs.get("scopeSpans") or []:
                            for sp in ss.get("spans") or []:
                                if sp.get("kind") not in SERVER:
                                    continue
                                n += 1
                                pods.add(pod)
                                k = path_of(sp)
                                counts[k] = counts.get(k, 0) + 1
                                t = int(sp.get("startTimeUnixNano") or 0) / 1e9
                                first = t if first is None or t < first else first
                                last = t if last is None or t > last else last
    except (OSError, ValueError, EOFError) as e:
        print(f"abmix: {e}", file=sys.stderr)
        return 1
    if n == 0:
        print(f"abmix: no SERVER span of {service} in {cut}", file=sys.stderr)
        return 1
    s, e, source = window_of(cut)
    if source is None:
        s, e, source = first, last, "spans"
    if not e > s:
        print(f"abmix: the window of {cut} is empty", file=sys.stderr)
        return 1
    iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    mix = {"service": service,
           "rate_per_pod": round(n / (e - s) / len(pods), 4),
           "paths": [{"path": k, "w": round(c / n, 6)} for k, c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))],
           "from_capture": name or cut,
           "window": {"start": iso(s), "end": iso(e)}, "window_source": source,
           "spans": n, "pods": sorted(pods)}
    print(json.dumps(mix, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
