#!/usr/bin/env bash
# The CI judge inside predict.sh, offline with the REAL CLI: pr-check -> build (stubs) -> [ab.sh stand-in: the 2026-10-30
# proof record, auth +0.67 ms, a pass] -> predict.sh with JUDGE_CMD -> sign.sh (stub cosign/aws).
#   run A: tools1/judge/meta-judge.py against a stand-in Meta API: muse-wonder-1.0 is 404 for the key, muse-spark-1.3
#          answers accept   -> pass (exit 0), gate.json judge ci-judge, the request digest, the judge in the signed predicate
#   run E: a provider that answers escalate (A/A record)       -> inconclusive (exit 3), judge admitted, signed, reported
#   run M: a provider whose answer cites another packet digest -> judge refused; pass (exit 0), no judge in gate.json
#   run F: a provider that fails                               -> judge unavailable; pass (exit 0)
#   JUDGE_MODE=advisory: the judge escalates in both runs below, and the rules alone decide
#   run V: the 1 ms record                                     -> pass (exit 0), the judge recorded as advisory
#   run W: the 6 ms record                                     -> block (exit 1), signed with judge_advisory, reported
# shellcheck disable=SC2016  # test code: single-quoted programs
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== judge: predict.sh with JUDGE_CMD (real CLI), sign"
mkenv judge
S=$T/src
mkrepo "$S"
mkbaseline
FX=$HERE/fixtures
CH=$HERE/fixtures/changes
cp -r "$KIT/tools1/judge" "$TROOT/judge"
prep() { # prep NAME ITERATIONS [RECORD] -> H: c2's change with another iteration count (a distinct commit), pr-check, build,
  # the record (a run's prediction is keyed by it: two runs that share a record share one write-once ledger row)
  H=$(branch "$S" "$1" "git apply $CH/c2-auth-small/change.patch; sed -i 's/6927/$2/' maze/app/internal/work/lib_v11.go")
  "$CI/pr-check.sh" "$S" "$(git -C "$S" rev-parse main)" "$H" > "$T/prc-$1.out" 2> "$T/prc-$1.err" || { bad "pr-check $1"; cat "$T/prc-$1.err"; }
  "$CI/build.sh" "$S" "$H" "$(fget "$T/prc-$1.out" service)" > "$T/build-$1.out" 2> "$T/build-$1.err" || { bad "build $1"; cat "$T/build-$1.err"; }
  ab_standin "$H" "${3:-$FX/ab-record-1ms.json}"
}
prep a 6927; A=$H
prep e 6928 "$FX/ab-record-0ms.json"; E=$H
prep m 6929; M=$H
prep f 6930; F=$H
prep v 6931; V=$H
prep w 6932 "$FX/ab-record-6ms.json"; W=$H
KEY=sk-meta-test-$RANDOM$RANDOM-secret

# a stand-in Meta API: 404 for muse-wonder-1.0, an accept answer (citing the digest in the request) from muse-spark-1.3
cat > "$T/fakemeta.py" << 'PY'
import json, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
log = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open(log, "a").write(json.dumps({"auth": self.headers.get("Authorization"), "body": b}) + "\n")
        if b["model"] == "muse-wonder-1.0":
            out, code = {"error": {"type": "invalid_request_error", "code": "model_not_found", "message": "no such model", "param": "model"}}, 404
        else:
            d = re.search(r"packet digest: (sha256:[0-9a-f]{64})", b["messages"][1]["content"]).group(1)
            ans = {"schema": "rhobound-mcp.judge-answer/v1", "packet": d, "decision": "accept",
                   "reasons": [{"refs": ["prediction.entries[0]"], "code": "within_budget"}],
                   "commentary": "The measured change is small and within the threshold."}
            out, code = {"id": "c", "object": "chat.completion", "model": b["model"], "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "```json\n" + json.dumps(ans) + "\n```"}}],
                         "usage": {"prompt_tokens": 900, "completion_tokens": 300}}, 200
        raw = json.dumps(out).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(raw)))
        self.end_headers(); self.wfile.write(raw)
s = ThreadingHTTPServer(("127.0.0.1", 0), H); open(sys.argv[1], "w").write(str(s.server_address[1])); s.serve_forever()
PY
python3 -I "$T/fakemeta.py" "$T/meta.port" "$T/meta.log" &
MPID=$!
trap 'kill $MPID 2> /dev/null' EXIT
for _ in $(seq 1 50); do [[ -s $T/meta.port ]] && break; sleep 0.1; done

