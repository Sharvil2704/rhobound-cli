"""test_export.py: unit tests of tools1/muse/export.py (python3 -I tools1/muse/tests/test_export.py). Offline, no Go.
Scratch under $RBD_SCRATCH/muse-t (default $TMPDIR/rbd/muse-t)."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.abspath(os.path.join(HERE, "../../.."))
EXPORT = os.path.join(KIT, "tools1/muse/export.py")
sys.dont_write_bytecode = True   # no __pycache__ beside export.py
spec = importlib.util.spec_from_file_location("export", EXPORT)
X = importlib.util.module_from_spec(spec)
spec.loader.exec_module(X)
SCR = os.path.join(os.environ.get("RBD_SCRATCH") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "rbd"), "muse-t")


def put(path, text):
    with open(path, "w") as f:
        f.write(text)


def jload(path):
    with open(path) as f:
        return json.load(f)


SPEC = jload(os.path.join(KIT, "repo/maze/spec.json"))["services"]


def rec(pt, payload, stream=None):
    return json.dumps({"schema_version": 1, "stream": stream or {"kind": "run", "id": "r"}, "payload_type": pt,
                       "payload": payload})


def task(tid, kind, stages=("proposed", "accepted", "started", "completed"), extra=None):
    out = []
    for st in stages:
        p = {"event": {"kind": st, "task_id": tid, "task_kind": kind} if st == "proposed" else {"kind": st}, "task_id": tid}
        p.update((extra or {}).get(st, {}))
        out.append(rec("task.lifecycle." + st, p))
    return out


class Base(unittest.TestCase):
    def setUp(self):
        os.makedirs(SCR, exist_ok=True)
        self.d = tempfile.mkdtemp(dir=SCR, prefix="u.")

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)


class Events(Base):
    def lines(self):
        ev = [rec("run.model.configured", {"tools": ["mcp__rhobound__predict", "mcp__rhobound__context"]}),
              rec("session.run.linked", {"session": {"kind": "session", "id": "01a19dfb-cc5a-7453-8326-56e6687e7842"}},
                  {"kind": "session", "id": "01a19dfb-cc5a-7453-8326-56e6687e7842"})]
        ev += task("m1", "model.meta.response", extra={"completed": {"x": "calls mcp__rhobound__predict"}})
        ev += task("m2", "model.meta.response", stages=("proposed", "rejected"))
        ev += task("r1", "tool.read_file", extra={"output": {"text": "mcp__rhobound__budget"}})
        ev += task("c1", "tool.mcp__rhobound__context")
        ev += task("c2", "tool.mcp", extra={"started": {"name": "mcp__rhobound__predict"}})
        ev += task("c3", "tool.mcp")
        ev += task("rem", "reminder.agent.goal-reminder")
        ev += [rec("run.output.delta", {"delta": "Hello "}), rec("run.output.delta", {"text": "world"}),
               rec("run.usage", {"models": {"m": {"input_tokens": 10, "cached_input_tokens": 3, "output_tokens": 4,
                                                  "reasoning_tokens": 2}}}),
               rec("run.terminal.completed", {"status": "completed"}), "garbage", "[1,2]"]
        return "\n".join(ev)

    def test_counts(self):
        E = X.parse_events(self.lines())
        self.assertEqual(E["model_steps"], 2)
        self.assertEqual(E["model_steps_completed"], 1)
        self.assertEqual(E["bad_lines"], 2)
        self.assertEqual(E["tool_calls_by_kind"]["tool.read_file"], 1)
        self.assertEqual(E["tasks_by_kind"]["model.meta.response"], {"proposed": 2, "accepted": 1, "started": 1,
                                                                     "completed": 1, "rejected": 1})
        self.assertEqual(E["tokens"], {"input": 10, "output": 4, "cached": 3, "reasoning": 2, "total": None})
        self.assertEqual(E["final_text"], "Hello world")
        self.assertEqual(E["sessions"][0], "01a19dfb-cc5a-7453-8326-56e6687e7842")
        self.assertEqual(E["terminal"]["type"], "run.terminal.completed")

    def test_mcp_calls_only_tool_tasks(self):
        E = X.parse_events(self.lines())
        self.assertEqual([c["tool"] for c in E["mcp_calls"]], ["context", "predict", "mcp"])   # not the model's, not output
        self.assertEqual(E["mcp_offered"], ["context", "predict"])
        self.assertTrue(all(X.PLAIN.fullmatch(c["tool"]) for c in E["mcp_calls"]))

    def test_events_subcommand(self):
        p = os.path.join(self.d, "events.jsonl")
        put(p, self.lines())
        r = subprocess.run([sys.executable, "-I", EXPORT, "events", "--events", p], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual((d["model_steps"], [c["tool"] for c in d["mcp_calls"]]), (2, ["context", "predict", "mcp"]))

    def test_tokens_no_double_count(self):
        t = X.tokens_of({"per_model": {"a": {"input_tokens": 5, "output_tokens": 1}},
                         "totals": {"input_tokens": 5, "output_tokens": 1, "total_tokens": 6}})
        self.assertEqual((t["input"], t["output"], t["total"]), (5, 1, 6))
        self.assertEqual(X.tokens_of({"n": 3})["input"], None)

    def test_hooks(self):
        def h(ev, kind, **kw):
            e = {"event": ev, "kind": kind, "hook_key": "plugin:rhobound:x", "origin": {"plugin_id": "rhobound"}}
            e.update(kw)
            return json.dumps({"payload_type": "runtime.session", "payload": {"event": e}})
        data = "\n".join([h("SessionStart", "hook_run_started"), h("SessionStart", "hook_run_terminal", exit_code=0),
                          h("Stop", "hook_run_terminal", exit_code=2, effects=["blocked"], duration_ms=16),
                          h("Stop", "hook_run_terminal", exit_code=0), "nope",
                          json.dumps({"payload_type": "runtime.mcp_tool_identity_catalog", "payload": {"entries": [
                              {"canonical_id": "mcp__rhobound__predict"}, {"canonical_id": "mcp__rhobound__budget"},
                              {"canonical_id": "mcp__other__x"}, {"canonical_id": "mcp__rhobound__a b"}, 7]}})])
        H = X.parse_hooks(data)
        self.assertEqual(H["mcp_offered"], ["budget", "predict"])   # the session log carries the catalog, --json does not
        self.assertEqual(H["stop_blocked"], 1)
        self.assertEqual(H["summary"]["Stop"]["exit_codes"], [2, 0])
        self.assertEqual(H["summary"]["SessionStart"]["started"], 1)
        self.assertEqual(len(H["records"]), 3)


class Text(unittest.TestCase):
    def test_clean(self):
        s = X.clean("ip 100.64.7.9 and 10.1.2.3, acct 123456789012 [skip ci] \x07bell", 500)
        self.assertNotIn("100.64.7.9", s)
        self.assertNotIn("123456789012", s)
        self.assertNotIn("skip ci", s)
        self.assertTrue(s.isprintable())

    def test_leaks(self):
        self.assertTrue(X.leaks("x := \"100.64.7.9\""))
        self.assertTrue(X.leaks("const id = 123456789012"))
        self.assertFalse(X.leaks("addr := \"10.0.0.1\" // 127.0.0.1"))


class Services(unittest.TestCase):
    def test_v1(self):
        self.assertEqual(X.service_of(SPEC, {"services": ["catalog"]}, []), ("catalog", ["catalog"], None))

    def test_v2_shared_image(self):
        svc, svcs, err = X.service_of(SPEC, {"services": ["audit"]}, [])
        self.assertEqual((svc, svcs, err), ("audit", ["audit", "events"], None))

    def test_too_many_on_image(self):
        svc, svcs, err = X.service_of(SPEC, {"services": ["index-a"]}, [])
        self.assertIsNone(svcs)
        self.assertIn("at most 3", err)

    def test_derived(self):
        self.assertEqual(X.service_of(SPEC, None, ["maze/app/internal/svc/pricing/pricing.go"])[:2], ("pricing", ["pricing"]))
        self.assertEqual(X.service_of(SPEC, {}, ["maze/app/cmd/notify/main.go"])[:2], ("audit", ["audit", "events"]))
        self.assertIn("cannot tell", X.service_of(SPEC, None, ["maze/app/internal/rt/rt.go"])[2])
        self.assertIn("cannot tell", X.service_of(SPEC, None, ["maze/app/internal/svc/pricing/p.go",
                                                               "maze/app/internal/svc/catalog/c.go"])[2])


class Scan(Base):
    def test_no_links_followed(self):
        os.makedirs(os.path.join(self.d, "outside"))
        put(os.path.join(self.d, "outside/secret.go"), "package x // secret\n")
        ws = os.path.join(self.d, "ws")
        os.makedirs(os.path.join(ws, "maze/app/internal/svc"))
        os.symlink(os.path.join(self.d, "outside"), os.path.join(ws, "maze/app/internal/svc/catalog"))
        os.symlink(os.path.join(self.d, "outside/secret.go"), os.path.join(ws, "maze/app/x.go"))
        os.mkfifo(os.path.join(ws, "maze/app/fifo.go"))
        put(os.path.join(ws, "maze/app/a.go"), "package app\n")
        os.link(os.path.join(ws, "maze/app/a.go"), os.path.join(ws, "maze/app/b.go"))
        t0 = time.time()
        t = X.scan(ws, keep=lambda r: r.endswith(".go"))
        self.assertLess(time.time() - t0, 5)
        self.assertEqual(sorted(t.links), ["maze/app/internal/svc/catalog", "maze/app/x.go"])
        self.assertEqual(sorted(t.special), ["maze/app/a.go", "maze/app/b.go", "maze/app/fifo.go"])   # two links: neither read
        self.assertEqual(t.files, {})

    def test_link_above(self):
        real = os.path.join(self.d, "real")
        os.makedirs(os.path.join(real, "maze"))
        os.symlink(real, os.path.join(self.d, "ws"))
        with self.assertRaises(OSError):
            X.scan(os.path.join(self.d, "ws"))
        self.assertIsNone(X.read_path(os.path.join(self.d, "ws/maze/../maze"), 10))


class Prompt(Base):
    def run_prompt(self, *args):
        return subprocess.run([sys.executable, "-I", EXPORT, "prompt"] + list(args), capture_output=True, text=True)

    def test_prompt(self):
        tm = os.path.join(self.d, "task.md")
        put(tm, "Title: x\n\nDo it.\n")
        fb = os.path.join(self.d, "fb.md")
        put(fb, "gate: block\x00 rules: a\n")
        r1 = self.run_prompt("--task", tm)
        self.assertEqual((r1.returncode, r1.stdout), (0, "Title: x\n\nDo it.\n"))
        r2 = self.run_prompt("--task", tm, "--iter", "2", "--feedback", fb)
        self.assertEqual(r2.returncode, 0)
        self.assertEqual(r2.stdout, "Title: x\n\nDo it.\n\n---\n\n" + X.LEAD + "\n\ngate: block  rules: a\n")
        self.assertNotEqual(self.run_prompt("--task", tm, "--iter", "2").returncode, 0)
        self.assertNotEqual(self.run_prompt("--task", tm, "--feedback", fb).returncode, 0)
        put(fb, "y" * 40000)
        r3 = self.run_prompt("--task", tm, "--iter", "3", "--feedback", fb)
        self.assertIn("[the feedback was cut at 32000 bytes]", r3.stdout)
        os.symlink(fb, os.path.join(self.d, "fbl"))
        self.assertNotEqual(self.run_prompt("--task", tm, "--iter", "2", "--feedback", os.path.join(self.d, "fbl")).returncode, 0)


class HiddenSummary(Base):
    def summ(self, lines, rc, tests=("TestA", "TestB")):
        j = os.path.join(self.d, "t.json")
        put(j, "\n".join(json.dumps(x) if not isinstance(x, str) else x for x in lines) + "\n")
        c = os.path.join(self.d, "c.json")
        put(c, json.dumps({"packages": ["./internal/svc/catalog"], "tests": list(tests), "overwrote": []}))
        o = os.path.join(self.d, "h.json")
        r = subprocess.run([sys.executable, "-I", EXPORT, "hidden-summary", "--json", j, "--rc", str(rc), "--out", o,
                            "--copy", c, "--run", "r", "--iter", "1", "--ticket", "T9", "--arm", "R", "--verify-rc", "0",
                            "--strip", "/x/src/"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        h = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(h, jload(o))
        return h

    def ev(self, act, test=None, out=None):
        e = {"Action": act, "Package": "maze/internal/svc/catalog"}
        if test:
            e["Test"] = test
        if out:
            e["Output"] = out
        return e

    def test_pass(self):
        h = self.summ([self.ev("run", "TestA"), self.ev("pass", "TestA"), self.ev("pass", "TestB"), self.ev("pass")], 0)
        self.assertTrue(h["pass"])
        self.assertEqual((h["passed"], h["failed"], h["error"], h["modcache_verified"]), (2, [], None, True))

    def test_fail(self):
        h = self.summ([self.ev("output", "TestA", "/x/src/maze/app/a_test.go:9: bad\n"), self.ev("fail", "TestA"),
                       self.ev("pass", "TestB"), self.ev("fail")], 1)
        self.assertFalse(h["pass"])
        self.assertEqual(h["failed"], ["TestA"])
        self.assertIsNone(h["error"])
        self.assertIn("<copy>maze/app/a_test.go:9: bad", h["output_tail"])

    def test_build_fail(self):
        h = self.summ([self.ev("build-output", None, "x.go:3: undefined: Hello\n"), self.ev("build-fail"),
                       self.ev("output", None, "FAIL\tmaze/internal/svc/catalog [build failed]\n"), self.ev("fail")], 1)
        self.assertFalse(h["pass"])
        self.assertTrue(h["build_failed"])
        self.assertIsNone(h["error"])

    def test_none_ran(self):
        h = self.summ([self.ev("pass", "TestOther"), self.ev("pass")], 0)
        self.assertFalse(h["pass"])
        self.assertIn("did not run", h["error"])
        self.assertEqual(h["missing"], ["TestA", "TestB"])

    def test_timeout(self):
        h = self.summ([self.ev("pass", "TestA")], 124)
        self.assertFalse(h["pass"])
        self.assertEqual(h["error"], "go test timed out")


if __name__ == "__main__":
    unittest.main(verbosity=1)
