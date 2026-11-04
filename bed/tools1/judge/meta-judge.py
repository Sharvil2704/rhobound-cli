"""meta-judge.py PACKET: the CI judge's provider on rbd-tools1 (as rbd, from predict.sh): a gate's judge packet
(rhobound-mcp.judge-packet/v1) -> a Meta model -> its answer (rhobound-mcp.judge-answer/v1) on stdout.

    JUDGE_OUT=DIR python3 -I /opt/rbd/judge/meta-judge.py DIR/packet.json > DIR/answer.json

The request follows the CLI's examples/judge/openai-compatible.sh (the review_latency_impact prompt as the developer
message, the packet and its digest as the user message), on the Meta Model API's Chat Completions
(https://api.meta.ai/v1/chat/completions, Bearer; dev.meta.ai/docs, read 2026-10-30), with the answer's JSON schema in
the prompt and response_format json_object. JUDGE_OUT gets request.json (the exact bytes sent: predict.sh records their
sha256 as the gate's --judge-request), response.json (the API's reply) and model.txt (the model that answered).
The key: Secrets Manager JUDGE_SECRET [rhobound-demo/meta-key], read with the aws CLI into memory only; never written,
never printed. One request, no re-roll (ARCHITECTURE 7.2: an invalid answer is "judge unavailable", never retried into
a different one); only transport errors (429/500/503, Retry-After) are retried.
Model: JUDGE_MODEL [muse-wonder-1.0]; when the key cannot use it (403/404) JUDGE_FALLBACK [muse-spark-1.3] once, and
model.txt says which answered. Exit 0 an answer printed, 1 no answer.
Env: JUDGE_MODEL JUDGE_FALLBACK JUDGE_EFFORT [high] JUDGE_SECRET RBD_REGION JUDGE_API_URL (tests) JUDGE_KEY_CMD (tests)
"""
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
API_URL = os.environ.get("JUDGE_API_URL", "https://api.meta.ai/v1/chat/completions")
MODEL = os.environ.get("JUDGE_MODEL", "muse-wonder-1.0")
FALLBACK = os.environ.get("JUDGE_FALLBACK", "muse-spark-1.3")
EFFORT = os.environ.get("JUDGE_EFFORT", "high")
SECRET = os.environ.get("JUDGE_SECRET", "rhobound-demo/meta-key")
REGION = os.environ.get("RBD_REGION", "ap-south-1")
SECRETS = []


def say(msg):
    msg = re.sub(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]", "?", msg)
    for k in SECRETS:
        msg = msg.replace(k, "[redacted]")
    print(f"meta-judge: {msg}", file=sys.stderr, flush=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def read_key():
    cmd = os.environ.get("JUDGE_KEY_CMD")
    argv = ["sh", "-c", cmd] if cmd else ["aws", "secretsmanager", "get-secret-value", "--secret-id", SECRET, "--region", REGION,
                                          "--query", "SecretString", "--output", "text"]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=60,
                       env={k: v for k, v in os.environ.items() if not k.startswith("JUDGE_KEY")})
    key = r.stdout.strip()
    if r.returncode != 0 or not key or any(c.isspace() for c in key):
        say(f"cannot read the secret {SECRET} (exit {r.returncode}): {r.stderr.strip()[-300:]}")
        sys.exit(1)
    SECRETS.append(key)
    return key


def post(key, body):
    """(status, parsed JSON or None, error text). Retries 429/500/503 (and network errors) only."""
    data = json.dumps(body, separators=(",", ":")).encode()
    for attempt in range(5):
        req = urllib.request.Request(API_URL, data=data, method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
        try:
            with OPENER.open(req, timeout=900) as r:
                return 200, json.loads(r.read()), "", data
        except urllib.error.HTTPError as e:
            raw = e.read()[:2000].decode("utf-8", "replace")
            try:
                err = json.loads(raw).get("error", {})
                why = f"{err.get('type')}/{err.get('code')}: {err.get('message')}"
            except (ValueError, AttributeError):
                why = raw[:300] or "(empty body)"
            if e.code in (429, 500, 503) and attempt < 4:
                try:
                    wait = float(e.headers.get("retry-after") or 0)
                except ValueError:
                    wait = 0
                wait = min(90.0, wait or 1.0 * 2 ** attempt + random.random())
                say(f"HTTP {e.code} ({why}); retry in {wait:.0f} s")
                time.sleep(wait)
                continue
            return e.code, None, why, data
        except (urllib.error.URLError, OSError, TimeoutError, ValueError) as e:
            if attempt < 4:
                say(f"unreachable ({type(e).__name__}); retry in {2 ** attempt * 3} s")
                time.sleep(2 ** attempt * 3)
                continue
            return 0, None, f"{type(e).__name__}: {e}", data
    return 0, None, "out of retries", data


def main():
    if len(sys.argv) != 2:
        say("usage: JUDGE_OUT=DIR meta-judge.py PACKET.json > ANSWER.json")
        return 1
    packet = Path(sys.argv[1]).read_bytes()
    out = Path(os.environ.get("JUDGE_OUT") or Path(sys.argv[1]).parent)
    digest = "sha256:" + hashlib.sha256(packet.rstrip(b"\n")).hexdigest()   # judge-packet --json prints canonical bytes
    prompt = (HERE / "review_latency_impact.txt").read_text("utf-8")
    schema = (HERE / "judge-answer.v1.json").read_text("utf-8")
    system = (prompt + "\n\nThe JSON schema of your answer (judge-check refuses anything else, unknown fields included; "
              "\"schema\" must be \"rhobound-mcp.judge-answer/v1\" and \"packet\" the digest given after the packet):\n" + schema)
    key = read_key()
    model, tried = MODEL, []
    while True:
        body = {"model": model, "messages": [{"role": "developer", "content": system},
                                             {"role": "user", "content": packet.decode("utf-8") + "\npacket digest: " + digest}],
                "reasoning_effort": EFFORT, "max_completion_tokens": 16000, "response_format": {"type": "json_object"}}
        status, resp, why, sent = post(key, body)
        tried.append(model)
        if status in (403, 404) and model != FALLBACK and FALLBACK:
            say(f"{model} is not available to this key (HTTP {status}: {why}): asking {FALLBACK} instead")
            model = FALLBACK
            continue
        break
    (out / "request.json").write_bytes(sent)
    if resp is None:
        say(f"no answer from {model} (HTTP {status}: {why})")
        return 1
    (out / "response.json").write_text(json.dumps(resp, indent=1) + "\n")
    served = resp.get("model") or model
    (out / "model.txt").write_text(served + "\n")
    ch = (resp.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    text = msg.get("content") if isinstance(msg.get("content"), str) else ""
    text = re.sub(r"^\s*```(?:json)?\s*|\s*```\s*$", "", text or "")
    if not text.strip():
        say(f"{served} gave no answer text (finish_reason {ch.get('finish_reason')}, refusal {msg.get('refusal')!r})")
        return 1
    for k in SECRETS:
        if k in text:
            say("the answer holds the key: dropped")
            return 1
    u = resp.get("usage") or {}
    say(f"{served} answered (tried {', '.join(tried)}; {u.get('prompt_tokens')} in, {u.get('completion_tokens')} out, "
        f"finish_reason {ch.get('finish_reason')})")
    sys.stdout.write(text.strip() + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:
        say(f"crashed: {type(e).__name__}: {e}")
        sys.exit(1)