# the stub providers (E, M, F): mode from a file
cat > "$T/stubjudge.py" << 'PY'
import hashlib, json, os, sys
mode = open(os.path.join(os.path.dirname(sys.argv[0]), "judge.mode")).read().strip()
p = open(sys.argv[1], "rb").read()
out = os.environ.get("JUDGE_OUT") or os.path.dirname(sys.argv[1])
open(os.path.join(out, "request.json"), "w").write('{"stub": "%s"}' % mode)
open(os.path.join(out, "model.txt"), "w").write("stub-judge-1\n")
if mode == "fail":
    sys.exit(1)
d = "sha256:" + hashlib.sha256(p.rstrip(b"\n")).hexdigest()
if mode == "mismatch":
    d = "sha256:" + "0" * 64
print(json.dumps({"schema": "rhobound-mcp.judge-answer/v1", "packet": d, "decision": "escalate" if mode == "escalate" else "accept",
                  "reasons": [{"refs": ["prediction.entries[0]"], "code": "needs_profile"}]}))
PY
setjudge() { # setjudge CMD [MODE]: JUDGE_CMD, JUDGE_MODE (and the stand-in API) in the test rbd-env.sh, as rbd.env.local sets them
  sed -i '/^export JUDGE_/d' "$TROOT/lib/rbd-env.sh"
  { echo "export JUDGE_CMD='$1'"; [[ -z ${2:-} ]] || echo "export JUDGE_MODE=$2"; echo "export JUDGE_API_URL=http://127.0.0.1:$(cat "$T/meta.port")/v1/chat/completions"
    echo "export JUDGE_KEY_CMD='printf %s $KEY'"; } >> "$TROOT/lib/rbd-env.sh"
}
predict() { local rc=0; RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$1" > "$T/pred-$1.out" 2> "$T/pred-$1.err" || rc=$?; echo "$rc"; }
gj() { python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); j=g.get("judge") or {}; print(g["verdict"], j.get("provenance"), j.get("model_id"), j.get("decision"), g["digests"].get("judge_request"))' "$THOME/runs/$1/gate/gate.json"; }

setjudge "python3 -I $TROOT/judge/meta-judge.py"
rc=$(predict "$A")
read -r v prov model dec req <<< "$(gj "$A")"
check "A: meta-judge.py, muse-wonder-1.0 refused (404), muse-spark-1.3 accepts: pass (exit $rc), ci-judge, model muse-spark-1.3" \
  test "$rc" -eq 0 -a "$v" = pass -a "$prov" = ci-judge -a "$model" = muse-spark-1.3 -a "$dec" = accept
check "A: gate.json's judge_request is the sha256 of the request.json sent" \
  test "$req" = "sha256:$(sha256sum "$THOME/runs/$A/judge/request.json" | cut -d' ' -f1)"
check "A: the API saw Bearer KEY, model muse-wonder-1.0 then muse-spark-1.3, json_object, effort high, no temperature" python3 -I -c '
import json,sys
L=[json.loads(l) for l in open(sys.argv[1])]
assert [x["body"]["model"] for x in L]==["muse-wonder-1.0","muse-spark-1.3"], L
assert all(x["auth"]=="Bearer "+sys.argv[2] for x in L)
b=L[1]["body"]; assert b["response_format"]=={"type":"json_object"} and b["reasoning_effort"]=="high" and "temperature" not in b
assert b["messages"][0]["role"]=="developer" and "judge-answer/v1" in b["messages"][0]["content"]' "$T/meta.log" "$KEY"
check "A: predict.json records the judge (admitted, the gate's ci-judge record)" python3 -I -c '
import json,sys
d=json.loads(open(sys.argv[1]).read().splitlines()[-1])["judge"]
assert d["status"]=="admitted" and d["model"]=="muse-spark-1.3" and d["gate"]["provenance"]=="ci-judge", d' "$T/pred-$A.out"
"$CI/sign.sh" "$A" > "$T/sign.out" 2> "$T/sign.err" || { bad "sign A"; tail -3 "$T/sign.err"; }
check "A: the signed predicate carries the judge (ci-judge, muse-spark-1.3, accept, answer and request digests)" python3 -I -c '
import json,sys
p=json.load(open(sys.argv[1])); j=p["judge"]
assert p["verdict"]=="pass" and j["provenance"]=="ci-judge" and j["model_id"]=="muse-spark-1.3" and j["decision"]=="accept"
assert j["request"]==sys.argv[2] and j["answer"].startswith("sha256:")' "$THOME/runs/$A/predicate.json" "$req"
check "A: the key is in no file of the run" bash -c '! grep -rqF "$1" "$2"' _ "$KEY" "$THOME/runs/$A"

setjudge "python3 -I $T/stubjudge.py"
echo escalate > "$T/judge.mode"
rc=$(predict "$E")
read -r v prov model dec req <<< "$(gj "$E")"
check "E: the judge escalates: inconclusive (exit $rc), ci-judge stub-judge-1, escalate" \
  test "$rc" -eq 3 -a "$v" = inconclusive -a "$prov" = ci-judge -a "$model" = stub-judge-1 -a "$dec" = escalate
check "E: predict.json names the decider judge_escalate (the commit status and the report say who decided)" \
  test "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["rule"])' "$T/pred-$E.out")" = judge_escalate
"$CI/sign.sh" "$E" > "$T/sign-E.out" 2> "$T/sign-E.err"; check "E: sign.sh signs the inconclusive verdict too (ok true)" test "$(fget "$T/sign-E.out" ok)" = true
"$CI/report.sh" "$E" > "$T/rep-E.out" 2> "$T/rep-E.err" || true
check "E: the report says the judge decided (stub-judge-1, escalate), not 'rule ?'" bash -c 'grep -q "decided by the judge (stub-judge-1" "$1" && ! grep -q "decided by rule ?" "$1"' _ "$THOME/runs/$E/summary.md"
echo mismatch > "$T/judge.mode"
rc=$(predict "$M")
read -r v prov model dec req <<< "$(gj "$M")"
check "M: an answer to another packet is refused by judge-check: pass stands (exit $rc), no judge in gate.json" \
  test "$rc" -eq 0 -a "$v" = pass -a "$prov" = None
check "M: judge.json says refused, with judge-check's code" bash -c 'grep -q "\"status\": \"refused\"" "$1" && grep -q "packet" "$1"' _ "$THOME/runs/$M/judge/judge.json"
echo fail > "$T/judge.mode"
rc=$(predict "$F")
read -r v prov model dec req <<< "$(gj "$F")"
check "F: the provider fails: judge unavailable, pass stands (exit $rc)" \
  test "$rc" -eq 0 -a "$v" = pass -a "$prov" = None -a -n "$(grep '"unavailable"' "$THOME/runs/$F/judge/judge.json")"
setjudge "python3 -I $T/stubjudge.py" advisory
echo escalate > "$T/judge.mode"
rc=$(predict "$V")
read -r v prov model dec req <<< "$(gj "$V")"
check "V (advisory): the judge escalates, the rules decide: pass (exit $rc), no judge in gate.json" test "$rc" -eq 0 -a "$v" = pass -a "$prov" = None
check "V: judge.json: admitted, advisory, escalate, with the request digest; predict.json's rule is mean_change" python3 -I -c '
import json,sys
j=json.load(open(sys.argv[1])); p=json.loads(open(sys.argv[2]).read().splitlines()[-1])
assert j["status"]=="admitted" and j["mode"]=="advisory" and j["decision"]=="escalate" and j["request"].startswith("sha256:"), j
assert p["rule"].startswith("mean_change") and p["judge"]["mode"]=="advisory" and p["judge"]["gate"] is None, p' "$THOME/runs/$V/judge/judge.json" "$T/pred-$V.out"
rc=$(predict "$W")
read -r v prov model dec req <<< "$(gj "$W")"
check "W (advisory): the 6 ms record blocks on the rules (exit $rc), the escalation changes nothing" test "$rc" -eq 1 -a "$v" = block -a "$prov" = None
"$CI/sign.sh" "$W" > "$T/sign-W.out" 2> "$T/sign-W.err"
check "W: signed (ok true): the predicate has judge_advisory (stub-judge-1, escalate, digests) and no gate judge" python3 -I -c '
import json,sys
p=json.load(open(sys.argv[1])); a=p["judge_advisory"]
assert p["verdict"]=="block" and "judge" not in p and a["model"]=="stub-judge-1" and a["decision"]=="escalate", p
assert a["request"].startswith("sha256:") and a["answer"].startswith("sha256:")' "$THOME/runs/$W/predicate.json"
"$CI/report.sh" "$W" > /dev/null 2>&1 || true
check "W: the report has the advisory judge section and names a rule as the decider" bash -c 'grep -q "## Judge (advisory: recorded, not part of the verdict)" "$1" && grep -q "stub-judge-1.*escalate" "$1" && grep -q "decided by rule" "$1"' _ "$THOME/runs/$W/summary.md"
sed -i 's/^export JUDGE_MODE=.*/export JUDGE_MODE=sometimes/' "$TROOT/lib/rbd-env.sh"
prep x 6933 "$FX/ab-record-0ms.json"; X=$H
rc=$(predict "$X")
check "a JUDGE_MODE other than gate/advisory is refused (exit $rc), no verdict kept" bash -c "[ $rc -eq 2 ] && [ ! -e '$THOME/runs/$X/gate' ]"
done_summary
