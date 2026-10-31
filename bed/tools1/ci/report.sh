#!/bin/bash
# report: the run's summary for people (GITHUB_STEP_SUMMARY): the verdict first, the rule that decided it, each entry's
# predicted band against its threshold, the A/B delta +- SE (one line set per service: CI v2 runs one A/B per service the
# one candidate image is for, predict.json services), the digests, and how to verify the attestation by hand.
#   sudo -n -u rbd /opt/rbd/ci/report.sh RUN
# Prints the markdown, then one JSON line (the workflow appends all but the last line to the step summary). Also writes
# runs/RUN/summary.md. No account id or IP in the output: images are written as $RBD_ECR@sha256:...
# Exit 0 written, 1 failed (no verdict for RUN).
set -euo pipefail
STEP=report
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_fail() { echo "$STEP: error: $1" >&2; printf '{"step":"%s","ok":false,"error":%s}\n' "$STEP" "$(ci_jstr "$1")"; exit 1; }
[[ $# -eq 1 ]] || ci_fail "usage: report.sh RUN"
RUNID=$1
[[ $RUNID =~ ^[0-9a-f]{40}$ ]] || ci_fail "RUN must be a 40-hex commit id"

RBD_ROOT=/opt/rbd
[[ -z ${SUDO_USER:-} && -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT   # tests only; sudo's env_reset never passes it
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
[[ -n ${RBD_HOME:-} ]] || ci_fail "RBD_HOME not set by rbd-env.sh"
RUN=$RBD_HOME/runs/$RUNID
for f in candidate.json prediction.json gate/gate.json gate/verdict.txt; do
  [[ -r $RUN/$f ]] || ci_fail "no runs/$RUNID/$f: no verdict for this run"
done

python3 -I - "$RUN" "$RUNID" "${RBD_ACCOUNT:-}" <<'PY'
import json, os, re, sys
run, sha, account = sys.argv[1:4]
TYPE = "https://rhobound.dev/attestations/gate-verdict/v1"
def load(name, default=None):
    p = os.path.join(run, name)
    return json.load(open(p)) if os.path.exists(p) else default
g, cand, pred = load("gate/gate.json"), load("candidate.json"), load("prediction.json")
pr, pj = load("pr.json", {}), load("predict.json", {})
sig = load("sign.json")   # written by sign.sh only after cosign attest succeeded, for this prediction
if sig and sig.get("ledger_key") != g.get("digests", {}).get("report", "").split(":")[-1]:
    sig = None
verdict = open(os.path.join(run, "gate", "verdict.txt")).read().strip()
svc = cand["service"]
# CI v2: the services the one candidate image is for, each with its A/B folder (predict.json), else the v1 run's one
abs_ = [x for x in pj.get("services") or [] if re.fullmatch(r"ab(-[a-z]([a-z0-9-]{0,44}[a-z0-9])?)?", str(x.get("ab_dir")))]
if not abs_:
    abs_ = [{"service": s, "ab_dir": "ab" if s == svc else "ab-" + s} for s in cand.get("services") or [svc]]
svcs = [x["service"] for x in abs_]
bases = cand.get("baselines") or {svc: cand.get("baseline_digest")}
pol = g.get("policy", {})
def cell(x):
    s = str(x).replace("\n", " ").replace("|", "\\|").replace("<", "&lt;").replace(">", "&gt;")
    return s[:300]
def ms(x):
    return "%.3f" % x if isinstance(x, (int, float)) else "-"
rules = [r for r in g.get("rules", []) if r.get("evaluated")]
deciding = next((r for r in rules if r.get("effect") == verdict), None)
if verdict == "pass":
    deciding = next((r for r in rules if r.get("rule") == "mean_change"), deciding)
tok = (deciding or {}).get("rule", "")
where = (" at " + deciding["entry"]) if deciding and deciding.get("entry") else ""
L = []
adv = " (advisory)" if g.get("advisory") else ""
L.append("# rhobound gate: %s%s" % (verdict.upper(), adv))
L.append("")
jd = (g.get("judge") or {}).get("decision")
if deciding is None and verdict == "inconclusive" and jd == "escalate":   # no rule decided it: the CI judge did
    L.append("**Verdict: `%s`**, decided by the judge (%s, `%s`): every rule passed; a person reviews the change."
             % (verdict, cell((g.get("judge") or {}).get("model_id")), jd))
else:
    L.append("**Verdict: `%s`**, decided by rule %s `%s`%s." % (verdict, (deciding or {}).get("number", "?"), tok, where))
if deciding and "value" in deciding and "threshold" in deciding:
    L.append("Rule value %s against limit %s." % (ms(deciding["value"]), ms(deciding["threshold"])))
others = [r for r in rules if r.get("effect") in ("block", "inconclusive") and r is not deciding]
if others:
    L.append("Also: " + "; ".join("rule %s `%s` (%s)" % (r.get("number"), r.get("rule"), r.get("effect")) for r in others) + ".")
L.append("")
if len(svcs) == 1:
    L.append("Service `%s`, commit `%s`. Change request: %s" % (svc, sha[:12], cell(pr.get("summary", "(no pr.json)"))))
else:
    L.append("Services %s (one image for all, labelled `%s`), commit `%s`. Change request: %s" % (
        ", ".join("`%s`" % s for s in svcs), svc, sha[:12], cell(pr.get("summary", "(no pr.json)"))))
if cand.get("base"):
    L.append("")
    L.append("Go builder: base `%s` = `%s` (the kit's bases.json)." % (cell(cand["base"]), cell(cand.get("go_image"))))
L.append("")
if isinstance(pred.get("error"), dict):
    e = pred["error"]
    L.append("The prediction was refused: `%s` (%s). Fix: %s" % (e.get("code"), cell(e.get("reason", "")), cell(e.get("fix", ""))))
    L.append("")
pct, mx = pol.get("max_entry_mean_change_pct"), pol.get("max_entry_mean_change_ms")
L.append("## Entries: predicted change of mean latency (ms) against the policy threshold")
L.append("")
L.append("| entry | before | predicted change | band (with model error) | threshold | outcome |")
L.append("|---|---|---|---|---|---|")
for e in pred.get("entries", []):
    ts = [t for t in ((pct / 100.0 * e["before_ms"]) if pct is not None else None, mx) if t is not None]
    T = min(ts) if ts else None
    lo, hi = e["band_ms"]["lo"], e["band_ms"]["hi"]
    out = "-" if T is None else ("under" if hi <= T else ("over" if lo > T else "straddles"))
    L.append("| %s | %s | %s .. %s | %s .. %s | %s | %s |" % (cell(e["name"]), ms(e["before_ms"]), ms(e["change_ms"]["lo"]),
             ms(e["change_ms"]["hi"]), ms(lo), ms(hi), ms(T), out))
L.append("")
L.append("Threshold = %s%% of the entry's modelled mean%s. Mean latency only; no tails." %
         (pct, "" if mx is None else ", at most %s ms" % mx))
L.append("")
L.append("## A/B measurement (arm a = production image, arm b = candidate)")
L.append("")
for x in abs_:   # one A/B per service (CI v2: runs/RUN/ab-<service>/), each against that service's production image
    s, multi = x["service"], len(abs_) > 1
    rec = load(os.path.join(x["ab_dir"], "record", "ab-record.json"), {})
    row = next((r for r in rec.get("services", []) if r.get("service") == s), None)
    tag = " (%s, `%s/`)" % (s, x["ab_dir"]) if multi else ""
    if row:
        o = row["own_ms"]
        L.append("- %s own time per visit: %s -> %s ms, **delta %+.3f +- %.3f ms** (1 SE, %s); the prediction used delta +- 2 SE = %.3f .. %.3f ms" %
                 (s, ms(o["baseline"]), ms(o["candidate"]), o["delta"], o["se"], rec.get("se_method", "?"),
                  o["delta"] - 2 * o["se"], o["delta"] + 2 * o["se"]))
        lg = rec.get("loadgen", {})
        if lg.get("client_latency_ms"):
            c = lg["client_latency_ms"]
            L.append("- client latency%s (A/B driver): delta %+.3f +- %.3f ms over %s / %s requests" %
                     (tag, c["delta"], c["se"], lg.get("requests", {}).get("baseline"), lg.get("requests", {}).get("candidate")))
        L.append("- record findings%s: %s" % (tag, ", ".join("`%s`" % f["code"] for f in rec.get("findings", [])) or "none"))
        im = x.get("images") or (pj.get("images") if s == svc else None)
        if im:
            L.append("- image digests in the arms' spans%s: baseline %s, candidate %s" % (tag, im["baseline"], im["candidate"]))
    else:
        L.append("- no A/B record for %s in this run" % s)
L.append("")
jf = os.path.join(run, "judge", "judge.json")
if os.path.exists(jf):
    j = json.load(open(jf))
    if j.get("mode") == "advisory":
        L.append("## Judge (advisory: recorded, not part of the verdict)")
        L.append("")
        if j.get("status") == "admitted":
            L.append("- `%s`: **%s** (%s); answer `%s`, request `%s`" % (cell(j.get("model")), cell(j.get("decision")),
                     ", ".join("`%s`" % cell(r) for r in j.get("reasons") or []) or "no reason codes", cell(j.get("answer")), cell(j.get("request"))))
            try:
                com = json.load(open(os.path.join(run, "judge", "answer.json"))).get("commentary")
            except (OSError, ValueError, AttributeError):
                com = None
            if com:
                L.append("- the judge's commentary (untrusted model text): %s" % cell(com)[:300])
        else:
            L.append("- judge %s: %s" % (cell(j.get("status")), cell(j.get("why"))))
        L.append("")
L.append("## Digests")
L.append("")
dg = g.get("digests", {})
if len(abs_) == 1:
    prod = [("production image (baseline)", cand.get("baseline_digest")), ("A/B record", pj.get("record_digest"))]
else:
    prod = [kv for x in abs_ for kv in (("production image of %s (baseline)" % x["service"], bases.get(x["service"])),
                                        ("A/B record of %s" % x["service"], x.get("record_digest")))]
for k, v in [("candidate image", "$RBD_ECR@" + cand["digest"])] + prod + [
        ("fit", dg.get("fit")), ("prediction", dg.get("report")), ("policy (effective)", dg.get("policy")), ("git", sha)]:
    L.append("- %s: `%s`" % (k, v))
L.append("")
L.append("## Verify the signed verdict by hand (on rbd-tools1, as rbd)")
L.append("")
L.append("%s" % ("Signed: yes, predicate `rbd.gate-verdict/v1`, ledger key `%s`." % dg.get("report", "").split(":")[-1] if sig else
                 "NOT signed: sign.sh has not completed for this verdict (deploy.sh will refuse the image)."))
L.append("")
L.append("```bash")
L.append(". /opt/rbd/etc/rbd.env")
L.append('cosign verify-attestation --key "$RBD_KMS" --type %s \\' % TYPE)
L.append('  --insecure-ignore-tlog=true "$RBD_ECR@%s" | jq -r .payload | base64 -d | jq .predicate' % cand["digest"])
L.append("```")
L.append("")
L.append("`deploy.sh` runs the same verification and deploys only a `pass` whose baseline is still production.")
gs = os.path.join(run, "gate", "summary.md")
if os.path.exists(gs):
    L += ["", "<details><summary>the gate's own summary</summary>", "", open(gs).read().strip(), "", "</details>"]
md = "\n".join(L) + "\n"
if account:
    md = md.replace(account, "<account>")
md = md[:60000]
tmp = os.path.join(run, ".summary.md.tmp")
with open(tmp, "w") as f:
    f.write(md)
os.replace(tmp, os.path.join(run, "summary.md"))
sys.stdout.write(md)
print(json.dumps({"step": "report", "ok": True, "verdict": verdict, "rule": tok + (("@" + deciding["entry"]) if where and tok == "mean_change" else ""),
                  "service": svc, "services": svcs, "candidate_digest": cand["digest"], "git_sha": sha, "signed": bool(sig)},
                 sort_keys=True))
PY
