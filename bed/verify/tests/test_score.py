#!/usr/bin/env python3
"""Offline tests of verify/score.py: synthetic kshop-load windows + the offline proof's prediction.json/gate (copied in
fixtures/proof; block and inconclusive gates are SYNTHETIC edits of it). usage: python3 -I test_score.py [-v]"""
import copy
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE = os.path.join(os.path.dirname(HERE), "score.py")
FIX = os.path.join(HERE, "fixtures")
SCRATCH = os.environ.get("VERIFY_SCRATCH", "$HOME/rbd-dev/tmp/verify")
# the proof: storefront before 67.948 (T 3.397, band -0.611..3.016), checkout before 89.219 (T 4.461, band
# -1.094..3.498)
URLS = {"/browse": "http://storefront.kshop.svc.cluster.local:8080/browse",
        "/buy/card": "http://checkout.kshop.svc.cluster.local:8080/buy/card",
        "/buy/wallet": "http://checkout.kshop.svc.cluster.local:8080/buy/wallet"}


def jload(path):
    with open(path) as f:
        return json.load(f)


def jdump(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f)


def window(path, sf, co, seed, ok=(42000, 10800, 7200), err=(0, 0, 0), start="2026-10-31 09:00:00", done=True,
           wallet_delta=0.0):
    """A kshop-load log: storefront mean sf; checkout card co - wallet_delta*w, wallet co + ..., weighted to co."""
    n = sum(ok) + sum(err)
    card = co - wallet_delta * ok[2] / (ok[1] + ok[2])
    wallet = co + wallet_delta * ok[1] / (ok[1] + ok[2])
    rows = [("/browse", sf, ok[0], err[0]), ("/buy/card", card, ok[1], err[1]), ("/buy/wallet", wallet, ok[2], err[2])]
    lines = [f"{start.replace('-', '/')} kshop-load: {n} requests over 600 s ({n / 600:.1f} rps), seed {seed}"]
    for i, (p, m, k, e) in enumerate(rows):
        js = json.dumps({"errors": e, "mean_ms": m, "ok": k, "p50_ms": m * 0.9, "p95_ms": m * 2, "p99_ms": m * 3,
                         "url": URLS[p]}, sort_keys=True)
        lines.append(js)
        if i == 1 and done:
            lines.append(f"{start.replace('-', '/')[:11]}09:10:00 kshop-load: done in 600 s")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def shifted_pred(src, dst, d):
    p = jload(src)
    for e in p["entries"]:
        for k in ("change_ms", "band_ms", "after_ms"):
            e[k] = {"lo": e[k]["lo"] + d, "hi": e[k]["hi"] + d}
    jdump(p, dst)


def gate_dir(dst, verdict, value=None, threshold=None, txt=None, rule=None, row="10"):
    """A SYNTHETIC edit of the proof's gate: verdict, exit code, and the deciding row's effect/token/value/threshold."""
    os.makedirs(dst, exist_ok=True)
    g = jload(os.path.join(FIX, "proof", "gate", "gate.json"))
    g = copy.deepcopy(g)
    g["verdict"] = verdict
    g["exit_code"] = {"pass": 0, "block": 1, "inconclusive": 3}[verdict]
    for r in g["rules"]:
        if r["number"] == row:
            r["effect"] = verdict
            r["rule"] = rule or {"pass": "mean_change", "block": "mean_change", "inconclusive": "range_straddles"}[verdict]
            if value is not None:
                r["value"] = value
            if threshold is not None:
                r["threshold"] = threshold
    jdump(g, os.path.join(dst, "gate.json"))
    with open(os.path.join(dst, "verdict.txt"), "w") as f:
        f.write((txt or verdict) + "\n")
    return dst


class ScoreTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.makedirs(SCRATCH, exist_ok=True)
        cls.d = tempfile.mkdtemp(prefix="score-", dir=SCRATCH)
        d = cls.d
        cls.aa = [window(f"{d}/aa-1.load.json", 68.00, 88.60, 11, start="2026-10-31 08:00:00"),
                  window(f"{d}/aa-2.load.json", 68.20, 88.90, 12, start="2026-10-31 08:11:00"),
                  window(f"{d}/aa-3.load.json", 67.90, 88.70, 13, start="2026-10-31 08:22:00")]
        cls.pred = os.path.join(FIX, "proof", "prediction.json")
        cls.gpass = os.path.join(FIX, "proof", "gate")
        shifted_pred(cls.pred, f"{d}/pred-block.json", 5.0)
        shifted_pred(cls.pred, f"{d}/pred-inc.json", 1.5)
        cls.gblock = gate_dir(f"{d}/gate-block", "block", value=-0.611 + 5.0)
        cls.ginc = gate_dir(f"{d}/gate-inc", "inconclusive", value=3.016 + 1.5)
        b0 = lambda n, s: window(f"{d}/{n}-b0.load.json", 68.00, 88.70, s, start="2026-10-31 09:00:00")
        c = lambda n, sf, co, s, **k: window(f"{d}/{n}-c.load.json", 68.00 + sf, 88.70 + co, s,
                                             start="2026-10-31 09:15:00", wallet_delta=3.0, **k)
        cls.cases = {
            "right-pass": [b0("rp", 21), c("rp", 1.0, 1.2, 22), cls.pred, cls.gpass],
            "wrong-pass": [b0("wp", 23), c("wp", 5.0, 6.0, 24), cls.pred, cls.gpass],
            "right-block": [b0("rb", 25), c("rb", 6.0, 7.0, 26), f"{d}/pred-block.json", cls.gblock],
            "wrong-block": [b0("wb", 27), c("wb", 0.5, 0.4, 28), f"{d}/pred-block.json", cls.gblock],
            "inconclusive": [b0("in", 29), c("in", 2.0, 2.0, 30), f"{d}/pred-inc.json", cls.ginc],
            "unresolved": [b0("ur", 31), c("ur", 3.3, 1.0, 32), cls.pred, cls.gpass],
        }
        cls.out = f"{d}/out"
        args = [sys.executable, "-I", SCORE, "--out", cls.out, "--now", "2026-10-31T12:00:00Z", "--aa"] + cls.aa
        for name, (b, cc, p, g) in cls.cases.items():
            args += ["--change", name, b, cc, p, g]
        cls.proc = subprocess.run(args, capture_output=True, text=True)
        cls.doc = jload(f"{cls.out}/score.json")
        with open(f"{cls.out}/report.md") as f:
            cls.md = f.read()
        cls.by = {ch["name"]: ch for ch in cls.doc["changes"]}

    @classmethod
    def tearDownClass(cls):
        if os.environ.get("VERIFY_KEEP") != "1":
            shutil.rmtree(cls.d, ignore_errors=True)

    def entry(self, change, name):
        return next(e for e in self.by[change]["entries"] if e["name"] == name)

    def test_exit_and_scores(self):
        self.assertEqual(self.proc.returncode, 1, self.proc.stderr)  # failures listed (wrong pass/block)
        for name in self.cases:
            self.assertEqual(self.by[name]["score"], name, json.dumps(self.by[name], indent=1))

    def test_floor(self):
        sf = self.doc["aa"]["entries"]["storefront"]
        self.assertEqual(sf["n"], 3)
        self.assertAlmostEqual(sf["floor_ms"], 0.3, places=9)  # pairs .2 .1 .3 -> p90 nearest rank = .3
        self.assertAlmostEqual(self.doc["aa"]["entries"]["checkout"]["floor_ms"], 0.3, places=9)

    def test_threshold_is_the_gates(self):
        e = self.entry("right-pass", "storefront")
        self.assertAlmostEqual(e["threshold_ms"], 3.3973935739460526, places=9)  # gate.json rule 10
        self.assertAlmostEqual(self.entry("right-pass", "checkout")["threshold_ms"], 0.05 * 89.21882616741699,
                               places=9)
        self.assertEqual(e["threshold_key"], "max_entry_mean_change_pct")
        self.assertFalse([p for p in self.by["right-pass"]["problems"] if "rule 10" in p])

    def test_checkout_weighted_by_ok(self):
        e = self.entry("right-pass", "checkout")
        self.assertAlmostEqual(e["c_ms"], 88.70 + 1.2, places=9)  # card/wallet differ by 3 ms, ok-weighted back
        self.assertAlmostEqual(e["observed_ms"], 1.2, places=9)
        self.assertAlmostEqual(e["observed_pct"], 100 * 1.2 / 88.70, places=9)

    def test_coverage(self):
        self.assertTrue(self.entry("right-pass", "storefront")["covered"])
        self.assertFalse(self.entry("wrong-pass", "storefront")["covered"])
        self.assertTrue(self.entry("right-pass", "storefront")["in_predicted_range"])  # 1.0 in 0.93..1.36

    def test_truth_classes(self):
        self.assertEqual(self.entry("unresolved", "storefront")["truth_class"], "unresolved")  # |3.3-3.397| < .3
        self.assertEqual(self.entry("unresolved", "checkout")["truth_class"], "clean")
        self.assertEqual(self.by["inconclusive"]["truth_class"], "clean")
        self.assertEqual(self.by["wrong-pass"]["truth_class"], "regression")

    def test_failures_ranked(self):
        f = self.doc["failures"]
        self.assertEqual(f[0]["kind"], "wrong-pass")
        self.assertEqual(f[0]["change"], "wrong-pass")
        self.assertEqual(f[1]["kind"], "wrong-block")
        kinds = [x["kind"] for x in f]
        self.assertEqual(kinds, sorted(kinds, key=["wrong-pass", "wrong-block", "input", "band-miss"].index))
        self.assertIn("band-miss", kinds)

    def test_report(self):
        md = self.md
        self.assertLess(md.index("## Failures"), md.index("## Per change"))
        self.assertLess(md.index("**wrong-pass** `wrong-pass`"), md.index("**wrong-block**"))
        self.assertLess(md.index("## Per change"), md.index("## A/A floor"))
        self.assertIn("## What this cannot show", md)
        self.assertIn("One 600-s window per state", md)
        self.assertIn("n = 6 change(s)", md)
        self.assertIn("gate said inconclusive (rule 10 range_straddles at storefront", md)

    def test_decided_by(self):
        self.assertEqual(self.by["right-block"]["decided_by"]["rule"], "mean_change")
        self.assertEqual(self.by["inconclusive"]["decided_by"]["rule"], "range_straddles")
        self.assertTrue(self.by["right-pass"]["advisory"])


