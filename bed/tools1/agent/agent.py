"""agent.py: the model-written change of demo1 (2026-10-30). On rbd-tools1, as rbd:

    python3 -I /opt/rbd/agent/agent.py --out /var/lib/rbd/agent/RUN [--task /opt/rbd/agent/task-prc77.md] [--feedback FILE]

A model gets one ticket and these tools, nothing else:
  list_files, read_file    the source of main as images.sh uploaded it (/var/lib/rbd/src/main): maze/app/** and maze/spec.json
  write_file               a .go file under maze/app/, held in memory (nothing is compiled, run or written outside OUT)
  rhobound_context, rhobound_budget, rhobound_predict, rhobound_explain
                           rhobound-mcp on 127.0.0.1:8765 with /var/lib/rbd/mcp/token (rhobound:read; fit_start/job_status
                           are not offered: the CI measures)
  submit_change            the service, a title and a summary: ends the run
Providers (RBD_AGENT_PROVIDER):
  meta (default)  Meta Model API, Chat Completions: POST https://api.meta.ai/v1/chat/completions, Authorization: Bearer,
                  model muse-spark-1.3, OpenAI-style function tools, reasoning_effort (dev.meta.ai/docs, read 2026-10-30)
  anthropic       Claude Messages API: claude-opus-5-5, anthropic-version 2026-10-21, fallbacks "default"
The API key: AWS Secrets Manager RBD_AGENT_SECRET [rhobound-demo/anthropic-key: a historical name; it holds the Meta key]
(the tools role), read with the aws CLI into memory only: never written, never printed, never passed to a child. OUT (new or
empty): files/<path> for each changed file, manifest.json (rbd.agent-change/v1), rhobound-change.json (rbd.change-request/v1),
change.patch (for reading; the workstation rebuilds it), transcript.jsonl, result.json. Last stdout line:
{"step":"agent","ok":...}. Exit 0 submitted, 1 not, 2 usage.
Env: RBD_AGENT_PROVIDER RBD_AGENT_MODEL RBD_AGENT_EFFORT [high] RBD_AGENT_MAX_TURNS [40] RBD_AGENT_SECRET RBD_REGION RBD_REPO
     RBD_AGENT_BRANCH [rbd/c5-model] RBD_MCP_URL RBD_MCP_TOKEN_FILE RBD_AGENT_API_URL (tests) RBD_AGENT_KEY_CMD (tests: a
     command printing a key) RBD_AGENT_SBX_CALLS [6] RBD_SBX_TMP [OUT's parent: the sandbox's temporary trees]

The bench modes (SPEC2 3; tools1/bench/run_task.py drives them; --bench-task DIR = tools1/bench/tasks/<id>, its task.json):
  --plan K --bench-task DIR      S0: tools list_files, read_file, rhobound_context, rhobound_budget and submit_plan (exactly K
                                 distinct strategies {tag, line}; refused until context and budget were both called). OUT gets
                                 plan.json (rbd.bench-plan/v1 {k, strategies, turns, usage, mcp_calls}), transcript, result.json
  --approach TEXT --bench-task DIR [--sbx SBX] [--start PREV_OUT --review FILE]
                                 S1: the ticket is task.json's prompt (--task is not read) plus the strategy TEXT; write_file only
                                 under task.json's writable folders; two more tools, each at most RBD_AGENT_SBX_CALLS calls a run:
                                 run_tests (the visible tests) and run_bench (the task's microbenchmarks against main) run
                                 'bash SBX tests|bench TREE DIR OUT' (tools1/bench/sbx.sh: docker, no network) on the workspace
                                 written to a temporary tree; submit_change takes one of task.json's services. --start continues
                                 from an earlier run's files (the S5 revise round), --review adds the reviewer's issues to the
                                 ticket. OUT as above, with rhobound-change.json rbd.change-request/v2 {services: task.json's,
                                 summary, base (only when task.json names one)} and the manifest's "approach", "task", "sandbox".
"""
import argparse
import difflib
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.request
from pathlib import Path

PROVIDER = os.environ.get("RBD_AGENT_PROVIDER", "meta")
DEFAULTS = {"meta": ("https://api.meta.ai/v1/chat/completions", "muse-spark-1.3"),
            "anthropic": ("https://api.anthropic.com/v1/messages", "claude-opus-5-5")}
if PROVIDER not in DEFAULTS:
    sys.exit(f"agent: RBD_AGENT_PROVIDER must be one of {sorted(DEFAULTS)}")
API_URL = os.environ.get("RBD_AGENT_API_URL", DEFAULTS[PROVIDER][0])
MODEL = os.environ.get("RBD_AGENT_MODEL", DEFAULTS[PROVIDER][1])
EFFORT = os.environ.get("RBD_AGENT_EFFORT", "high")
MAX_TURNS = int(os.environ.get("RBD_AGENT_MAX_TURNS", "40"))
MAX_OUTPUT_TOTAL = 400_000          # output tokens over the whole run: a runaway stops here
SECRET_ID = os.environ.get("RBD_AGENT_SECRET", "rhobound-demo/anthropic-key")
REGION = os.environ.get("RBD_REGION", "ap-south-1")
REPO = os.environ.get("RBD_REPO", "Sharvil2704/rhobound-maze-bed")
BRANCH = os.environ.get("RBD_AGENT_BRANCH", "rbd/c5-model")
MCP_URL = os.environ.get("RBD_MCP_URL", "http://127.0.0.1:8765/mcp")
MCP_TOKEN_FILE = os.environ.get("RBD_MCP_TOKEN_FILE", "/var/lib/rbd/mcp/token")
MCP_TOOLS = ("context", "budget", "predict", "explain")
PROTOCOL = "2025-06-18"
WRITABLE = re.compile(r"maze/app/(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}/){0,6}[A-Za-z0-9_][A-Za-z0-9_.-]{0,60}\.go")   # fullmatch
MAX_FILE = 100_000
MAX_CHANGED = 8
RESULT_CHARS = 24_000
MCP_PER_TURN, MCP_PER_RUN = 6, 40   # engine runs on the box the CI shares
EFFORT_DOWN = {"max": "xhigh", "xhigh": "high", "high": "medium", "medium": "low", "low": "minimal"}

