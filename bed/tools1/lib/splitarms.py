#!/usr/bin/env python3
"""Split copied Collector files into the two arms of an A/B run (SPEC 5 step 4).

usage: python3 -I splitarms.py SERVICE RAW_DIR OUT_A OUT_B [--stats FILE]

A trace is arm a (b) when its root span (no parent) sits on a resource whose k8s.deployment.name is SERVICE-ab-a
(SERVICE-ab-b); a resource without k8s.deployment.name falls back to k8s.pod.name starting with SERVICE-ab-a- (-b-).
Pass 1 maps traceId -> arm; pass 2 writes every span of a kept trace to OUT_X/traces/spans.jsonl, keeping the
resourceSpans/scopeSpans structure (only the kept spans). Every other trace is dropped. RAW_DIR is read recursively:
files whose name holds ".json" (plain or gzip); a line that does not parse (a partial tail) is counted and skipped.
Stats: one JSON line on stderr (and FILE). Exit 0 ok, 1 an arm has no trace or a file cannot be read, 2 usage.
"""
import gzip
import json
import os
import sys

USAGE = "usage: python3 -I splitarms.py SERVICE RAW_DIR OUT_A OUT_B [--stats FILE]"


def files_of(raw):
    out = []
    for d, dirs, names in os.walk(raw):
        dirs.sort()
        for n in sorted(names):
            if not n.startswith(".") and ".json" in n:
                out.append(os.path.join(d, n))
    return out


def open_text(path):
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic[:2] == b"\x1f\x8b":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    if magic == b"\x28\xb5\x2f\xfd":
        raise ValueError(f"{path}: zstd-compressed; the Collector's file exporter must write plain or gzip")
    return open(path, "rt", encoding="utf-8", errors="replace")


def raw_lines(path, st):
    """The file's lines; a truncated gzip (a file copied while written) ends early and is counted."""
    with open_text(path) as f:
        try:
            yield from f
        except EOFError:
            st["truncated_files"] += 1


def lines_of(paths, st):
    for p in paths:
        for line in raw_lines(p, st):
            if not line.strip():
                continue
            st["lines"] += 1
            try:
                d = json.loads(line)
            except ValueError:
                st["bad_lines"] += 1
                continue
            if not isinstance(d, dict) or not isinstance(d.get("resourceSpans"), list):
                st["other_lines"] += 1
                continue
            yield d


def attrs(resource):
    out = {}
    for a in (resource or {}).get("attributes") or []:
        v = a.get("value") or {}
        if "stringValue" in v:
            out[a.get("key")] = v["stringValue"]
    return out


def arm_of(resource, service):
    """('a'|'b'|None, how) for a resource."""
    at = attrs(resource)
    dep = at.get("k8s.deployment.name")
    if dep:
        for arm in "ab":
            if dep == f"{service}-ab-{arm}":
                return arm, "deployment"
        return None, None
    pod = at.get("k8s.pod.name") or ""
    for arm in "ab":
        if pod.startswith(f"{service}-ab-{arm}-"):
            return arm, "pod_prefix"
    return None, None


def is_root(span):
    p = span.get("parentSpanId")
    return not p or p == "0000000000000000"