class ProblemsTest(unittest.TestCase):
    """Inconsistent inputs are listed, never silently scored."""

    def run_score(self, d, changes, aa):
        args = [sys.executable, "-I", SCORE, "--out", f"{d}/out"]
        if aa:
            args += ["--aa"] + aa
        for c in changes:
            args += ["--change"] + c
        p = subprocess.run(args, capture_output=True, text=True)
        return p, jload(f"{d}/out/score.json")

    def setUp(self):
        os.makedirs(SCRATCH, exist_ok=True)
        self.d = tempfile.mkdtemp(prefix="score-p-", dir=SCRATCH)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def test_mismatches(self):
        d, pred = self.d, os.path.join(FIX, "proof", "prediction.json")
        b0 = window(f"{d}/b0.json", 68.0, 88.7, 1)
        c = window(f"{d}/c.json", 69.0, 89.7, 2, done=False, err=(900, 0, 0))
        g1 = gate_dir(f"{d}/g1", "pass", threshold=3.0, txt="block")  # rule 10 T and verdict.txt both wrong
        p, doc = self.run_score(d, [["x", b0, c, pred, g1]], [])
        self.assertEqual(p.returncode, 1)
        probs = " | ".join(doc["changes"][0]["problems"])
        for want in ("differs from gate rule 10", "verdict.txt 'block' and gate.json 'pass' differ",
                     "no 'kshop-load: done' line", "storefront errors", "exit_code"):
            self.assertIn(want, probs)
        self.assertIn("no A/A pair", " | ".join(f["what"] for f in doc["failures"]))

    def test_refusal_and_missing(self):
        d = self.d
        ref = f"{d}/refused.json"
        jdump({"error": {"code": "fit.stale", "message": "x"}}, ref)
        b0 = window(f"{d}/b0.json", 68.0, 88.7, 1)
        c = window(f"{d}/c.json", 75.0, 88.7, 2)
        gi = gate_dir(f"{d}/gi", "inconclusive", rule="input_refused:fit.stale", row="1")
        aa = [window(f"{d}/a1.json", 68.0, 88.7, 3), window(f"{d}/a2.json", 68.1, 88.6, 4)]
        p, doc = self.run_score(d, [["ref", b0, c, ref, gi], ["nogate", b0, c, ref, f"{d}/nope"]], aa)
        ch = {x["name"]: x for x in doc["changes"]}
        self.assertEqual(ch["ref"]["score"], "inconclusive")
        self.assertEqual(ch["ref"]["refusal"], "fit.stale")
        self.assertEqual(ch["ref"]["decided_by"]["rule"], "input_refused:fit.stale")
        self.assertFalse([x for x in ch["ref"]["problems"] if "rule 10" in x], ch["ref"]["problems"])
        # T falls back to the policy x observed B0 when the prediction was refused: 5% of 68 = 3.4 < +7
        sf = next(e for e in ch["ref"]["entries"] if e["name"] == "storefront")
        self.assertAlmostEqual(sf["threshold_ms"], 3.4, places=9)
        self.assertEqual(ch["ref"]["truth_class"], "regression")
        self.assertEqual(ch["nogate"]["score"], "unscored")
        self.assertTrue(any("no " in x and "gate.json" in x for x in ch["nogate"]["problems"]))
        self.assertIn("fewer than 2 A/A pairs", " | ".join(doc["aa"]["problems"]))

    def test_truth_warnings_listed(self):
        d = self.d
        b0 = window(f"{d}/b0.json", 68.0, 88.7, 1)
        c = window(f"{d}/c.json", 69.0, 89.7, 2)
        t = f"{d}/truth.json"
        jdump({"schema": "rbd.truth/v1", "status": "ok", "service": "auth", "warnings": ["background load job not active"]}, t)
        p, doc = self.run_score(d, [["w", b0, c, os.path.join(FIX, "proof", "prediction.json"),
                                     os.path.join(FIX, "proof", "gate"), t]], [])
        self.assertIn("truth bracket: background load job not active", doc["changes"][0]["problems"])
        self.assertEqual(doc["changes"][0]["score"], "right-pass")

    def test_real_rs2_window_parses(self):
        """The real kshop-load log (rs2 base-poisson100-r1): JSON lines interleaved with log lines, wallet after done."""
        d = self.d
        real = os.path.join(FIX, "rs2-base-poisson100-r1.load.json")
        c = window(f"{d}/c.json", 68.21983039687669 + 1, 88.88, 8)
        p, doc = self.run_score(d, [["real", real, c, os.path.join(FIX, "proof", "prediction.json"),
                                     os.path.join(FIX, "proof", "gate")]], [real, c])
        ch = doc["changes"][0]
        sf = next(e for e in ch["entries"] if e["name"] == "storefront")
        co = next(e for e in ch["entries"] if e["name"] == "checkout")
        self.assertAlmostEqual(sf["b0_ms"], 68.21983039687669, places=9)
        want = (88.7681138135674 * 10776 + 89.0616931737338 * 7287) / (10776 + 7287)
        self.assertAlmostEqual(co["b0_ms"], want, places=9)
        self.assertEqual(ch["windows"]["b0"]["start"], "2026-10-22T05:12:45Z")
        self.assertEqual(ch["windows"]["b0"]["seed"], 7)
        self.assertFalse([x for x in ch["problems"] if x.startswith("b0 window")], ch["problems"])

    def test_load_setting_line_ignored(self):
        """capture.sh (SPEC3 F6a) appends the load setting (rbd.load/v1, no "url" key) to load.json: parsed as before."""
        d = self.d
        a = window(f"{d}/a.json", 68.0, 88.7, 5)
        b = f"{d}/b.json"
        rec = {"schema": "rbd.load/v1", "source": "load.env", "file": "/var/lib/rbd/load.env", "sha256": "sha256:" + "c" * 64,
               "rps": 121.0, "mix": "browse=91.0,card=18.0,wallet=12.0", "shares": {"browse": 0.752066},
               "rates": {"browse": 91.0}, "entries": {"storefront": 91.0, "checkout": 30.0},
               "summary": "121 rps (load.env): browse 91, card 18, wallet 12"}
        with open(a) as f, open(b, "w") as g:
            g.write(f.read() + json.dumps(rec, separators=(",", ":")) + "\n")
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location("score_under_test", SCORE)
        score = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(score)
        wa, wb = score.parse_load(a), score.parse_load(b)
        self.assertEqual({k: v for k, v in wa.items() if k != "file"}, {k: v for k, v in wb.items() if k != "file"})
        self.assertEqual(wb["problems"], [])

    def test_bundle(self):
        d = self.d
        os.makedirs(f"{d}/b/aa")
        os.makedirs(f"{d}/b/truth/c1")
        window(f"{d}/b/aa/aa-1.load.json", 68.0, 88.6, 1)
        window(f"{d}/b/aa/aa-2.load.json", 68.2, 88.8, 2)
        window(f"{d}/b/truth/c1/b0.load.json", 68.0, 88.7, 3)
        window(f"{d}/b/truth/c1/c.load.json", 69.0, 89.7, 4)
        shutil.copy(os.path.join(FIX, "proof", "prediction.json"), f"{d}/b/truth/c1/prediction.json")
        shutil.copytree(os.path.join(FIX, "proof", "gate"), f"{d}/b/truth/c1/gate")
        jdump({"schema": "rbd.truth/v1", "status": "ok", "service": "auth", "base_digest": "sha256:" + "a" * 64,
               "cand_digest": "sha256:" + "b" * 64, "keep": False}, f"{d}/b/truth/c1/truth.json")
        os.makedirs(f"{d}/b/truth/c0-failed")
        jdump({"schema": "rbd.truth/v1", "status": "failed-restored"}, f"{d}/b/truth/c0-failed/truth.json")
        p = subprocess.run([sys.executable, "-I", SCORE, "--out", f"{d}/out", "--bundle", f"{d}/b"],
                           capture_output=True, text=True)
        doc = jload(f"{d}/out/score.json")
        self.assertEqual(len(doc["changes"]), 1)
        self.assertEqual(doc["skipped"], [{"name": "c0-failed", "status": "failed-restored"}])
        with open(f"{d}/out/report.md") as f:
            self.assertIn("`c0-failed`: bracket status failed-restored, skipped", f.read())
        ch = doc["changes"][0]
        self.assertEqual((ch["name"], ch["service"], ch["score"]), ("c1", "auth", "right-pass"), ch["problems"])
        self.assertEqual(doc["aa"]["entries"]["storefront"]["n"], 1)
        self.assertEqual(json.loads(p.stdout.strip().splitlines()[-1])["step"], "score")

    def test_usage(self):
        p = subprocess.run([sys.executable, "-I", SCORE, "--out", f"{self.d}/o", "--change", "a", "b"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