SYSTEM = """You are a senior Go engineer on maze, a shop of 32 Go services built into 28 images (maze/app; \
maze/app/cmd/<image> is each image, maze/spec.json says which service runs which image, its routes, workers and calls). You work through tools only: \
list_files, read_file and write_file for the source (write_file takes a whole .go file under maze/app/; nothing is \
compiled or run here: the CI builds the image), the rhobound_* tools, and submit_change, which ends the task.

The rhobound_* tools model production's mean latency per entry from a recent capture of live traces (a queueing model per \
service: utilization, own time per visit, workers, leverage). After you submit, the CI builds the image of the service you name, \
runs it beside production in an A/B, and the rhobound gate passes the change only when no entry's mean latency \
rises by the policy threshold or more. rhobound_predict with numbers you declare (own_ms, own_pct, ...) is an advisory \
preview: by design it answers block or inconclusive, never pass. That is expected, not a failure: use it to size the \
effect and put the expected number in your summary.

Rules: keep security behaviour identical (same algorithms, parameters and accept/reject result for every input); no new \
dependencies (go.mod and go.sum are fixed; the standard library is fine); one service's behaviour; bounded memory; gofmt \
style. Write complete, compilable files."""

LOCAL_TOOLS = [
    {"name": "list_files", "description": "List the files you can read (maze/app/** and maze/spec.json) with their sizes; "
     "files you changed are marked.", "strict": True,
     "schema": {"type": "object", "properties": {}, "required": [], "additionalProperties": False}},
    {"name": "read_file", "description": "Read one file (your edited version if you changed it).", "strict": True,
     "schema": {"type": "object", "properties": {"path": {"type": "string", "description": "e.g. maze/app/internal/svc/pricing/pricing.go"}},
                "required": ["path"], "additionalProperties": False}},
    {"name": "write_file", "description": "Replace (or create) one .go file under maze/app/ with the complete new content. "
     "Held in memory until you submit; at most 8 files changed.", "strict": True,
     "schema": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                "required": ["path", "content"], "additionalProperties": False}},
    {"name": "submit_change", "description": "Finish: the ONE service whose image the CI must build and measure (a name in "
     "maze/spec.json), a one-line title (at most 72 characters) and a summary for the pull request (at most 1000 "
     "characters: what changed, why it is safe, and the latency effect you expect with the rhobound numbers).", "strict": True,
     "schema": {"type": "object", "properties": {"service": {"type": "string"}, "title": {"type": "string"},
                                                 "summary": {"type": "string"}},
                "required": ["service", "title", "summary"], "additionalProperties": False}},
]

# ------------------------------------------------------------------------------------------------- bench modes (SPEC2 3)
SBX_CALLS = int(os.environ.get("RBD_AGENT_SBX_CALLS", "6"))
EMPTY = {"type": "object", "properties": {}, "required": [], "additionalProperties": False}
SBX_TOOLS = [
    {"name": "run_tests", "description": "Run the task package's visible tests (go test -v) on your current files in a "
     "sandbox (no network). Returns PASS/FAIL, counts and the output's tail. At most %d calls." % SBX_CALLS, "strict": True,
     "schema": EMPTY},
    {"name": "run_bench", "description": "Run the task's microbenchmarks on main's code and on yours, interleaved, 5 rounds, "
     "in a sandbox: median ns/op and allocs/op of each. Takes about a minute. At most %d calls." % SBX_CALLS, "strict": True,
     "schema": EMPTY},
]
PLAN_TOOL = {"name": "submit_plan", "description": "Finish: exactly K distinct strategies for the task, each a short tag "
             "(lowercase letters, digits, '-'; at most 24 characters) and one line (at most 200 characters) saying what the "
             "change does and why it can be both correct and fast.", "strict": True,
             "schema": {"type": "object", "properties": {"strategies": {"type": "array", "items": {
                 "type": "object", "properties": {"tag": {"type": "string"}, "line": {"type": "string"}},
                 "required": ["tag", "line"], "additionalProperties": False}}},
                 "required": ["strategies"], "additionalProperties": False}}
SYSTEM_BENCH = """You are a senior Go engineer on maze, a shop of 32 Go services built into 28 images (maze/app; \
maze/app/cmd/<image> is each image, maze/spec.json says which service runs which image, its routes, workers and calls). This ticket is one task of a benchmark: \
several engineers try different approaches to it in parallel, and you follow the approach you are given. You work through \
tools only: list_files and read_file for the source; write_file takes a whole .go file and only under the folders the \
task makes writable; run_tests runs the package's visible tests and run_bench the task's microbenchmarks (main's code \
against yours), both in a sandbox and both limited in calls; the rhobound_* tools model production's mean latency per entry \
from live traces (rhobound_predict with numbers you declare is an advisory preview: it answers block or inconclusive, \
never pass); submit_change ends the task.

After you submit: hidden tests check correctness (never shown to you), the microbenchmark measures your code, a rhobound \
preview turns that into production latency, and a reviewer reads the diff; each can stop your approach.

Rules: identical results for every input unless the ticket says otherwise; standard library only (go.mod and go.sum are \
fixed); bounded memory; no goroutine outlives a call; never special-case the tests, the benchmarks or their inputs; gofmt \
style; write complete, compilable files."""
SYSTEM_PLAN = """You are the lead Go engineer on maze, a shop of 32 Go services built into 28 images (maze/app; \
maze/app/cmd/<image> is each image, maze/spec.json says which service runs which image, its routes, workers and calls). You plan one task of a benchmark: \
several engineers will each implement ONE of your strategies in parallel, and the best measured one ships.

First call rhobound_context (where production's mean latency is tight: utilization, own time per visit, leverage) and \
rhobound_budget for the task's service(s) (how much they may add or must lose); read the code with list_files and \
read_file; then call submit_plan with exactly K strategies. Strategies must be distinct mechanisms (not variants of one), \
each plausible for identical results; at least one should be the simplest safe change. Nothing is written in this step."""


