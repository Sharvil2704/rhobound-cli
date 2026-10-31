"""splitarms.py on a small hand-made capture: roots by deployment and by pod prefix, children before their root in
another file, decoys, a conflict, a partial line, gzip and plain, structure kept.
usage: python3 -I tools1/tests/ab/test_splitarms_unit.py"""
import gzip
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPLIT = os.path.join(HERE, "..", "..", "lib", "splitarms.py")


def res(dep=None, pod=None, svc="auth"):
    at = [{"key": "service.name", "value": {"stringValue": svc}}]
    if pod:
        at.append({"key": "k8s.pod.name", "value": {"stringValue": pod}})
    if dep:
        at.append({"key": "k8s.deployment.name", "value": {"stringValue": dep}})
    return {"attributes": at, "droppedAttributesCount": 0}


def span(tid, sid, parent=None, kind=2, name="GET /verify"):
    sp = {"traceId": tid, "spanId": sid, "name": name, "kind": kind, "startTimeUnixNano": "1792646025528666887",
          "endTimeUnixNano": "1792646025538666887", "attributes": [], "status": {}}
    if parent:
        sp["parentSpanId"] = parent
    return sp


def rs(resource, *spans, scope="otelhttp"):
    return {"resource": resource, "scopeSpans": [{"scope": {"name": scope, "version": "0.72.0"}, "spans": list(spans)}],
            "schemaUrl": "https://opentelemetry.io/schemas/1.26.0"}


T = {k: ("%032x" % (i + 1)) for i, k in enumerate(["a1", "b1", "prod", "decoy", "c", "conf", "a2"])}


def build(raw):
    os.makedirs(os.path.join(raw, "sub"))
    # children first (another file, sorted earlier), the roots later: pass 1 must see the whole capture
    with open(os.path.join(raw, "0-children.jsonl"), "w") as f:
        f.write(json.dumps({"resourceSpans": [
            rs(res("inventory", "inventory-5d-xx", "inventory"), span(T["a1"], "c1", "r1", kind=2, name="GET /stock"),
               span(T["prod"], "c2", "r3", name="GET /stock"), span(T["b1"], "c3", "r2", name="GET /stock")),
        ]}) + "\n")
        f.write("\n")
    with gzip.open(os.path.join(raw, "sub", "1-roots.jsonl.gz"), "wt") as f:
        f.write(json.dumps({"resourceSpans": [
            rs(res("auth", "auth-79-x"), span(T["prod"], "r3")),
            rs(res("auth-ab-a", "auth-ab-a-5d-aaaaa"), span(T["a1"], "r1"), span(T["a1"], "k1", "r1", kind=3)),
            rs(res(None, "auth-ab-b-7c-bbbbb"), span(T["b1"], "r2")),
            rs(res(None, "auth-ab-ax-1"), span(T["decoy"], "r4")),
            rs(res("auth-ab-c", "auth-ab-c-1"), span(T["c"], "r5")),
            rs(res("auth-ab-a", "auth-ab-a-5d-aaaaa"), span(T["conf"], "r6")),
            rs(res("auth-ab-b", "auth-ab-b-7c-bbbbb"), span(T["conf"], "r7")),
        ]}) + "\n")
    with open(os.path.join(raw, "sub", "spans-2.jsonl"), "w") as f:
        f.write(json.dumps({"resourceSpans": [rs(res("auth-ab-a", "auth-ab-a-5d-aaaaa"),
                                                  span(T["a2"], "r8", "0000000000000000"))]}) + "\n")
        f.write('{"resourceSpans": [{"resource": ')            # a partial tail line
    with open(os.path.join(raw, "notes.txt"), "w") as f:
        f.write("not a trace file\n")
    with open(os.path.join(raw, ".hidden.json"), "w") as f:
        f.write("{bad\n")


def read(out):
    with open(os.path.join(out, "traces", "spans.jsonl")) as f:
        return [json.loads(line) for line in f]


class SplitTest(unittest.TestCase):
    def run_split(self, *args):
        p = subprocess.run([sys.executable, "-I", SPLIT, *args], capture_output=True, text=True)
        return p.returncode, p.stderr

    def test_split(self):
        with tempfile.TemporaryDirectory() as d:
            raw = os.path.join(d, "raw")
            build(raw)
            oa, ob, stats = os.path.join(d, "raw-a"), os.path.join(d, "raw-b"), os.path.join(d, "split.json")
            code, err = self.run_split("auth", raw, oa, ob, "--stats", stats)
            self.assertEqual(code, 0, err)
            with open(stats) as f:
                st = json.load(f)
            self.assertEqual(json.loads(err.strip().splitlines()[-1]), st)
            self.assertEqual(st["traces"], {"a": 2, "b": 1})
            self.assertEqual(st["arm_roots"], {"a": {"deployment": 3, "pod_prefix": 0},
                                               "b": {"deployment": 1, "pod_prefix": 1}})
            self.assertEqual((st["conflicts"], st["bad_lines"], st["files"], st["lines"]), (1, 1, 3, 4))
            self.assertEqual(st["spans"], {"read": 12, "a": 4, "b": 2, "dropped": 6})
            la, lb = read(oa), read(ob)
            ids = lambda lines: sorted((sp["traceId"], sp["spanId"]) for l in lines for r in l["resourceSpans"]
                                       for s in r["scopeSpans"] for sp in s["spans"])
            self.assertEqual(ids(la), sorted([(T["a1"], "c1"), (T["a1"], "r1"), (T["a1"], "k1"), (T["a2"], "r8")]))
            self.assertEqual(ids(lb), sorted([(T["b1"], "c3"), (T["b1"], "r2")]))
            # structure: the child's resource (inventory) and scope kept, one resourceSpans per source resource
            first = la[0]["resourceSpans"][0]
            self.assertEqual(first["resource"], res("inventory", "inventory-5d-xx", "inventory"))
            self.assertEqual(first["scopeSpans"][0]["scope"], {"name": "otelhttp", "version": "0.72.0"})
            self.assertEqual(first["schemaUrl"], "https://opentelemetry.io/schemas/1.26.0")
            self.assertEqual([len(l["resourceSpans"]) for l in la], [1, 1, 1])
            self.assertFalse(any(n.startswith(".") for n in os.listdir(os.path.join(oa, "traces"))))

    def test_no_arm_fails(self):
        with tempfile.TemporaryDirectory() as d:
            raw = os.path.join(d, "raw")
            build(raw)
            code, err = self.run_split("payments", raw, os.path.join(d, "a"), os.path.join(d, "b"))
            self.assertEqual(code, 1)
            self.assertIn("no trace of payments-ab-a or payments-ab-b", err)

    def test_usage_and_missing(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_split("auth", d)[0], 2)
            self.assertEqual(self.run_split("auth", d, "a", "b", "--stats")[0], 2)
            self.assertEqual(self.run_split("auth", os.path.join(d, "nope"), "a", "b")[0], 1)
            self.assertEqual(self.run_split("auth", d, os.path.join(d, "a"), os.path.join(d, "b"))[0], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
