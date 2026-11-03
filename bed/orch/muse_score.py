"""muse_score.py: the scoreboard of the Muse Code experiment (reports/muse-live/DECLARE.md), per ticket and arm, from the
timelines orch/muse_arm.sh writes (state/muse/TICKET-ARM/timeline.json). Run it as  python3 -I orch/muse_score.py
[--state DIR (state/muse)] [--out DIR (the same)]  ->  DIR/SCORE.json and DIR/SCORE.md (the Markdown is also printed).

Per ticket and arm:
  lead time        wall time from the arm's start to the end of the accepted deploy's measurement (the C window's end,
                   truth.json times.c_end); also without the B0 windows of every bracket up to it (measurement overhead a
                   real deploy would not have) and, separately, the cluster-lock queue in front of the brackets (arm C's
                   bracket queues behind its own counterfactual gate's A/B: CI work arm C is not meant to pay)
  iterations, outcome per iteration, agent time (the task.sh phases), CI time (arm R: PR open -> verdict; arm C: PR open ->
  image built), checks time (agent_take, hidden tests, PR), measure time, deploys, regressions that reached production
  (count, latency as DECLARE.md defines it; exposure = minutes production ran the candidate x ms of the worst entry over
  its threshold; error-rate increases counted apart, as errors_up_deploys), rollbacks (deploys
  rolled back because they regressed; every bracket also rolls back after its C window, by protocol), gate verdicts (arm R:
  real; arm C: the counterfactual CI computed anyway), hidden-test results, agent steps, tool calls and tokens, rhobound MCP
  calls and Stop reminders (arm R), and for arm C each counterfactual verdict against the measured truth.
Every timeline is read as data (it holds agent-derived text); missing pieces read as unknown ('-'), so a run cut short
still scores. Written files are redacted (public IPv4 addresses, 12-digit numbers).
"""
import argparse
import calendar
import ipaddress
import json
import os
import re
import stat
import sys
import time

_OK = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "0.0.0.0/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                         "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
_IP = re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])(?!\.[0-9])")
_N12 = re.compile(r"(?<![0-9A-Za-z_])(?<![0-9]\.)[0-9]{12}(?![0-9A-Za-z_])(?!\.[0-9])")


def _ipsub(m):
    try:
        a = ipaddress.ip_address(m.group())
    except ValueError:
        return m.group()
    return m.group() if any(a in n for n in _OK) else "<ip>"


def red(s):
    return _N12.sub("<n12>", _IP.sub(_ipsub, s))


def redact(o):
    if isinstance(o, str):
        return red(o)
    if isinstance(o, list):
        return [redact(x) for x in o]
    if isinstance(o, dict):
        return {red(str(k)): redact(v) for k, v in o.items()}
    if isinstance(o, int) and not isinstance(o, bool) and len(str(abs(o))) == 12:
        return "<n12>"
    return o