class Fail(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None   # a 3xx is an HTTPError: the key and the MCP token go to the URL we chose, nowhere else


OPENER = urllib.request.build_opener(NoRedirect)


class Scrub:
    """Every string that leaves this process goes through here: the key never appears in OUT or on stdout/stderr."""
    secrets: list = []

    @classmethod
    def s(cls, text: str) -> str:
        for k in cls.secrets:
            if k:
                text = text.replace(k, "[redacted]")
        return text


CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def log(msg: str):
    msg = CONTROL.sub("?", msg)   # model text and tool results: no escape sequence reaches a terminal
    print(Scrub.s(f"[agent {time.strftime('%H:%M:%S', time.gmtime())}] {msg}"), file=sys.stderr, flush=True)


# ------------------------------------------------------------------------------------------------------------------ key
def read_key() -> str:
    cmd = os.environ.get("RBD_AGENT_KEY_CMD")
    argv = ["sh", "-c", cmd] if cmd else ["aws", "secretsmanager", "get-secret-value", "--secret-id", SECRET_ID,
                                           "--region", REGION, "--query", "SecretString", "--output", "text"]
    env = {k: v for k, v in os.environ.items() if not k.startswith("RBD_AGENT_KEY")}
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=60, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Fail(f"cannot run the secret read ({argv[0]}): {type(e).__name__}")
    if r.returncode != 0:
        raise Fail(f"cannot read the secret {SECRET_ID} (exit {r.returncode}): {r.stderr.strip()[-400:]} "
                   f"(store it from CloudShell: BED=1 bash spawn_two.sh secret {SECRET_ID.split('/', 1)[-1]})")
    key = r.stdout.strip()
    if not key or any(c.isspace() for c in key):
        raise Fail(f"the secret {SECRET_ID} is empty or holds more than one word")
    return key


# ------------------------------------------------------------------------------------------------------------------ MCP
class MCP:
    def __init__(self, url: str, token: str, timeout: float = 300):
        self.url, self.token, self.timeout = url, token, timeout
        self.sid, self.version, self.next_id = None, PROTOCOL, 1

    def _post(self, body: dict):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
             "Authorization": f"Bearer {self.token}", "MCP-Protocol-Version": self.version}
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST", headers=h)
        with OPENER.open(req, timeout=self.timeout) as r:
            self.sid = r.headers.get("Mcp-Session-Id") or self.sid
            raw, ctype = r.read().decode("utf-8", "replace"), r.headers.get("Content-Type", "")
        if "id" not in body:
            return None
        msgs = []
        if ctype.startswith("text/event-stream"):
            for block in raw.replace("\r\n", "\n").split("\n\n"):
                data = "\n".join(line[5:].lstrip() for line in block.splitlines() if line.startswith("data:"))
                if data:
                    msgs.append(json.loads(data))
        elif raw.strip():
            msgs.append(json.loads(raw))
        for m in msgs:
            if isinstance(m, dict) and m.get("id") == body["id"]:
                return m
        raise Fail(f"MCP: no answer to request {body['id']} in: {raw[:300]}")

    def request(self, method: str, params: dict | None = None) -> dict:
        self.next_id += 1
        return self._post({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}})

    def open(self):
        m = self._post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": PROTOCOL, "capabilities": {},
                                   "clientInfo": {"name": "rbd-agent", "version": "1"}}})
        if "error" in m:
            raise Fail(f"MCP initialize: {m['error']}")
        self.version = m["result"].get("protocolVersion", PROTOCOL)
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def tools(self) -> list:
        m = self.request("tools/list")
        if "error" in m:
            raise Fail(f"MCP tools/list: {m['error']}")
        return m["result"]["tools"]

    def call(self, name: str, args: dict) -> tuple[str, bool]:
        try:
            m = self.request("tools/call", {"name": name, "arguments": args})
        except urllib.error.HTTPError as e:
            return f"MCP HTTP {e.code}: {e.read()[:300]!r}", True
        except (urllib.error.URLError, OSError, ValueError) as e:
            return f"MCP unreachable or unreadable: {type(e).__name__}: {e}", True
        if "error" in m:
            return json.dumps(m["error"]), True
        r = m["result"]
        out = r.get("structuredContent")
        text = json.dumps(out, separators=(",", ":")) if out is not None else \
            "\n".join(x.get("text", "") for x in r.get("content", []) if x.get("type") == "text")
        return text, bool(r.get("isError"))


def portable_schema(s: dict) -> tuple[dict, str]:
    """An MCP inputSchema for a model API: local $refs inlined (no $defs left), no top-level oneOf/anyOf/allOf (said in words
    instead), no $schema/$id. The server still validates every call against its own schema."""
    s = json.loads(json.dumps(s))
    defs = s.pop("$defs", None) or s.pop("definitions", None) or {}

    def walk(x, depth=0):
        if depth > 32:
            return {}
        if isinstance(x, dict):
            ref = x.get("$ref")
            if isinstance(ref, str):
                name = ref.split("/")[-1] if ref.startswith(("#/$defs/", "#/definitions/")) else None
                base = walk(defs[name], depth + 1) if name in defs else {}
                rest = {k: walk(v, depth + 1) for k, v in x.items() if k != "$ref"}
                return {**base, **rest}
            return {k: walk(v, depth + 1) for k, v in x.items() if k not in ("$defs", "definitions", "$schema", "$id")}
        if isinstance(x, list):
            return [walk(v, depth + 1) for v in x]
        return x

    s = walk(s)
    notes = []
    for k in ("oneOf", "anyOf", "allOf"):
        if k in s:
            notes.append(f"{k}: {json.dumps(s.pop(k), separators=(',', ':'))}")
    s.setdefault("type", "object")
    return s, ("; constraints " + " ".join(notes)) if notes else ""


