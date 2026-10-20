#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Writes the inputs of parity.py's `edge` group: the cases found when the first version was checked (parity,
performance, safety), so that every fix stays checked against the Go binary.

    python3 -I scripts/edge_inputs.py FIXTURE OUTDIR

FIXTURE is rhobound-cli's testdata/capture-chain. OUTDIR gets:
  ties/*        parallel calls to one callee whose CLIENT spans start at the same nanosecond, in shuffled and
                reversed capture order, and the patterns next to it (distinct callees, parent-child ties, stages)
                (as the original tie-case generators wrote them, with their seeds)
  json/*        capture-chain as `.json` streams: one value per line, gzipped, pretty-printed, adjacent values,
                a value cut by a line that starts with '{' inside it, a syntax error late, a truncation, a bad rune
                at the end, a corrupt gzip member
  names/*       capture-chain with service names that hold \\v, \\f, a tab, invalid UTF-8, CJK and NBSP (the
                text report's tabwriter, the quoting)
  topo/*.json   topologies whose names hold \\v and \\f (`model`'s text report)
  nonutf8/      a copy of capture-chain at a path with the byte 0xff in it
  misc/utf8port a client span whose server.port intValue holds invalid UTF-8 (a panic once)
  misc/peers8   100,000 distinct 8-byte peer names (quadratic interning once)
  out/          --out fixtures: a regular file, a read-only folder, a symlink loop
"""
import gzip
import json
import os
import random
import shutil
import stat
import sys

FIXTURE, OUT = sys.argv[1], sys.argv[2]
T0 = 1_700_000_000_000_000_000


def mkdirs(p):
    os.makedirs(p, exist_ok=True)
    return p


def write_capture(d, lines, name="spans.jsonl", gz=False):
    mkdirs(os.path.join(d, "traces"))
    body = "".join(x + "\n" for x in lines).encode()
    p = os.path.join(d, "traces", name)
    with open(p, "wb") as f:
        f.write(gzip.compress(body, mtime=0) if gz else body)


def res_line(svc, pod, spans):
    return json.dumps({"resourceSpans": [{"resource": {"attributes": [
        {"key": "service.name", "value": {"stringValue": svc}},
        {"key": "k8s.pod.name", "value": {"stringValue": pod}}]},
        "scopeSpans": [{"spans": spans}]}]})


# ------------------------------------------------------------------ ties

def sp(tr, sid, parent, kind, s, e, peer=None):
    d = {"traceId": "%032x" % tr, "spanId": "%016x" % sid, "parentSpanId": ("%016x" % parent) if parent else "",
         "kind": kind, "startTimeUnixNano": str(T0 + s), "endTimeUnixNano": str(T0 + e)}
    if peer:
        d["attributes"] = [{"key": "server.address", "value": {"stringValue": peer}}]
    return d


def write_res(name, res):
    lines = []
    for (svc, pod), spans in res.items():
        for i in range(0, len(spans), 300):
            lines.append(res_line(svc, pod, spans[i:i + 300]))
    write_capture(os.path.join(OUT, "ties", name), lines)


def ties_shuffled_reversed():
    rng = random.Random(7)
    for variant in ("shuffled", "reversed"):
        res = {("fe", "fe-0"): [], ("be", "be-0"): []}
        t, sid = 0, 1
        for tr in range(1, 8001):
            t += int(rng.expovariate(1 / 40e6))
            root = sid
            sid += 1
            start_c = t + 1_000_000 + rng.randint(0, 999)
            kids, ends = [], []
            for _ in range(3):
                dur = int(rng.expovariate(1 / 3e6)) + rng.randint(1, 997)
                cs = start_c
                ss = cs + 100_001  # all three server spans start at the same ns
                se = ss + dur
                ce = se + 99_999
                cid, bid = sid, sid + 1
                sid += 2
                kids.append((sp(tr, cid, root, 3, cs, ce, "be"), sp(tr, bid, cid, 2, ss, se)))
                ends.append(ce)
            re_ = max(ends) + 500_000 + rng.randint(0, 333)
            res[("fe", "fe-0")].append(sp(tr, root, 0, 2, t, re_))
            if variant == "shuffled":
                rng.shuffle(kids)
            else:
                kids = kids[::-1]
            for c, b in kids:
                res[("fe", "fe-0")].append(c)
                res[("be", "be-0")].append(b)
        write_res(variant, res)


def ties_gen(name, seed, callees, parent_tie=False, stages=None, n=8000, shuffle=True):
    rng = random.Random(seed)
    res = {}

    def add(svc, s):
        res.setdefault((svc, svc + "-0"), []).append(s)

    t, sid = 0, 1
    for tr in range(1, n + 1):
        t += int(rng.expovariate(1 / 40e6))
        root = sid
        sid += 1
        cur = t if parent_tie else t + 1_000_000 + rng.randint(0, 999)
        kids = []
        for g in stages or [callees]:
            ends = []
            for callee in g:
                dur = int(rng.expovariate(1 / 3e6)) + rng.randint(1, 997)
                cid, bid = sid, sid + 1
                sid += 2
                ss = cur + 100_001
                kids.append((callee, sp(tr, cid, root, 3, cur, ss + dur + 99_999, callee), sp(tr, bid, cid, 2, ss, ss + dur)))
                ends.append(ss + dur + 99_999)
            cur = max(ends) + rng.randint(1000, 5000)
        add("fe", sp(tr, root, 0, 2, t, cur + 500_000 + rng.randint(0, 333)))
        if shuffle:
            rng.shuffle(kids)
        for callee, c, b in kids:
            add("fe", c)
            add(callee, b)
    write_res(name, res)


def ties():
    ties_shuffled_reversed()
    ties_gen("par-two-callees", 11, ["be", "db"])
    ties_gen("par-same-x2", 12, ["be", "be"])
    ties_gen("par-same-x3-plus-other", 13, ["be", "be", "be", "db"])
    ties_gen("parent-child-tie", 14, ["be"], parent_tie=True)
    ties_gen("parent-child-tie-par", 15, ["be", "db"], parent_tie=True)
    ties_gen("stages-same", 16, None, stages=[["be", "be"], ["db"]])
    ties_gen("stages-same-2", 17, None, stages=[["db"], ["be", "be", "be"]])
    ties_gen("par-same-x3-unshuffled", 18, ["be", "be", "be"], shuffle=False)


# ------------------------------------------------------------------ capture-chain variants

def chain_lines():
    out = []
    tdir = os.path.join(FIXTURE, "traces")
    for f in sorted(os.listdir(tdir)):
        raw = open(os.path.join(tdir, f), "rb").read()
        if f.endswith(".gz"):
            raw = gzip.decompress(raw)
        out += [x for x in raw.decode().split("\n") if x.strip()]
    return out


def json_streams():
    lines = chain_lines()
    base = "\n".join(lines).encode() + b"\n"
    cases = {
        "lines": base,
        "pretty": b"\n".join(json.dumps(json.loads(x), indent=1).encode() for x in lines) + b"\n",
        "adjacent": "".join(lines).encode(),
        "nested-cut": base.replace(b'[{"resource"', b'[\n{"resource"'),
    }
    at = len(base) * 3 // 4
    at = base.index(b"\n", at) + 1
    cases["syntax-late"] = base[:at] + b'{"x":tru}\n' + base[at:]
    cases["ctrl-in-string-late"] = base[:at] + b'{"a":"x\x01y"}\n' + base[at:]
    cases["truncated"] = base[:-7]
    cases["bad-rune-at-end"] = base + "é".encode()
    cases["number-last"] = base + b"7"
    for k, b in cases.items():
        for gz in (False, True):
            d = mkdirs(os.path.join(OUT, "json", k + ("-gz" if gz else ""), "traces"))
            name = "spans.json" + (".gz" if gz else "")
            with open(os.path.join(d, name), "wb") as f:
                f.write(gzip.compress(b, mtime=0) if gz else b)
    z = bytearray(gzip.compress(base, mtime=0))
    z[len(z) // 2] ^= 0xFF
    d = mkdirs(os.path.join(OUT, "json", "corrupt-gz", "traces"))
    with open(os.path.join(d, "spans.json.gz"), "wb") as f:
        f.write(bytes(z))


def renamed(name, mapping):
    """capture-chain with its service names (and the peer names that point at them) replaced."""
    out = []
    for ln in chain_lines():
        doc = json.loads(ln)
        for rs in doc["resourceSpans"]:
            for a in rs["resource"]["attributes"]:
                v = a["value"].get("stringValue")
                if a["key"] == "service.name" and v in mapping:
                    a["value"]["stringValue"] = mapping[v]
            for ss in rs["scopeSpans"]:
                for s in ss["spans"]:
                    for a in s.get("attributes", []):
                        v = a["value"].get("stringValue")
                        if a["key"] in ("server.address", "peer.service") and v in mapping:
                            a["value"]["stringValue"] = mapping[v]
        out.append(json.dumps(doc, ensure_ascii=False))
    write_capture(os.path.join(OUT, "names", name), out)


def names():
    renamed("vt-ff", {"a": "e\u000bd\u000cg", "b": "b\u000bb"})
    renamed("ff-only", {"b": "x\u000cyy"})
    renamed("tab", {"b": "t\tb"})
    renamed("cjk-nbsp", {"a": "日本", "b": "b b"})
    # invalid UTF-8 in a name: the reader replaces it (per byte) with U+FFFD
    lines = [ln.replace('"stringValue":"b"', '"stringValue":"b\\udcff"') for ln in chain_lines()]
    write_capture(os.path.join(OUT, "names", "lone-surrogate"), lines)
    raw = [ln.encode().replace(b'"stringValue":"a"', b'"stringValue":"a\xff\xe2\x82"') for ln in chain_lines()]
    d = mkdirs(os.path.join(OUT, "names", "invalid-utf8", "traces"))
    with open(os.path.join(d, "spans.jsonl"), "wb") as f:
        f.write(b"\n".join(raw) + b"\n")


def topologies():
    d = mkdirs(os.path.join(OUT, "topo"))
    for k, n in (("vt", "a\u000bb"), ("ff", "a\u000cb"), ("vt-ff", "e\u000bd\u000cg")):
        doc = {"name": "t", "entry": {n: 1}, "services": [{"name": n, "s": 2, "children": ["z"]}, {"name": "z", "s": 3}]}
        with open(os.path.join(d, k + ".json"), "w") as f:
            json.dump(doc, f)
    # a topology refused at 95 requests/s (b at 95%), for sweep's order of checks
    doc = {"name": "two", "entry": {"a": 1}, "services": [{"name": "a", "s": 1, "children": ["b"]}, {"name": "b", "s": 10}]}
    with open(os.path.join(d, "two.json"), "w") as f:
        json.dump(doc, f)


def nonutf8():
    d = os.path.join(os.fsencode(OUT), b"nonutf8")
    os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, b"cap\xffdir")
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(os.fsencode(FIXTURE), dst)
    # a trace file whose own name is not UTF-8
    dst2 = os.path.join(d, b"capx")
    if os.path.exists(dst2):
        shutil.rmtree(dst2)
    os.makedirs(os.path.join(dst2, b"traces"))
    for f in os.listdir(os.path.join(os.fsencode(FIXTURE), b"traces")):
        shutil.copy(os.path.join(os.fsencode(FIXTURE), b"traces", f), os.path.join(dst2, b"traces", b"sp\xe9" + f))


def misc():
    span = {"traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef", "name": "GET", "kind": 3,
            "startTimeUnixNano": "1000", "endTimeUnixNano": "2000",
            "attributes": [{"key": "peer.service", "value": {"stringValue": "db"}},
                           {"key": "server.port", "value": {"intValue": "5@32"}}]}
    line = json.dumps({"resourceSpans": [{"resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "api"}}]},
                                          "scopeSpans": [{"spans": [span]}]}]}).encode().replace(b"5@32", b"5\xb432")
    d = mkdirs(os.path.join(OUT, "misc", "utf8port", "traces"))
    with open(os.path.join(d, "spans.jsonl"), "wb") as f:
        f.write(line + b"\n")
    # 100,000 distinct 8-byte peer names
    n = 100_000
    t0 = 1792145237637323545
    ch = [{"traceId": "%032x" % (0x9000000 + i), "spanId": "%016x" % (0x400000 + i), "kind": 3, "name": "op",
           "startTimeUnixNano": str(t0 + i), "endTimeUnixNano": str(t0 + i + 5),
           "attributes": [{"key": "peer.service", "value": {"stringValue": "h%07d" % i}},
                          {"key": "server.port", "value": {"intValue": "443"}}]} for i in range(n)]
    lines = [json.dumps({"resourceSpans": [{"resource": {"attributes": [
        {"key": "service.name", "value": {"stringValue": "a"}}, {"key": "k8s.pod.name", "value": {"stringValue": "a-1"}}]},
        "scopeSpans": [{"spans": ch[k:k + 2000]}]}]}, separators=(",", ":")) for k in range(0, n, 2000)]
    write_capture(os.path.join(OUT, "misc", "peers8"), lines)


def out_fixtures():
    d = mkdirs(os.path.join(OUT, "out"))
    open(os.path.join(d, "afile"), "w").close()
    ro = os.path.join(d, "ro")
    if os.path.isdir(ro):
        os.chmod(ro, 0o755)
        shutil.rmtree(ro)
    os.makedirs(ro)
    os.chmod(ro, stat.S_IRUSR | stat.S_IXUSR | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
    for a, b in (("loop1", "loop2"), ("loop2", "loop1")):
        p = os.path.join(d, a)
        if os.path.lexists(p):
            os.remove(p)
        os.symlink(b, p)


ties()
json_streams()
names()
topologies()
nonutf8()
misc()
out_fixtures()
print("edge inputs written to", OUT)
