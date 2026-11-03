#!/usr/bin/env python3
"""Offline tests of verify/regress.py on synthetic maze-load windows (the maze bed's 5-entry format, and the older
storefront/checkout format of verify/tests/fixtures). regress.py runs as python3 -I in a subprocess, as on the day.
usage: python3 -I test_regress.py [-v]   (scratch under VERIFY_SCRATCH [$RBD_SCRATCH/verify])"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
V = os.path.dirname(os.path.dirname(HERE))
REGRESS = os.path.join(V, "regress.py")
OLD_FIX = os.path.join(V, "tests", "fixtures", "rs2-base-poisson100-r1.load.json")
SCRATCH = os.environ.get("VERIFY_SCRATCH") or os.path.join(os.environ.get("RBD_SCRATCH") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "rbd"), "verify")
BASE = {"web": 59.2, "mobile": 74.1, "search-api": 60.1, "checkout": 94.4, "partner": 58.2}
PATHS = {"web": "browse", "mobile": "feed", "search-api": "q", "checkout": "buy", "partner": "bulk"}
OK = {"web": 15000, "mobile": 9000, "search-api": 4500, "checkout": 4500, "partner": 3000}
SETTING = {"schema": "rbd.load/v1", "source": "default", "rps": 120.0, "mix": "browse=50.0,feed=30.0,q=15.0,buy=15.0,bulk=10.0",
           "shares": {"browse": 0.416667, "feed": 0.25, "q": 0.125, "buy": 0.125, "bulk": 0.083333},
           "summary": "120 rps (default): browse 50, feed 30, q 15, buy 15, bulk 10"}


def window(path, shift=None, ok=None, err=None, done=True, rps=120.0, setting=SETTING, entries=None, secs=300, extra=()):
    shift, ok, err = shift or {}, dict(OK, **(ok or {})), err or {}
    ents = entries or list(BASE)
    n = sum(ok[e] + err.get(e, 0) for e in ents)
    lines = [f"2026/11/02 09:00:00 maze-load: {n} requests over {secs} s ({rps} rps), seed 7"]
    for e in ents:
        m = BASE[e] + shift.get(e, 0.0) if ok[e] else 0.0
        lines.append(json.dumps({"errors": err.get(e, 0), "mean_ms": m, "ok": ok[e], "p50_ms": 1, "p95_ms": 2, "p99_ms": 3,
                                 "url": f"http://{e}:8080/{PATHS[e]}"}))
        if done and e == ents[-2 if len(ents) > 1 else -1]:   # as maze-load: the done line before the last result line
            lines.append(f"2026/11/02 09:05:00 maze-load: done in {secs} s")
    lines += list(extra)
    if setting is not None:
        lines.append(json.dumps(setting))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


class Regress(unittest.TestCase):
    def setUp(self):
        os.makedirs(SCRATCH, exist_ok=True)
        self.d = tempfile.mkdtemp(prefix="rg-", dir=SCRATCH)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def run_dir(self, name, b0=None, c=None):
        d = os.path.join(self.d, name)
        os.makedirs(d)
        window(os.path.join(d, "b0.load.json"), **(b0 or {}))
        window(os.path.join(d, "c.load.json"), **(c or {}))
        return d

    def rg(self, *args):
        p = subprocess.run([sys.executable, "-I", REGRESS, *args], capture_output=True, text=True, timeout=60)
        doc = json.loads(p.stdout) if p.stdout.strip() else None
        return p.returncode, doc, p.stderr

    def entry(self, doc, e):
        return next(r for r in doc["entries"] if r["entry"] == e)

    def test_clean(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"shift": {"web": 0.3, "partner": -0.5}}))
        self.assertEqual(rc, 0)
        self.assertEqual(doc["schema"], "rbd.regress/v1")
        self.assertFalse(doc["regressed"])
        self.assertTrue(doc["production_ok"])
        self.assertEqual(doc["worst"]["entry"], "web")
        self.assertAlmostEqual(self.entry(doc, "web")["change_ms"], 0.3, places=6)
        self.assertEqual(doc["n"], 1)
        self.assertEqual(doc["se_ms"], 2.0)
        self.assertEqual(sorted(r["entry"] for r in doc["entries"]), sorted(BASE))
        self.assertEqual(doc["threshold_ms"], 4.0)
        self.assertEqual(doc["warnings"], [])

    def test_regressed_within_noise(self):
        rc, doc, err = self.rg(self.run_dir("r", c={"shift": {"search-api": 5.0}}))
        self.assertEqual(rc, 1)
        self.assertTrue(doc["regressed"])
        self.assertFalse(doc["regressed_resolved"])   # 5 - 4 < 2 ms noise
        self.assertEqual(doc["worst"]["entry"], "search-api")
        self.assertTrue(doc["worst"]["over"])
        self.assertFalse(doc["worst"]["resolved"])
        self.assertIn("search-api", doc["unresolved"])
        self.assertIn("REGRESSED", err)

    def test_regressed_beyond_noise(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"shift": {"checkout": 7.0, "web": 4.5}}))
        self.assertEqual(rc, 1)
        self.assertTrue(doc["regressed_resolved"])
        self.assertEqual(doc["worst"]["entry"], "checkout")
        self.assertAlmostEqual(doc["worst"]["margin_ms"], 3.0, places=6)
        self.assertTrue(self.entry(doc, "web")["over"])

    def test_just_under_threshold(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"shift": {"web": 3.9}}))
        self.assertEqual(rc, 0)
        self.assertFalse(doc["regressed"])
        self.assertEqual(doc["unresolved"], ["web"])

    def test_threshold_override(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"shift": {"web": 1.5}}), "--threshold", "1.0", "--noise", "0.25")
        self.assertEqual(rc, 1)
        self.assertTrue(doc["regressed_resolved"])
        self.assertEqual(doc["noise_ms"], 0.25)

    def test_two_pairs(self):
        a = self.run_dir("a", c={"shift": {"web": 5.0}})
        b = self.run_dir("b", c={"shift": {"web": 3.0}})
        rc, doc, _ = self.rg(a, b)
        self.assertEqual(rc, 0)   # mean +4.0 is not over 4.0
        w = self.entry(doc, "web")
        self.assertAlmostEqual(w["change_ms"], 4.0, places=6)
        self.assertEqual(w["changes_ms"], [5.0, 3.0])
        self.assertAlmostEqual(w["se_ms"], 2.0 / 2 ** 0.5, places=3)
        self.assertAlmostEqual(w["sd_ms"], 2 ** 0.5, places=3)
        self.assertEqual(doc["n"], 2)
        self.assertEqual(len(doc["pairs"]), 2)

    def test_b0_c_flags(self):
        b = window(os.path.join(self.d, "x.json"))
        c = window(os.path.join(self.d, "y.json"), shift={"mobile": 6.5})
        rc, doc, _ = self.rg("--b0", b, "--c", c)
        self.assertEqual(rc, 1)
        self.assertEqual(doc["worst"]["entry"], "mobile")
        self.assertEqual(doc["pairs"][0]["label"], "pair 1")

    def test_errors_up(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"err": {"web": 400}}))   # 400 / 15400 = 2.6 points
        self.assertEqual(rc, 1)
        self.assertFalse(doc["regressed"])
        self.assertEqual(doc["errors_up"], ["web"])
        self.assertFalse(doc["production_ok"])
        rc, doc, _ = self.rg(self.run_dir("s", c={"err": {"web": 50}}))   # 0.3 points: not counted
        self.assertEqual(rc, 0)
        self.assertEqual(doc["errors_up"], [])
        self.assertEqual(self.entry(doc, "web")["c_errors"], 50)

    def test_broken_entry_is_not_a_speedup(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"ok": {"partner": 0}, "err": {"partner": 3000}}))
        self.assertEqual(rc, 1)
        p = self.entry(doc, "partner")
        self.assertTrue(p["broken"])
        self.assertIsNone(p["change_ms"])
        self.assertEqual(doc["errors_up"], ["partner"])
        self.assertNotEqual(doc["worst"]["entry"], "partner")

    def test_policy(self):
        pol = os.path.join(self.d, "gate.json")
        with open(pol, "w") as f:
            json.dump({"schema": "rhobound.policy/v1", "max_entry_mean_change_ms": 4.0, "max_entry_mean_change_pct": 5.0}, f)
        rc, doc, _ = self.rg(self.run_dir("r", c={"shift": {"partner": 3.5}}), "--policy", pol)
        self.assertEqual(rc, 1)   # 5 % of 58.2 = 2.91 ms < 4 ms
        self.assertAlmostEqual(self.entry(doc, "partner")["threshold_ms"], 2.91, places=3)
        self.assertEqual(doc["worst"]["entry"], "partner")
        with open(pol, "w") as f:
            json.dump({"schema": "rhobound.policy/v1", "max_entry_mean_change_ms": 4.0}, f)
        rc, doc, _ = self.rg(self.run_dir("s", c={"shift": {"partner": 3.5}}), "--policy", pol)
        self.assertEqual(rc, 0)
        bed = os.path.join(os.path.dirname(V), "repo", "policy", "gate.json")
        if os.path.exists(bed):
            rc, doc, _ = self.rg(self.run_dir("t"), "--policy", bed)
            self.assertEqual((rc, doc["threshold_ms"], doc["threshold_pct"]), (0, 4.0, None))

    def test_old_format_several_urls_per_entry(self):
        rc, doc, _ = self.rg("--b0", OLD_FIX, "--c", OLD_FIX)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(r["entry"] for r in doc["entries"]), ["checkout", "storefront"])
        co = self.entry(doc, "checkout")
        self.assertEqual(co["urls"], ["/buy/card", "/buy/wallet"])
        self.assertAlmostEqual(co["b0_mean_ms"], (88.7681138135674 * 10776 + 89.0616931737338 * 7287) / 18063, places=3)
        self.assertEqual(co["change_ms"], 0.0)
        self.assertTrue(any("no rbd.load/v1 line" in w for w in doc["warnings"]))

    def test_out_file(self):
        out = os.path.join(self.d, "regress.json")
        rc, doc, _ = self.rg(self.run_dir("r"), "--out", out)
        self.assertEqual(rc, 0)
        with open(out) as f:
            self.assertEqual(json.load(f), doc)

    def assertCannot(self, *args, why=""):
        rc, doc, err = self.rg(*args)
        self.assertEqual(rc, 2, err)
        self.assertIn("error", doc)
        self.assertIn(why, doc["error"])

    def test_cannot_judge(self):
        self.assertCannot(self.run_dir("a", c={"rps": 100.0}), why="different load settings")
        self.assertCannot(self.run_dir("b", c={"setting": dict(SETTING, shares={"browse": 1.0})}), why="load mix")
        self.assertCannot(self.run_dir("c", c={"done": False}), why="did not finish")
        self.assertCannot(self.run_dir("d", c={"entries": ["web", "mobile"]}), why="entries")
        self.assertCannot(self.run_dir("e", b0={"ok": {"web": 0}, "err": {"web": 10}}), why="before the change")
        self.assertCannot(self.run_dir("f", c={"extra": ['{"url":"http://web:8080/browse2","ok":"x","errors":0,"mean_ms":1}']}),
                          why="not numbers")
        self.assertCannot(self.run_dir("g", c={"extra": ['{"url":"http://web:8080/browse","ok":1,"errors":0,"mean_ms":1}']}),
                          why="two result lines")
        self.assertCannot(os.path.join(self.d, "nosuch"), why="nosuch")
        self.assertCannot(why="no run")
        b = window(os.path.join(self.d, "x.json"))
        self.assertCannot("--b0", b, why="pairs")
        self.assertCannot(self.run_dir("h"), "--threshold", "0", why="positive")
        self.assertCannot(self.run_dir("i"), "--threshold", "nan", why="positive")
        pol = os.path.join(self.d, "p.json")
        with open(pol, "w") as f:
            json.dump({"schema": "rhobound.policy/v1"}, f)
        self.assertCannot(self.run_dir("j"), "--policy", pol, why="max_entry_mean_change_ms")
        self.assertCannot(self.run_dir("k"), "--policy", pol, "--threshold", "3", why="not both")
        a, b2 = self.run_dir("l"), self.run_dir("m", b0={"entries": ["web"]}, c={"entries": ["web"]})
        self.assertCannot(a, b2, why="the first pair's")
        rc, _, _ = self.rg("--bogus")
        self.assertEqual(rc, 2)

    def test_window_lengths_differ_warns(self):
        rc, doc, _ = self.rg(self.run_dir("r", c={"secs": 600}))
        self.assertEqual(rc, 0)
        self.assertTrue(any("windows of 300 s (B0) and 600 s (C)" in w for w in doc["warnings"]))


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[sys.argv[0]])