# ------------------------------------------------------------------------------------------------------------ providers
def http_json(url: str, headers: dict, body: dict, timeout: float = 600) -> dict:
    """POST body; retries 408/409/429/500/502/503/529 and network errors (Retry-After honoured, else exponential backoff
    with jitter, 6 attempts). Raises Fail with the status and the API's error type/message only (never a header)."""
    data = json.dumps(body).encode()
    for attempt in range(6):
        req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json", **headers})
        try:
            with OPENER.open(req, timeout=timeout) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            raw = e.read()[:2000].decode("utf-8", "replace")
            try:
                err = json.loads(raw).get("error", {})
                why = f"{err.get('type')}: {err.get('message')}" + (f" (param {err.get('param')})" if err.get("param") else "")
            except (ValueError, AttributeError):
                why = raw[:300] or "(empty body)"
            if e.code in (408, 409, 429, 500, 502, 503, 529) and attempt < 5:
                try:
                    wait = float(e.headers.get("retry-after") or 0)
                except ValueError:
                    wait = 0
                wait = min(90.0, wait or 2.0 * 2 ** attempt + random.random())
                log(f"API HTTP {e.code} ({why}); retry in {wait:.0f} s")
                time.sleep(wait)
                continue
            raise Fail(f"API HTTP {e.code}: {why}")
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            if attempt < 5:
                log(f"API unreachable ({type(e).__name__}: {e}); retry in {5 * 2 ** attempt} s")
                time.sleep(5 * 2 ** attempt)
                continue
            raise Fail(f"API unreachable: {type(e).__name__}: {e}")
    raise Fail("API: out of retries")


class Turn:
    """One model answer, provider-neutral. stop: tool | end | cut | refusal | pause."""
    def __init__(self, stop, texts, calls, usage, served_by, raw_stop):
        self.stop, self.texts, self.calls, self.usage, self.served_by, self.raw_stop = stop, texts, calls, usage, served_by, raw_stop


class Anthropic:
    """Claude Messages API (raw HTTP; API version 2026-10-21; adaptive thinking by default, effort via output_config)."""
    def __init__(self, key, system, tools):
        self.key, self.system, self.messages = key, system, []
        self.tools = [{"name": t["name"], "description": t["description"], "input_schema": t["schema"],
                       **({"strict": True} if t.get("strict") else {})} for t in tools]

    def user(self, text):
        self.messages.append({"role": "user", "content": text})

    def turn(self) -> Turn:
        resp = http_json(API_URL, {"x-api-key": self.key, "anthropic-version": "2026-10-21",
                                   "anthropic-beta": "server-side-fallback-2026-07-01"},
                         {"model": MODEL, "max_tokens": 32000, "system": self.system, "tools": self.tools,
                          "messages": self.messages, "output_config": {"effort": EFFORT}, "fallbacks": "default",
                          "cache_control": {"type": "ephemeral"}})
        content, stop = resp.get("content") or [], resp.get("stop_reason")
        self.messages.append({"role": "assistant", "content": content})     # append-only, thinking blocks unchanged
        u = resp.get("usage") or {}
        calls = [{"id": b["id"], "name": b["name"], "args": b.get("input") if isinstance(b.get("input"), dict) else None}
                 for b in content if b.get("type") == "tool_use"]
        kind = {"tool_use": "tool", "end_turn": "end", "max_tokens": "cut", "refusal": "refusal",
                "pause_turn": "pause"}.get(stop, "end")
        if stop == "refusal":
            stop = f"refusal {json.dumps(resp.get('stop_details'))}"
        return Turn(kind, [b.get("text", "") for b in content if b.get("type") == "text"], calls,
                    {"input": int(u.get("input_tokens") or 0), "output": int(u.get("output_tokens") or 0),
                     "cached": int(u.get("cache_read_input_tokens") or 0)}, resp.get("model"), stop)

    def results(self, rs):
        self.messages.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": i, "content": t, "is_error": e}
                                                          for i, t, e in rs]})