def main(argv):
    stats_path = None
    args = list(argv)
    if "--stats" in args:
        i = args.index("--stats")
        if i + 1 >= len(args):
            print(USAGE, file=sys.stderr)
            return 2
        stats_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 4 or not args[0] or args[0].startswith("-"):
        print(USAGE, file=sys.stderr)
        return 2
    service, raw, out_a, out_b = args
    if not os.path.isdir(raw):
        print(f"splitarms: {raw} is not a folder", file=sys.stderr)
        return 1
    paths = files_of(raw)
    st = {"schema": "rbd.splitarms/v1", "service": service, "raw": raw, "files": len(paths), "lines": 0,
          "bad_lines": 0, "other_lines": 0, "truncated_files": 0, "roots": 0,
          "arm_roots": {"a": {"deployment": 0, "pod_prefix": 0}, "b": {"deployment": 0, "pod_prefix": 0}},
          "conflicts": 0, "traces": {"a": 0, "b": 0}, "spans": {"read": 0, "a": 0, "b": 0, "dropped": 0}}
    if not paths:
        print(f"splitarms: no trace file under {raw}", file=sys.stderr)
        return 1

    # pass 1: traceId -> arm, from root spans only
    arm_by_trace, conflicted = {}, set()
    try:
        for d in lines_of(paths, st):
            for rs in d["resourceSpans"]:
                arm, how = arm_of(rs.get("resource"), service)
                for ss in rs.get("scopeSpans") or []:
                    for sp in ss.get("spans") or []:
                        if not is_root(sp):
                            continue
                        st["roots"] += 1
                        if arm is None:
                            continue
                        tid = sp.get("traceId")
                        prev = arm_by_trace.get(tid)
                        if prev is not None and prev != arm:
                            conflicted.add(tid)
                        arm_by_trace[tid] = arm
                        st["arm_roots"][arm][how] += 1
    except (OSError, ValueError, EOFError) as e:
        print(f"splitarms: {e}", file=sys.stderr)
        return 1
    for tid in conflicted:
        del arm_by_trace[tid]
    st["conflicts"] = len(conflicted)
    for arm in arm_by_trace.values():
        st["traces"][arm] += 1

    # pass 2: the kept spans, each arm to its own file, structure kept
    keys = ("lines", "bad_lines", "other_lines", "truncated_files")
    seen = {k: st[k] for k in keys}
    st.update({k: 0 for k in keys})
    outs, tmps = {}, {}
    try:
        for arm, out in (("a", out_a), ("b", out_b)):
            os.makedirs(os.path.join(out, "traces"), exist_ok=True)
            tmps[arm] = os.path.join(out, "traces", ".spans.jsonl.tmp")
            outs[arm] = open(tmps[arm], "w", encoding="utf-8")
        for d in lines_of(paths, st):
            kept = {"a": [], "b": []}
            for rs in d["resourceSpans"]:
                per = {"a": [], "b": []}
                for ss in rs.get("scopeSpans") or []:
                    sp_by = {"a": [], "b": []}
                    for sp in ss.get("spans") or []:
                        st["spans"]["read"] += 1
                        arm = arm_by_trace.get(sp.get("traceId"))
                        if arm is None:
                            st["spans"]["dropped"] += 1
                            continue
                        sp_by[arm].append(sp)
                        st["spans"][arm] += 1
                    for arm in "ab":
                        if sp_by[arm]:
                            nss = {k: v for k, v in ss.items() if k != "spans"}
                            nss["spans"] = sp_by[arm]
                            per[arm].append(nss)
                for arm in "ab":
                    if per[arm]:
                        nrs = {k: v for k, v in rs.items() if k != "scopeSpans"}
                        nrs["scopeSpans"] = per[arm]
                        kept[arm].append(nrs)
            for arm in "ab":
                if kept[arm]:
                    outs[arm].write(json.dumps({"resourceSpans": kept[arm]}, separators=(",", ":")) + "\n")
        for arm, out in (("a", out_a), ("b", out_b)):
            outs[arm].close()
            os.replace(tmps[arm], os.path.join(out, "traces", "spans.jsonl"))
    except (OSError, ValueError, EOFError) as e:
        print(f"splitarms: {e}", file=sys.stderr)
        return 1
    finally:
        for f in outs.values():
            f.close()
    if seen != {k: st[k] for k in keys}:
        print("splitarms: the files changed between the two passes", file=sys.stderr)
        return 1
    st["ok"] = st["traces"]["a"] > 0 and st["traces"]["b"] > 0
    line = json.dumps(st, sort_keys=True)
    if stats_path:
        tmp = stats_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(line + "\n")
        os.replace(tmp, stats_path)
    print(line, file=sys.stderr)
    if not st["ok"]:
        print(f"splitarms: no trace of {service}-ab-a or {service}-ab-b (traces a={st['traces']['a']} "
              f"b={st['traces']['b']})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