def ts(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def secs(a, b):
    x, y = ts(a), ts(b)
    return None if x is None or y is None else y - x


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def jload(path, cap=64_000_000):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > cap:
        return None
    try:
        return json.loads(open(path, "rb").read().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def total(xs):
    xs = [x for x in xs if num(x) is not None]
    return sum(xs) if xs else None


def plain(s, cap=80):
    s = "".join(c if c.isprintable() else "?" for c in str(s))
    return s if len(s) <= cap else s[: cap - 3] + "..."


def classify(verdict, measured):
    """arm C: what the gate CI computed anyway, read against the measured production truth"""
    if verdict in (None, "pending"):
        return "pending"
    if measured in ("not deployed", "deployed, unmeasured"):
        return "no truth (%s)" % measured
    if verdict == "error":
        return "no verdict (CI error)"
    if measured in ("regressed", "errors up"):
        return "right: held a regression" if verdict != "pass" else "WRONG PASS: passed a regression"
    return "right: passed a clean change" if verdict == "pass" else "false hold: held a clean change"


def score_arm(tl):
    arm, its, phases = tl.get("arm"), [i for i in tl.get("iterations") or [] if isinstance(i, dict)], \
        [p for p in tl.get("phases") or [] if isinstance(p, dict)]
    thr = num(tl.get("threshold_ms"))

    def psum(name, upto=None):
        return total([p.get("seconds") for p in phases if p.get("phase") == name and (upto is None or (num(p.get("iter")) or 0) <= upto)])

    acc = tl.get("accepted_iteration") if isinstance(tl.get("accepted_iteration"), int) else None
    a = {"ticket": tl.get("ticket"), "arm": arm, "tag": tl.get("tag") or None, "status": tl.get("status"), "exit": tl.get("exit"),
         "started_at": tl.get("started_at"), "ended_at": tl.get("ended_at"), "threshold_ms": thr,
         "iterations": len(its), "max_iter": tl.get("max_iter"), "accepted": acc is not None, "accepted_iteration": acc,
         "elapsed_s": secs(tl.get("started_at"), tl.get("ended_at") or tl.get("updated_at"))}
    # lead time: start -> the end of the accepted deploy's C window
    lead = lead_b0 = None
    if acc is not None and acc <= len(its):
        m = its[acc - 1].get("measure") or {}
        end = (m.get("times") or {}).get("c_end")
        if end is None:
            end = next((p.get("ended_at") for p in phases if p.get("phase") == "measure" and p.get("iter") == acc), None)
        lead = secs(tl.get("started_at"), end)
        b0 = total([(i.get("measure") or {}).get("b0_window_s") for i in its[:acc]])
        lead_b0 = None if lead is None else lead - (b0 or 0)
    a.update(lead_time_s=lead, lead_time_minus_b0_s=lead_b0,
             b0_windows_s=total([(i.get("measure") or {}).get("b0_window_s") for i in its]),
             lock_wait_s=total([(i.get("measure") or {}).get("lock_wait_s") for i in its]),
             agent_time_s=psum("agent"), ci_time_s=psum("gate") if arm == "R" else psum("build"),
             checks_time_s=total([psum("take"), psum("hidden"), psum("pr")]), measure_time_s=psum("measure"))
    if lead is not None:
        q = total([(i.get("measure") or {}).get("lock_wait_s") for i in its[:acc]])
        a["lead_time_minus_b0_and_queue_s"] = lead_b0 - (q or 0)
    else:
        a["lead_time_minus_b0_and_queue_s"] = None
    # gate CI runs (arm R: on the critical path; arm C: the counterfactual, beside it)
    g_runs = []
    for i in its:
        g = i.get("gate") if arm == "R" else i.get("counterfactual")
        if isinstance(g, dict):
            g_runs.append(secs(g.get("gate_started"), g.get("gate_ended")))
    a["gate_run_s"] = total(g_runs)
    # deploys, regressions, exposure
    deployed = [i for i in its if i.get("deployed") is True]   # a bracket whose rollback failed counts, unmeasured
    reg = [i for i in deployed if isinstance(i.get("measure"), dict) and i["measure"].get("regressed") is True]
    a.update(deploys=len(deployed), regressions=len(reg), rollbacks=len(reg),
             exposure_ms_min=round(sum(num(i["measure"].get("exposure_ms_min")) or 0.0 for i in reg), 3),
             in_production_min=total([(i.get("measure") or {}).get("in_production_min") for i in deployed]),
             noisy_deploys=sum(1 for i in deployed if (i.get("measure") or {}).get("noisy_band")),
             unmeasured_deploys=sum(1 for i in deployed if not isinstance(i.get("measure"), dict)),
             errors_up_deploys=sum(1 for i in deployed if (i.get("measure") or {}).get("errors_up")))
    a["wrong_passes"] = len([i for i in reg if (i.get("gate") or {}).get("verdict") == "pass"]) if arm == "R" else None
    # per iteration
    rows = []
    for i in its:
        m = i.get("measure") if isinstance(i.get("measure"), dict) else {}
        h = i.get("hidden") if isinstance(i.get("hidden"), dict) else {}
        g = i.get("gate") if isinstance(i.get("gate"), dict) else None
        cf = i.get("counterfactual") if isinstance(i.get("counterfactual"), dict) else None
        ag = i.get("agent") if isinstance(i.get("agent"), dict) else {}
        measured = "not deployed"
        if i.get("deployed") is True:
            measured = ("regressed" if m.get("regressed") is True else "errors up" if m.get("errors_up") else "clean") \
                if m else "deployed, unmeasured"
        hid = None if not h else ("pass" if h.get("rc") == 0 else "fail" if h.get("rc") == 1 else "error")
        row = {"iter": i.get("iter"), "run": i.get("run"), "change": i.get("change"), "pr": i.get("pr"), "head": i.get("head"),
               "outcome": i.get("outcome"), "feedback_kind": i.get("feedback_kind"), "hidden": hid,
               "verdict": (g or {}).get("verdict"), "rule": (g or {}).get("rule"),
               "counterfactual": (cf or {}).get("verdict") if arm == "C" else None,
               "counterfactual_rule": (cf or {}).get("rule") if arm == "C" else None,
               "measured": measured, "worst_entry": m.get("worst_entry"), "worst_delta_ms": num(m.get("worst_delta_ms")),
               "noisy": m.get("noisy_band"), "lock_wait_s": num(m.get("lock_wait_s")),
               "exposure_ms_min": num(m.get("exposure_ms_min")) if measured == "regressed" else 0.0 if m else None,
               "agent_rc": ag.get("rc"), "steps": num(ag.get("steps")), "tool_calls": num(ag.get("tool_calls")),
               "tokens": num((ag.get("tokens") or {}).get("total")) if isinstance(ag.get("tokens"), dict) else None,
               "mcp_calls": ag.get("mcp_calls") if isinstance(ag.get("mcp_calls"), dict) else None,
               "stop_reminders": num(ag.get("stop_reminders")),
               "agent_s": total([p.get("seconds") for p in phases if p.get("phase") == "agent" and p.get("iter") == i.get("iter")])}
        if arm == "C":
            row["reading"] = classify(row["counterfactual"], measured) if row["head"] else None
        rows.append(row)
    a["per_iteration"] = rows
    a["outcomes"] = [r["outcome"] for r in rows]
    a["gate_verdicts"] = [{"iter": r["iter"], "verdict": r["verdict"] if arm == "R" else r["counterfactual"],
                           "rule": r["rule"] if arm == "R" else r["counterfactual_rule"]} for r in rows if r["head"]]
    a["hidden"] = [{"iter": r["iter"], "result": r["hidden"]} for r in rows]
    mcp = {}
    for r in rows:
        for k, v in (r["mcp_calls"] or {}).items():
            if num(v) is not None:
                mcp[k] = mcp.get(k, 0) + v
    a.update(steps=total([r["steps"] for r in rows]), tool_calls=total([r["tool_calls"] for r in rows]),
             tokens=total([r["tokens"] for r in rows]),
             mcp_calls=sum(mcp.values()) if any(r["mcp_calls"] is not None for r in rows) else None, mcp_by_tool=mcp,
             stop_reminders=total([r["stop_reminders"] for r in rows]))
    if arm == "C":
        cf = [{"iter": r["iter"], "head": r["head"], "verdict": r["counterfactual"], "rule": r["counterfactual_rule"],
               "measured": r["measured"], "worst_entry": r["worst_entry"], "worst_delta_ms": r["worst_delta_ms"],
               "noisy": r.get("noisy"), "reading": r["reading"]} for r in rows if r["head"]]
        a["counterfactual"] = cf
        a["counterfactual_summary"] = {k: sum(1 for c in cf if c["reading"] == k) for k in sorted({c["reading"] for c in cf})}
        a["counterfactual_complete"] = all(c["verdict"] not in (None, "pending") for c in cf)
    return a


def label(a):
    return plain(a["ticket"]) + (" (%s)" % plain(a["tag"]) if a.get("tag") else "")


def pick(attempts):
    """of several attempts of one ticket and arm (--tag), the latest that ran to an end (accepted or not), else the latest"""
    done = [a for a in attempts if a["status"] in ("accepted", "not_accepted")]
    return sorted(done or attempts, key=lambda a: str(a["started_at"]))[-1]


def fmt_min(s):
    return "-" if s is None else "%.1f min" % (s / 60.0)


def fmt(v, f="%s"):
    return "-" if v is None else f % v


def markdown(arms, gen):
    L = ["# Muse Code with and without rhobound: scoreboard", "",
         "Generated %s by orch/muse_score.py from state/muse/*/timeline.json. One agent sample per ticket and arm: "
         "illustrative, not a statistical comparison (DECLARE.md). Single-window noise is about +-2 ms; a worst entry "
         "between 2 and 6 ms is marked (noisy)." % gen, "",
         "## Per ticket and arm", "",
         "| ticket | arm | outcome | iterations | lead time | lead time - B0 | - lock queue | agent | CI | checks | measure "
         "| deploys | regressions | errors up | exposure (ms x min) | rollbacks | gate verdicts | hidden | steps | tool calls "
         "| tokens | MCP calls | Stop reminders |",
         "|" + "---|" * 23]
    for a in arms:
        outc = ("accepted at %d" % a["accepted_iteration"]) if a["accepted"] else plain(a["status"] or "?")
        gv = ", ".join("%s:%s" % (g["iter"], g["verdict"] or "pending") for g in a["gate_verdicts"]) or "-"
        if a["arm"] == "C" and gv != "-":
            gv = "(counterfactual) " + gv
        hid = ", ".join("%s:%s" % (h["iter"], h["result"] or "-") for h in a["hidden"]) or "-"
        mcp = "-" if a["mcp_calls"] is None else "%d (%s)" % (a["mcp_calls"], ", ".join("%s %d" % kv for kv in sorted(a["mcp_by_tool"].items())) or "none")
        L.append("| %s | %s | %s | %d/%s | %s | %s | %s | %s | %s | %s | %s | %d | %d | %d | %.1f | %d | %s | %s | %s | %s | %s | %s | %s |" % (
            label(a), a["arm"], outc, a["iterations"], fmt(a["max_iter"]), fmt_min(a["lead_time_s"]),
            fmt_min(a["lead_time_minus_b0_s"]), fmt_min(a["lead_time_minus_b0_and_queue_s"]), fmt_min(a["agent_time_s"]),
            fmt_min(a["ci_time_s"]), fmt_min(a["checks_time_s"]), fmt_min(a["measure_time_s"]), a["deploys"], a["regressions"],
            a["errors_up_deploys"], a["exposure_ms_min"], a["rollbacks"], plain(gv, 120), hid, fmt(a["steps"]), fmt(a["tool_calls"]), fmt(a["tokens"]),
            plain(mcp, 120), fmt(a["stop_reminders"]) if a["arm"] == "R" else "-"))
    L += ["", "CI is arm R's PR-open-to-verdict time and arm C's PR-open-to-image time. Lead time runs from the arm's start to "
          "the end of the accepted deploy's C window; '- B0' removes every bracket's B0 window (measurement overhead); "
          "'- lock queue' also removes the time the brackets waited for the cluster lock (arm C waits behind its own "
          "counterfactual gate's A/B). Every bracket rolls back after its C window by protocol; 'rollbacks' counts the "
          "deploys rolled back because they regressed.", "",
          "## Per iteration", "",
          "| ticket | arm | iter | change | PR | outcome | hidden | gate verdict | measured | worst entry | lock queue | exposure | steps | tokens | MCP | Stop |",
          "|" + "---|" * 16]
    for a in arms:
        for r in a["per_iteration"]:
            v = r["verdict"] if a["arm"] == "R" else r["counterfactual"]
            vr = r["rule"] if a["arm"] == "R" else r["counterfactual_rule"]
            vtxt = "-" if not r["head"] else "%s%s%s" % ("(cf) " if a["arm"] == "C" else "", v or "pending", " (%s)" % vr if vr else "")
            we = "-" if r["worst_entry"] is None else "%s %+.2f ms%s" % (plain(r["worst_entry"]), r["worst_delta_ms"], " (noisy)" if r["noisy"] else "")
            mc = "-" if r["mcp_calls"] is None else str(sum(v_ for v_ in r["mcp_calls"].values() if num(v_) is not None))
            L.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                label(a), a["arm"], fmt(r["iter"]), plain(r["change"] or "-"), fmt(r["pr"], "#%s"), plain(r["outcome"] or "-"),
                r["hidden"] or "-", plain(vtxt, 90), r["measured"], we, fmt_min(r["lock_wait_s"]),
                fmt(r["exposure_ms_min"], "%.1f"), fmt(r["steps"]), fmt(r["tokens"]), mc,
                fmt(r["stop_reminders"]) if a["arm"] == "R" else "-"))
    cfs = [(a, c) for a in arms if a["arm"] == "C" for c in a.get("counterfactual", [])]
    if cfs:
        L += ["", "## Arm C: what the gate would have said (computed by CI anyway) against the measured truth", "",
              "| ticket | iter | head | counterfactual verdict | measured | worst entry | reading |", "|" + "---|" * 7]
        for a, c in cfs:
            we = "-" if c["worst_entry"] is None else "%s %+.2f ms%s" % (plain(c["worst_entry"]), c["worst_delta_ms"],
                                                                          " (noisy)" if c.get("noisy") else "")
            rd = c["reading"]
            if c.get("noisy") and rd in ("right: passed a clean change", "false hold: held a clean change"):
                rd += " (a reading inside the noise band: no evidence either way, DECLARE.md)"
            L.append("| %s | %s | %s | %s | %s | %s | %s |" % (label(a), c["iter"], (c["head"] or "-")[:12],
                     "%s%s" % (c["verdict"] or "pending", " (%s)" % plain(c["rule"]) if c["rule"] else ""), c["measured"], we, rd))
    by_t = {}
    for a in arms:
        by_t.setdefault(a["ticket"], {}).setdefault(a["arm"], []).append(a)
    pairs = [(t, pick(d["R"]), pick(d["C"])) for t, d in sorted(by_t.items(), key=lambda kv: str(kv[0])) if "R" in d and "C" in d]
    if pairs:
        L += ["", "## R against C, per ticket (of several attempts, the latest that ran to an end)", "",
              "| ticket | accepted (R / C) | **lead time - B0 - queue, R - C** (headline) | lead time R - C | lead time - B0, R - C | regressions in production (R / C) | exposure (R / C, protocol-bound: one 300-s window per deploy) |",
              "|" + "---|" * 7]
        for t, r, c in pairs:
            d1 = None if r["lead_time_s"] is None or c["lead_time_s"] is None else r["lead_time_s"] - c["lead_time_s"]
            d2 = None if r["lead_time_minus_b0_s"] is None or c["lead_time_minus_b0_s"] is None else r["lead_time_minus_b0_s"] - c["lead_time_minus_b0_s"]
            q = "lead_time_minus_b0_and_queue_s"
            d3 = None if r.get(q) is None or c.get(q) is None else r[q] - c[q]
            L.append("| %s | %s / %s | %s | %s | %s | %d / %d | %.1f / %.1f |" % ("%s (R %s, C %s)" % (plain(t), r["tag"] or "first", c["tag"] or "first")
                     if r["tag"] or c["tag"] else plain(t), "yes" if r["accepted"] else "no",
                     "yes" if c["accepted"] else "no", "-" if d3 is None else "%+.1f min" % (d3 / 60.0),
                     "-" if d1 is None else "%+.1f min" % (d1 / 60.0),
                     "-" if d2 is None else "%+.1f min" % (d2 / 60.0), r["regressions"], c["regressions"],
                     r["exposure_ms_min"], c["exposure_ms_min"]))
    return "\n".join(red(x) for x in L) + "\n"


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state", default=os.path.join(here, "state", "muse"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    out = args.out or args.state
    arms = []
    for name in sorted(os.listdir(args.state)) if os.path.isdir(args.state) else []:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,31}", name) or not os.path.isdir(os.path.join(args.state, name)):
            continue
        tl = jload(os.path.join(args.state, name, "timeline.json"))
        if not isinstance(tl, dict) or tl.get("schema") != "rbd.muse-arm/v1" or tl.get("arm") not in ("R", "C"):
            print("muse_score: skipping %s (no rbd.muse-arm/v1 timeline)" % name, file=sys.stderr)
            continue
        arms.append(score_arm(tl))
    arms.sort(key=lambda a: (str(a["ticket"]), a["arm"], str(a["started_at"])))
    gen = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    os.makedirs(out, exist_ok=True)
    doc = {"schema": "rbd.muse-score/v1", "generated_at": gen, "arms": arms}
    for fn, body in (("SCORE.json", json.dumps(redact(doc), indent=1) + "\n"), ("SCORE.md", markdown(arms, gen))):
        tmp = os.path.join(out, "." + fn + ".tmp")
        with open(tmp, "w") as f:
            f.write(body)
        os.replace(tmp, os.path.join(out, fn))
    sys.stdout.write(markdown(arms, gen))
    if not arms:
        print("muse_score: no timelines under %s" % args.state, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