class Meta:
    """Meta Model API, Chat Completions (OpenAI-compatible): POST /v1/chat/completions, Authorization: Bearer. Per
    dev.meta.ai/docs (2026-10-30): tools {type: function, function: {name, description, parameters, strict}}; tool_choice
    only "auto"; the full assistant message is appended, then one {role: tool, tool_call_id, content} per call (an unpaired
    tool_calls message is a 400); reasoning_effort minimal..max ("none" is a 400); max_completion_tokens counts reasoning
    tokens; finish_reason stop | length | tool_calls | content_filter; no temperature/top_p sent (the model is best at its
    defaults); reasoning is not carried across turns on this endpoint. A 504 (non-streaming time limit) is retried once per
    turn with reasoning_effort one step lower, as the error-handling page advises."""
    def __init__(self, key, system, tools, cache_key):
        self.key, self.effort, self.cache_key = key, EFFORT, cache_key
        self.messages = [{"role": "developer", "content": system}]
        self.tools = [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                        "parameters": t["schema"], **({"strict": True} if t.get("strict") else {})}}
                      for t in tools]

    def user(self, text):
        self.messages.append({"role": "user", "content": text})

    def turn(self) -> Turn:
        while True:
            body = {"model": MODEL, "messages": self.messages, "tools": self.tools, "tool_choice": "auto",
                    "parallel_tool_calls": True, "reasoning_effort": self.effort, "max_completion_tokens": 32000,
                    "prompt_cache_key": self.cache_key}
            try:
                resp = http_json(API_URL, {"Authorization": f"Bearer {self.key}"}, body)
                break
            except Fail as e:
                if str(e).startswith("API HTTP 504") and self.effort in EFFORT_DOWN:
                    log(f"504 (non-streaming time limit) at reasoning_effort {self.effort}: again at {EFFORT_DOWN[self.effort]}")
                    self.effort = EFFORT_DOWN[self.effort]
                    continue
                raise
        ch = (resp.get("choices") or [{}])[0]
        msg, fin = ch.get("message") or {}, ch.get("finish_reason")
        tcs = msg.get("tool_calls") or []
        keep = {"role": "assistant", "content": msg.get("content")}
        if tcs:
            keep["tool_calls"] = [{"id": c["id"], "type": "function",
                                   "function": {"name": c["function"]["name"], "arguments": c["function"].get("arguments") or "{}"}}
                                  for c in tcs]
        if keep["content"] is None and not tcs:
            keep["content"] = ""
        self.messages.append(keep)
        calls = []
        for c in keep.get("tool_calls", []):
            try:
                a = json.loads(c["function"]["arguments"])
                a = a if isinstance(a, dict) else None
            except ValueError:
                a = None
            calls.append({"id": c["id"], "name": c["function"]["name"], "args": a})
        u = resp.get("usage") or {}
        kind = "tool" if tcs else {"stop": "end", "length": "cut", "content_filter": "refusal"}.get(fin, "end")
        if fin == "length" and tcs:
            kind = "cut"
        texts = [msg["content"]] if isinstance(msg.get("content"), str) else \
            [p.get("text", "") for p in msg.get("content") or [] if isinstance(p, dict)]
        if msg.get("refusal"):
            kind, fin = "refusal", f"refusal: {msg['refusal']}"
        return Turn(kind, texts, calls,
                    {"input": int(u.get("prompt_tokens") or 0), "output": int(u.get("completion_tokens") or 0),
                     "cached": int((u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0),
                     "reasoning": int((u.get("completion_tokens_details") or {}).get("reasoning_tokens") or 0)},
                    resp.get("model"), fin)

    def results(self, rs):
        for i, t, e in rs:
            self.messages.append({"role": "tool", "tool_call_id": i, "content": ("ERROR: " + t) if e else t})


# ------------------------------------------------------------------------------------------------------------ workspace
class Workspace:
    def __init__(self, src: Path):
        self.src, self.orig, self.files, self.writable = src, {}, {}, None   # writable: folder prefixes (bench) or None
        app = src / "maze" / "app"
        if not app.is_dir() or app.is_symlink():
            raise Fail(f"no {app}")
        for root, dirs, names in os.walk(app, followlinks=False):
            dirs[:] = sorted(d for d in dirs if not (Path(root) / d).is_symlink())
            for n in sorted(names):
                p = Path(root) / n
                if p.is_symlink() or not p.is_file():
                    continue
                rel = p.relative_to(src).as_posix()
                try:
                    self.orig[rel] = p.read_bytes().decode("utf-8")
                except UnicodeDecodeError:
                    continue
        spec = src / "maze" / "spec.json"
        self.orig["maze/spec.json"] = spec.read_text("utf-8")
        self.services = sorted(json.loads(self.orig["maze/spec.json"])["services"])
        self.files = dict(self.orig)

    def changed(self) -> list:
        return sorted(p for p in self.files if self.files[p] != self.orig.get(p))

    def list_files(self, _a):
        ch = set(self.changed())
        return "\n".join(f"{p}  {len(self.files[p].encode())} bytes{'  (changed)' if p in ch else ''}"
                         for p in sorted(self.files)), False

    def read_file(self, a):
        p = a.get("path", "")
        if not isinstance(p, str) or p not in self.files:
            return f"no such file: {p!r} (list_files shows what you can read)", True
        return self.files[p], False

    def write_file(self, a):
        p, c = a.get("path", ""), a.get("content", "")
        if not isinstance(p, str) or not WRITABLE.fullmatch(p) or "/../" in f"/{p}/" or "/./" in f"/{p}/":
            return f"refused: {p!r} is not a .go file path under maze/app/", True
        if self.writable is not None and not any(p.startswith(w) and "/" not in p[len(w):] for w in self.writable):
            return f"refused: {p!r}: this task lets you write only directly in {', '.join(self.writable)}", True
        if not isinstance(c, str) or not c.strip():
            return "refused: empty content", True
        if not c.endswith("\n"):
            c += "\n"
        try:
            size = len(c.encode())
        except UnicodeEncodeError:
            return "refused: the content is not valid UTF-8 text", True
        if size > MAX_FILE:
            return f"refused: more than {MAX_FILE} bytes", True
        if "\x00" in c:
            return "refused: NUL byte", True
        if p not in self.orig and not any(q.startswith(p.rsplit("/", 1)[0] + "/") for q in self.orig):
            return f"refused: {p!r} is in a new folder (new files go next to existing ones)", True
        if p not in self.changed() and len(self.changed()) >= MAX_CHANGED and c != self.orig.get(p):
            return f"refused: at most {MAX_CHANGED} files may change", True
        self.files[p] = c
        return f"ok: {p} held ({len(c.encode())} bytes); changed files: {', '.join(self.changed()) or 'none'}", False

    def patch(self) -> str:
        out = []
        for p in self.changed():
            a = self.orig.get(p)
            head = [f"diff --git a/{p} b/{p}\n"] + (["new file mode 100644\n"] if a is None else [])
            d = list(difflib.unified_diff((a or "").splitlines(True), self.files[p].splitlines(True),
                                          "/dev/null" if a is None else f"a/{p}", f"b/{p}"))
            out += head + d
        return "".join(out)


# ---------------------------------------------------------------------------------------------------------- bench helpers
def load_bench_task(d: Path) -> dict:
    """task.json of a bench task (SPEC2 2): the fields the agent uses, checked."""
    try:
        t = json.loads((d / "task.json").read_text("utf-8"))
    except (OSError, ValueError) as e:
        raise Fail(f"cannot read {d}/task.json: {type(e).__name__}")
    folder = re.compile(r"maze/app/(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}/){1,6}")
    svcs, wr = t.get("services"), t.get("writable")
    if not (isinstance(t.get("id"), str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", t["id"])
            and isinstance(t.get("prompt"), str) and t["prompt"].strip()
            and isinstance(svcs, list) and 1 <= len(svcs) <= 3 and all(isinstance(s, str) for s in svcs)
            and len(set(svcs)) == len(svcs) and isinstance(wr, list) and wr
            and all(isinstance(w, str) and folder.fullmatch(w) and "/../" not in "/" + w and "/./" not in "/" + w for w in wr)
            and (t.get("base") is None or isinstance(t.get("base"), str))):
        raise Fail(f"{d}/task.json: id, prompt, services (1..3 distinct) and writable (folders under maze/app/ ending in /) "
                   "are required; base is null or a name")
    return t


def start_files(prev: Path) -> dict:
    """The files of an earlier run's OUT (its manifest's list, read from files/): the revise round starts from them."""
    man = json.loads((prev / "manifest.json").read_text("utf-8"))
    got = {}
    for f in man.get("files") or []:
        p = f.get("path") if isinstance(f, dict) else None
        if not isinstance(p, str) or not WRITABLE.fullmatch(p) or "/../" in f"/{p}/":
            raise Fail(f"--start: bad file path {p!r}")
        q = prev / "files" / p
        if q.is_symlink() or not q.is_file():
            raise Fail(f"--start: {p} is not a plain file")
        got[p] = q.read_text("utf-8")
    return got


def check_plan(args: dict, k: int, called: set) -> tuple[str, bool]:
    """submit_plan: exactly K distinct strategies, after rhobound_context and rhobound_budget."""
    if not {"context", "budget"} <= called:
        return "refused: call rhobound_context and rhobound_budget first (production's view decides the strategies)", True
    st = args.get("strategies")
    if not isinstance(st, list) or len(st) != k:
        return f"refused: exactly {k} strategies", True
    tags, lines = set(), set()
    for s in st:
        if not isinstance(s, dict) or set(s) != {"tag", "line"}:
            return "refused: each strategy is {tag, line}", True
        tag, line = s["tag"], s["line"]
        if not isinstance(tag, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,23}", tag):
            return f"refused: tag {tag!r}: lowercase letters, digits and '-', at most 24", True
        if not isinstance(line, str) or not line.strip() or len(line) > 200 or not line.isprintable():
            return f"refused: {tag}: the line must be 1-200 printable characters", True
        if tag in tags or line.strip().lower() in lines:
            return f"refused: {tag}: strategies must be distinct", True
        tags.add(tag)
        lines.add(line.strip().lower())
    return "submitted", False


# ----------------------------------------------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--src", default="/var/lib/rbd/src/main")
    ap.add_argument("--task", default=str(Path(__file__).resolve().parent / "task-prc77.md"))
    ap.add_argument("--feedback", help="text from a failed earlier attempt (the compiler's errors)")
    ap.add_argument("--plan", type=int, help="bench S0: plan K strategies (needs --bench-task)")
    ap.add_argument("--approach", help="bench S1: the strategy to implement (needs --bench-task)")
    ap.add_argument("--bench-task", help="tools1/bench/tasks/<id> (its task.json)")
    ap.add_argument("--sbx", default=str(Path(__file__).resolve().parent.parent / "bench" / "sbx.sh"))
    ap.add_argument("--start", help="bench S1: an earlier OUT whose files this run starts from (the revise round)")
    ap.add_argument("--review", help="bench S1: a file with the reviewer's issues (the revise round)")
    a = ap.parse_args()
    mode = "plan" if a.plan is not None else "approach" if a.approach is not None else "day1"
    if (mode != "day1" and not a.bench_task) or (a.plan is not None and a.approach is not None) or \
            (mode != "approach" and (a.start or a.review)) or (mode == "plan" and not 1 <= a.plan <= 8) or \
            (mode == "approach" and not a.approach.strip()):
        print("agent: --plan K (1..8) or --approach TEXT, each with --bench-task DIR; --start/--review only with --approach",
              file=sys.stderr)
        return 2
    out = Path(a.out)
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        print(f"agent: {out} exists and is not empty", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True, mode=0o750)
    global OUT_DIR
    OUT_DIR = out
    tx = open(out / "transcript.jsonl", "w", encoding="utf-8")

    def record(kind: str, **kw):
        tx.write(Scrub.s(json.dumps({"t": time.strftime("%H:%M:%S", time.gmtime()), "kind": kind, **kw})) + "\n")
        tx.flush()

    usage = {"input": 0, "output": 0, "cached": 0, "reasoning": 0}
    mcp_calls, turns, submitted, served_by = [], 0, None, set()
    btask, sbx_used, sbx_log = None, {"run_tests": 0, "run_bench": 0}, []
    finish = "submit_plan" if mode == "plan" else "submit_change"
    mcp_names = ("context", "budget") if mode == "plan" else MCP_TOOLS
    try:
        ws = Workspace(Path(a.src))
        if mode == "day1":
            task = Path(a.task).read_text("utf-8")
        else:
            btask = load_bench_task(Path(a.bench_task))
            head = (f"Task {btask['id']} ({btask.get('category') or 'task'}). The services that run this code: "
                    f"{', '.join(btask['services'])}. Writable folders: {', '.join(btask['writable'])}.\n\n{btask['prompt'].strip()}")
            if mode == "plan":
                task = head + f"\n\nPlan exactly {a.plan} distinct strategies for this task (submit_plan)."
            else:
                ws.writable = list(btask["writable"])
                task = head + ("\n\nYour approach (the other engineers try the other ones: stick to yours): "
                               + a.approach.strip()[:600])
                if a.start:
                    for p, c in start_files(Path(a.start)).items():
                        text, err = ws.write_file({"path": p, "content": c})
                        if err:
                            raise Fail(f"--start {a.start}: {text}")
                if a.review:
                    task += ("\n\nYour previous version is already in the workspace (read_file shows it). A reviewer read it "
                             "and asks for these fixes before it can go on (fix them, run the tests, submit again):\n\n"
                             + Path(a.review).read_text("utf-8")[:8000])
        if a.feedback:
            task += ("\n\nA previous attempt at this ticket did not compile. The compiler said:\n\n"
                     + Path(a.feedback).read_text("utf-8")[:8000])
        token = Path(MCP_TOKEN_FILE).read_text().strip()
        Scrub.secrets.append(token)
        mcp = MCP(MCP_URL, token)
        mcp.open()
        if mode == "plan":
            tools = LOCAL_TOOLS[:2] + [PLAN_TOOL]
        else:
            tools = list(LOCAL_TOOLS) + (SBX_TOOLS if mode == "approach" else [])
        for t in mcp.tools():
            if t["name"] in mcp_names:
                schema, note = portable_schema(t.get("inputSchema") or {"type": "object"})
                tools.append({"name": "rhobound_" + t["name"], "description": (t.get("description") or "") + note,
                              "schema": schema})
        offered = [t["name"] for t in tools]
        missing = [n for n in mcp_names if "rhobound_" + n not in offered]
        if missing:
            raise Fail(f"rhobound-mcp does not offer {missing}")
        key = read_key()
        Scrub.secrets.append(key)
        system = {"day1": SYSTEM, "plan": SYSTEM_PLAN, "approach": SYSTEM_BENCH}[mode]
        model = Meta(key, system, tools, f"rbd-agent-{out.name}") if PROVIDER == "meta" else Anthropic(key, system, tools)
        log(f"provider {PROVIDER}, model {MODEL} (effort {EFFORT}); tools: {', '.join(offered)}; source {a.src}")
        record("start", provider=PROVIDER, model=MODEL, effort=EFFORT, tools=offered, task=task, mode=mode)
        model.user(task)

        def sandbox(tool: str):
            """run_tests / run_bench: the workspace written to a temporary tree, then sbx.sh (docker, no network)."""
            if sbx_used[tool] >= SBX_CALLS:
                return f"not run: at most {SBX_CALLS} {tool} calls per run", True
            sbx_used[tool] += 1
            smode = "tests" if tool == "run_tests" else "bench"
            work = Path(tempfile.mkdtemp(prefix="sbx-", dir=os.environ.get("RBD_SBX_TMP") or str(out.parent)))
            try:
                for p, c in ws.files.items():
                    if p.startswith("maze/app/"):
                        q = work / "tree" / p
                        q.parent.mkdir(parents=True, exist_ok=True)
                        q.write_text(c, "utf-8")
                env = {k: v for k, v in os.environ.items() if not k.startswith("RBD_AGENT_KEY")}
                r = subprocess.run(["bash", a.sbx, smode, str(work / "tree"), str(Path(a.bench_task).resolve()),
                                    str(work / "out")], capture_output=True, text=True, timeout=3600, env=env)
                try:
                    res = json.loads((work / "out" / "result.json").read_text("utf-8"))
                except (OSError, ValueError):
                    return f"sandbox error (exit {r.returncode}): {r.stderr.strip()[-600:]}", True
            except (OSError, subprocess.TimeoutExpired) as e:
                return f"sandbox error: {type(e).__name__}", True
            finally:
                shutil.rmtree(work, ignore_errors=True)
            bench = res.get("bench") or {}
            sbx_log.append({"turn": turns, "tool": tool, "ok": res.get("ok") is True, "passed": res.get("passed"),
                            "failed": res.get("failed"), "delta_ms": {k: v.get("delta_ms") for k, v in bench.items()}})
            if smode == "tests":
                return (f"{'PASS' if res.get('ok') else 'FAIL'}: {res.get('passed')} passed, {res.get('failed')} failed\n"
                        + str(res.get("output_tail") or "")[-4000:]), res.get("ok") is not True
            lines = []
            for n, v in bench.items():
                b, c = float(v["base_ns"]), float(v["cand_ns"])
                lines.append(f"{n}: main {b:,.0f} ns/op, yours {c:,.0f} ns/op ({(c / b - 1) * 100 if b else 0:+.1f}%), "
                             f"round-to-round spread +-{float(v['spread_ms']) * 1e6:,.0f} ns; allocs/op "
                             f"{v['base_allocs']} -> {v['cand_allocs']}")
            if res.get("ok") is not True:
                lines.append("the benchmark did not complete:\n" + str(res.get("output_tail") or "")[-3000:])
            return "\n".join(lines), res.get("ok") is not True

        nudged = False
        while submitted is None:
            turns += 1
            if turns > MAX_TURNS:
                raise Fail(f"no submit_change after {MAX_TURNS} turns")
            if usage["output"] > MAX_OUTPUT_TOTAL:
                raise Fail(f"more than {MAX_OUTPUT_TOTAL} output tokens without a submit_change")
            t = model.turn()
            for k in usage:
                usage[k] += t.usage.get(k, 0)
            served_by.add(t.served_by or "?")
            record("model", turn=turns, stop=t.raw_stop, served_by=t.served_by, text=t.texts,
                   tool_uses=[{"name": c["name"], "input": c["args"]} for c in t.calls], usage=t.usage)
            for x in t.texts:
                if x and x.strip():
                    log(f"turn {turns}: {x.strip()[:300]}")
            if t.stop == "refusal":
                raise Fail(f"the model declined: {t.raw_stop}")
            if t.stop == "pause":
                continue
            if not t.calls:
                if t.stop == "cut":
                    model.user("Your answer was cut off at the output limit. Continue; write one file per write_file call.")
                    continue
                if nudged:
                    raise Fail(f"the model stopped ({t.raw_stop}) without submit_change")
                nudged = True
                model.user("Call submit_plan with the strategies." if mode == "plan" else
                           "Call submit_change when the change is complete. If you cannot make it, say why in one "
                           "paragraph and call submit_change with service \"none\".")
                continue
            results = []
            for c in t.calls:
                name, args = c["name"], c["args"]
                if t.stop == "cut":
                    text, err = "not run: your answer was cut off at the output limit; send this call again", True
                elif args is None:
                    text, err = "not run: the arguments are not a JSON object; send this call again", True
                elif name not in offered:
                    text, err = f"unknown tool {name}", True
                elif name in ("run_tests", "run_bench"):
                    text, err = sandbox(name)
                    log(f"turn {turns}: {name}: {text[:160]}")
                elif name == "submit_plan":
                    text, err = check_plan(args, a.plan, {m["tool"] for m in mcp_calls})
                    if not err:
                        submitted = {"strategies": [{"tag": s["tag"], "line": s["line"].strip()} for s in args["strategies"]]}
                elif name == "list_files":
                    text, err = ws.list_files(args)
                elif name == "read_file":
                    text, err = ws.read_file(args)
                elif name == "write_file":
                    text, err = ws.write_file(args)
                    log(f"turn {turns}: write_file {args.get('path')!r}: {text[:120]}")
                elif name == "submit_change":
                    svc, title, summ = args.get("service"), str(args.get("title", "")).strip(), str(args.get("summary", "")).strip()
                    svc = svc if isinstance(svc, str) else repr(svc)
                    if svc == "none":
                        raise Fail(f"the model gave up: {summ[:1000]}")
                    allowed = btask["services"] if btask else ws.services
                    if svc not in allowed:
                        text, err = f"refused: service must be one of {allowed}", True
                    elif not ws.changed():
                        text, err = "refused: no file changed", True
                    elif not title or len(title) > 72 or "\n" in title:
                        text, err = "refused: title must be one line of 1-72 characters", True
                    elif not summ or len(summ) > 1000:
                        text, err = "refused: summary must be 1-1000 characters", True
                    else:
                        submitted = {"service": svc, "title": title, "summary": summ}
                        text, err = "submitted", False
                elif name.startswith("rhobound_") and name[9:] in MCP_TOOLS and (
                        len(mcp_calls) >= MCP_PER_RUN or sum(1 for m in mcp_calls if m["turn"] == turns) >= MCP_PER_TURN):
                    text, err = f"not run: the MCP budget is {MCP_PER_TURN} calls per turn and {MCP_PER_RUN} per run", True
                elif name.startswith("rhobound_") and name[9:] in MCP_TOOLS:
                    if name == "rhobound_predict":
                        args = {**args, "repo": REPO, "branch": BRANCH}   # a copy: the history keeps the model's input
                    text, err = mcp.call(name[9:], args)
                    try:
                        parsed = json.loads(text) if len(text) <= 8000 else text[:4000] + " [cut]"
                    except ValueError:
                        parsed = text[:4000]
                    mcp_calls.append({"turn": turns, "tool": name[9:], "arguments": args, "is_error": err, "result": parsed})
                    log(f"turn {turns}: {name} {json.dumps(args)[:160]} -> {'ERROR ' if err else ''}{text[:160]}")
                else:
                    text, err = f"unknown tool {name}", True
                if len(text) > RESULT_CHARS:
                    text = text[:RESULT_CHARS] + f"\n[truncated: {len(text)} characters; use rhobound_explain or detail=summary]"
                record("tool", turn=turns, name=name, is_error=err, result=text[:4000])
                results.append((c["id"], text, err))
            model.results(results)
    except Fail as e:
        record("fail", error=str(e))
        log(f"FAILED: {e}")
        res = {"step": "agent", "ok": False, "error": Scrub.s(str(e)), "turns": turns, "usage": usage,
               "provider": PROVIDER, "model": MODEL}
        (out / "result.json").write_text(Scrub.s(json.dumps(res, indent=1)) + "\n")
        print(Scrub.s(json.dumps(res)))
        return 1

    if mode == "plan":
        if any(k and k in json.dumps(submitted) for k in Scrub.secrets):
            res = {"step": "agent", "ok": False, "error": "the plan holds a secret: nothing kept", "mode": mode, "turns": turns,
                   "usage": usage, "provider": PROVIDER, "model": MODEL}
            (out / "result.json").write_text(json.dumps(res, indent=1) + "\n")
            print(json.dumps(res))
            return 1
        plan = {"schema": "rbd.bench-plan/v1", "task": btask["id"], "k": a.plan, **submitted, "turns": turns, "usage": usage,
                "provider": PROVIDER, "model": MODEL, "served_by": sorted(served_by), "mcp_calls": mcp_calls}
        (out / "plan.json").write_text(Scrub.s(json.dumps(plan, indent=1)) + "\n")
        res = {"step": "agent", "ok": True, "mode": mode, "strategies": [s["tag"] for s in submitted["strategies"]],
               "turns": turns, "mcp_calls": [c["tool"] for c in mcp_calls], "usage": usage, "provider": PROVIDER,
               "model": MODEL, "served_by": sorted(served_by)}
        (out / "result.json").write_text(Scrub.s(json.dumps(res, indent=1)) + "\n")
        record("done", **res)
        print(Scrub.s(json.dumps(res)))
        return 0
    leaked = [p for p in ws.changed() if any(k and k in ws.files[p] for k in Scrub.secrets)] + \
        [f for f in ("title", "summary") if any(k and k in submitted[f] for k in Scrub.secrets)]
    if leaked:
        res = {"step": "agent", "ok": False, "error": f"the model's output holds a secret ({', '.join(leaked)}): nothing kept",
               "turns": turns, "usage": usage, "provider": PROVIDER, "model": MODEL}
        record("fail", error=res["error"])
        (out / "result.json").write_text(json.dumps(res, indent=1) + "\n")
        print(json.dumps(res))
        return 1
    files = []
    for p in ws.changed():
        dst = out / "files" / p
        dst.parent.mkdir(parents=True, exist_ok=True)
        b = ws.files[p].encode()
        dst.write_bytes(b)
        files.append({"path": p, "sha256": hashlib.sha256(b).hexdigest(), "bytes": len(b), "new": p not in ws.orig})
    base = (Path(a.src).parent / "main.sha")
    man = {"schema": "rbd.agent-change/v1", "provider": PROVIDER, "model": MODEL, "served_by": sorted(served_by),
           "effort": EFFORT, "base_sha": base.read_text().strip()[:64] if base.exists() else None, **submitted,
           "files": files, "turns": turns, "usage": usage, "mcp_calls": mcp_calls}
    if mode == "approach":
        man.update(task=btask["id"], approach=a.approach.strip()[:600], sandbox=sbx_log, revised=bool(a.start))
        req = {"schema": "rbd.change-request/v2", "services": list(btask["services"]), "summary": submitted["summary"]}
        if btask.get("base"):
            req["base"] = btask["base"]
    else:
        req = {"schema": "rbd.change-request/v1", "services": [submitted["service"]], "summary": submitted["summary"]}
    (out / "manifest.json").write_text(Scrub.s(json.dumps(man, indent=1)) + "\n")
    (out / "rhobound-change.json").write_text(json.dumps(req) + "\n")
    (out / "change.patch").write_text(Scrub.s(ws.patch()))
    res = {"step": "agent", "ok": True, "service": submitted["service"], "title": submitted["title"], "files": len(files),
           "turns": turns, "mcp_calls": [c["tool"] for c in mcp_calls], "usage": usage, "provider": PROVIDER,
           "model": MODEL, "served_by": sorted(served_by)}
    (out / "result.json").write_text(Scrub.s(json.dumps(res, indent=1)) + "\n")
    record("done", **res)
    print(Scrub.s(json.dumps(res)))
    return 0


OUT_DIR = None

if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as e:   # an unexpected error: its traceback, scrubbed (never the key or the MCP token)
        print(Scrub.s(traceback.format_exc()), file=sys.stderr)
        res = {"step": "agent", "ok": False, "error": Scrub.s(f"crashed: {type(e).__name__}: {e}")[:500], "provider": PROVIDER,
               "model": MODEL}
        if OUT_DIR is not None:
            try:
                (OUT_DIR / "result.json").write_text(json.dumps(res, indent=1) + "\n")
            except OSError:
                pass
        print(json.dumps(res))
        sys.exit(1)
