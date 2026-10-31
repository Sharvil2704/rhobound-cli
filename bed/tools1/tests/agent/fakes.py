"""Stand-ins for t_agent.sh: a scripted Messages API and a small rhobound-mcp (both HTTP on 127.0.0.1, stdlib).
    python3 -I fakes.py api SCRIPT.json PORTFILE LOG     each POST answers the next response of SCRIPT (a list); every request
                                                          body is appended to LOG (one JSON per line) with its headers.
                                                          SCRIPT may be a dict of lists instead: the request's
                                                          prompt_cache_key picks the list ("*" when absent or unknown), so
                                                          concurrent runs (tools1/bench) each get their own sequence
    python3 -I fakes.py mcp TOKEN PORTFILE LOG           initialize / notifications/initialized / tools/list / tools/call, SSE answers
"""
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode = sys.argv[1]
TOOLS = [{"name": n, "description": "fake " + n, "inputSchema": {"type": "object", "$defs": {"Env": {"type": "string", "pattern": "^[a-z]+$"}},
          "properties": {"env": {"$ref": "#/$defs/Env", "description": "an env"},
          "fit_id": {"type": "string"}, "service": {"type": "string"}, "changes": {"type": "array"}, "repo": {"type": "string"},
          "branch": {"type": "string"}, "section": {"type": "string"}}, "oneOf": [{"required": ["env"]}, {"required": ["fit_id"]}],
          "$schema": "https://json-schema.org/draft/2020-12/schema"}} for n in ("context", "budget", "predict", "explain", "fit_start", "job_status")]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")

    def send(self, code, obj, ctype="application/json", extra=None):
        raw = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        b = self.body()
        with open(LOG, "a") as f:
            f.write(json.dumps({"headers": {k.lower(): v for k, v in self.headers.items()}, "body": b}) + "\n")
        if mode == "api":
            with LOCK:
                routed = isinstance(SCRIPT["r"], dict)
                route = b.get("prompt_cache_key") if routed else None
                if routed and route not in SCRIPT["r"]:
                    route = "*"
                seq = SCRIPT["r"].get(route, []) if routed else SCRIPT["r"]
                i = SCRIPT["i"].get(route, 0)
                SCRIPT["i"][route] = i + 1
            if i >= len(seq):
                return self.send(500, {"type": "error", "error": {"type": "api_error", "message": "script exhausted (%s)" % route}})
            r = seq[i]
            if "status" in r:
                return self.send(r["status"], r["body"], extra={"retry-after": "0", **r.get("headers", {})})
            return self.send(200, r)
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.send(401, {"error": "unauthorized"})
        if "id" not in b:
            self.send_response(202); self.end_headers(); return
        m = b.get("method")
        if m == "initialize":
            res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "0"}}
        elif m == "tools/list":
            res = {"tools": TOOLS}
        elif m == "tools/call":
            n, a = b["params"]["name"], b["params"]["arguments"]
            if n == "context":
                res = {"structuredContent": {"fit_id": "fit_abc123", "services": {"auth": {"utilization": 0.71, "leverage": 2.4}}},
                       "content": [{"type": "text", "text": "{}"}]}
            elif n == "predict":
                res = {"structuredContent": {"prediction_id": "pr_1", "verdict_preview": "inconclusive", "echo": a}, "content": []}
            else:
                res = {"content": [{"type": "text", "text": "fake %s ok" % n}]}
        else:
            return self.send(200, {"jsonrpc": "2.0", "id": b["id"], "error": {"code": -32601, "message": "no " + m}})
        sse = ("event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": b["id"], "result": res}) + "\n\n").encode()
        self.send(200, sse, "text/event-stream", {"Mcp-Session-Id": "sess-1"})


if mode == "api":
    SCRIPT = {"r": json.load(open(sys.argv[2])), "i": {}}; PORTFILE, LOG = sys.argv[3], sys.argv[4]
else:
    TOKEN, PORTFILE, LOG = sys.argv[2], sys.argv[3], sys.argv[4]
LOCK = threading.Lock()
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
