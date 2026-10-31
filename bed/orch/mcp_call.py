"""A minimal MCP client (stdlib) for rhobound-mcp's HTTP transport, through the ssh tunnel (orch/rbd.sh tunnel / rbd.sh mcp).

    RBD_MCP_TOKEN=... python3 -I mcp_call.py [--url http://127.0.0.1:8765/mcp] list
    RBD_MCP_TOKEN=... python3 -I mcp_call.py [--url ...] call TOOL '{"env": "prod"}'

The bearer token comes from the environment only (never an argument). initialize -> notifications/initialized -> the
request; answers in JSON or as server-sent events. Prints the result as one JSON document; exit 0, 1 on a tool error
(isError) or a JSON-RPC error, 2 when the server cannot be reached or answers HTTP errors.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

PROTOCOL = "2025-06-18"


class Client:
    def __init__(self, url: str, token: str, timeout: float):
        self.url, self.token, self.timeout = url, token, timeout
        self.sid, self.version, self.next_id = None, PROTOCOL, 1

    def _post(self, body: dict):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
             "Authorization": f"Bearer {self.token}", "MCP-Protocol-Version": self.version}
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST", headers=h)
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            self.sid = r.headers.get("Mcp-Session-Id") or self.sid
            raw, ctype = r.read().decode("utf-8", "replace"), r.headers.get("Content-Type", "")
        if "id" not in body:
            return None
        msgs = []
        if ctype.startswith("text/event-stream"):
            for block in raw.split("\n\n"):
                data = "\n".join(line[5:].lstrip() for line in block.splitlines() if line.startswith("data:"))
                if data:
                    msgs.append(json.loads(data))
        elif raw.strip():
            msgs.append(json.loads(raw))
        for m in msgs:
            if isinstance(m, dict) and m.get("id") == body["id"]:
                return m
        raise RuntimeError(f"no answer to request {body['id']} in: {raw[:300]}")

    def request(self, method: str, params: dict | None = None) -> dict:
        self.next_id += 1
        return self._post({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}})

    def open(self):
        m = self._post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": PROTOCOL, "capabilities": {},
                                   "clientInfo": {"name": "rbd-orchestrator", "version": "1"}}})
        if "error" in m:
            raise RuntimeError(f"initialize: {m['error']}")
        self.version = m["result"].get("protocolVersion", PROTOCOL)
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return m["result"]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://127.0.0.1:8765/mcp")
    p.add_argument("--timeout", type=float, default=300)
    p.add_argument("what", choices=("list", "call"))
    p.add_argument("tool", nargs="?")
    p.add_argument("arguments", nargs="?", default="{}")
    a = p.parse_args()
    token = os.environ.get("RBD_MCP_TOKEN", "").strip()
    if not token:
        print("mcp_call: RBD_MCP_TOKEN is not set", file=sys.stderr)
        return 2
    c = Client(a.url, token, a.timeout)
    try:
        c.open()
        if a.what == "list":
            m = c.request("tools/list")
            if "error" in m:
                print(json.dumps(m["error"]), file=sys.stderr)
                return 1
            print(json.dumps([{"name": t["name"], "description": t.get("description", "")[:160]} for t in m["result"]["tools"]], indent=1))
            return 0
        if not a.tool:
            print("mcp_call: call TOOL [ARGUMENTS_JSON]", file=sys.stderr)
            return 2
        m = c.request("tools/call", {"name": a.tool, "arguments": json.loads(a.arguments)})
    except urllib.error.HTTPError as e:
        print(f"mcp_call: HTTP {e.code} from {a.url}: {e.read()[:300]!r}", file=sys.stderr)
        return 2
    except (urllib.error.URLError, OSError) as e:
        print(f"mcp_call: cannot reach {a.url}: {e} (is the tunnel open? orch/rbd.sh tunnel)", file=sys.stderr)
        return 2
    if "error" in m:
        print(json.dumps(m["error"], indent=1))
        return 1
    r = m["result"]
    out = r.get("structuredContent")
    if out is None:
        texts = [x.get("text", "") for x in r.get("content", []) if x.get("type") == "text"]
        try:
            out = json.loads(texts[0]) if len(texts) == 1 else texts
        except ValueError:
            out = texts
    print(json.dumps(out, indent=1))
    return 1 if r.get("isError") else 0


if __name__ == "__main__":
    sys.exit(main())
