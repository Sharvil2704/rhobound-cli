"""export.py: the data side of tools1/muse/task.sh and hidden.sh (python3 -I; root on rbd-tools1, installed as
/opt/muse/export.py). Everything it reads from a Muse user's home (the workspace, Muse's events and session log, the
rhobound-mcp preview log) is untrusted data: every path is opened component by component with O_NOFOLLOW (a link is never
followed, not even one above the workspace), only regular files with one link are read, sizes and counts are capped, and
nothing it reads is ever run. task.sh calls it only after the session has ended and the user's processes are killed.

  export.py prompt --task TASK_MD [--iter N --feedback FILE]          the session's prompt on stdout (same text both arms)
  export.py previews --home HOME                                      rows in HOME's rhobound-mcp preview logs (JSON)
  export.py export --ws WS --base BASE --main-sha SHA --session S --home HOME --ticket-dir TD --arm R|C --ticket T
                   --iter N --run RUN --user U --stage OUTTMP --out OUT --raw RAWDIR --rc RC --t0 EPOCH --t1 EPOCH
                   --steps N [--commit SHA] [--commit-note TEXT] [--base-commit SHA] [--previews-before FILE]
      OUTTMP (new) gets the OUT folder of tools1/agent/agent.py, exactly what orch/agent_take.sh checks: result.json,
      manifest.json (rbd.agent-change/v1), files/<path>, rhobound-change.json (rbd.change-request/v1, or v2 when the
      service's image runs 2-3 services), change.patch (for reading), title.txt, plus usage.json. A change that cannot be
      carried (no .go change, more than 8 files, a deleted .go file, a link, a file over 100000 bytes, a build constraint
      or directive agent_take refuses, an address or 12-digit number) writes result.json {ok: false, error, errors} and
      usage.json only. RAWDIR gets size-capped copies of events.jsonl and session.jsonl (never into OUT: agent_take's 5 MB).
      Last stdout line: {"step": "muse-task", "ok": ...}. Exit 0 (ok or not: result.json says), 2 usage.
  export.py events --events EVENTS_JSONL [--session-log SESSION_JSONL]
      what export would read from a session's logs (model steps, tokens, tool calls by kind, MCP calls offered and made,
      hook records) as JSON, without exporting anything: to check the parser against a live session's real logs.
  export.py hidden-copy --base BASE --out OUT --hidden HDIR --dest DEST
      DEST/maze/app = BASE/maze/app + OUT's files (as its manifest lists them, sha256 checked) + the ticket's hidden tests
      (HDIR/maze/app/**/*_test.go). Prints {"packages": ["./internal/svc/x", ...], "tests": [Test names], "overwrote"}.
  export.py hidden-summary --json GOTEST_JSON --rc RC --out FILE --copy COPY_JSON --run RUN --iter N --ticket T --arm A
                           [--verify-rc N] [--strip PREFIX] [--wall S] [--go VERSION] [--error TEXT]
      go test -json output -> hidden.json {pass, failed, ran, passed, missing, build_failed, output_tail, error, ...}:
      pass only when go test exits 0 and every Test function of the hidden files passed.
"""
import argparse
import difflib
import hashlib
import ipaddress
import json
import os
import re
import stat
import sys
import time

GO_PATH = re.compile(r"maze/app/(?:[A-Za-z0-9_][A-Za-z0-9_.-]*/)*[A-Za-z0-9_][A-Za-z0-9_.-]*\.go")   # agent_take's
MAX_FILES, MAX_FILE = 8, 100000          # agent_take: 1..8 files, each at most 100000 bytes
HASH_CAP = 8 << 20                       # files above this are compared by size only
READ_BUDGET = 512 << 20                  # bytes read from one tree in all
MAX_ENTRIES, MAX_DEPTH = 200000, 48
LOG_CAP = 64 << 20                       # events.jsonl / session.jsonl bytes read (and archived)
FEEDBACK_CAP = 32000
LEAD = ("Your previous attempt at this ticket was not accepted. Your work so far is committed in this repository: "
        "continue from it and revise it. What happened:")
MODEL, PROVIDER, SERVED_BY, EFFORT = "muse-spark-1.3", "muse-code", "muse-code", "high"
BUILD_NAMES = {"go.mod", "go.sum", "go.work", "go.work.sum"}
BUILD_EXT = (".s", ".S", ".sx", ".c", ".h", ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx", ".m", ".f", ".F", ".for",
             ".f90", ".syso", ".swig", ".swigcxx")
DIRECTIVE = re.compile(r"^\s*//\s*(?:go:build|\+build)\b.*$", re.M)                                      # agent_take's
BANNED = re.compile(r"^\s*//\s*(?:go:embed|go:linkname|go:cgo_\w+|export\s)|^\s*import\s+(?:\(\s*)?\"C\"|^\s*\"C\"\s*$", re.M)
HIDDEN_CHARS = "﻿  ‮⁦⁧⁨⁩‪‫‬‭"
SKIP_CI = re.compile(r"\[\s*(?:skip\s+ci|ci\s+skip|no\s+ci|skip\s+actions|actions\s+skip)\s*\]|skip-checks\s*:\s*true", re.I)
IP_OK = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "0.0.0.0/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                           "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
IP_RE = re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])(?!\.[0-9])")                      # agent_take's
N12_RE = re.compile(r"(?<![0-9A-Za-z_])(?<![0-9]\.)[0-9]{12}(?![0-9A-Za-z_])(?!\.[0-9])")
QUAD = re.compile(r"[0-9]{1,3}(?:\.[0-9]{1,3}){3}")
MCP_RE = re.compile(r"mcp__rhobound__([A-Za-z0-9_]{1,40})")
PLAIN = re.compile(r"[A-Za-z0-9._:/-]{1,64}")
UUIDISH = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


class Refuse(Exception):
    pass


# ------------------------------------------------------------------------------------------------ reading without links
O_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
O_FILE = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


def open_dir(path):
    """A directory fd for an absolute path, every component opened with O_NOFOLLOW (a link anywhere: OSError)."""
    if not os.path.isabs(path):
        raise Refuse("not an absolute path: %r" % path)
    fd = os.open("/", O_DIR)
    try:
        for part in [p for p in path.split("/") if p]:
            if part in (".", ".."):
                raise Refuse("a . or .. in %r" % path)
            nfd = os.open(part, O_DIR, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_at(dfd, name, cap):
    """(bytes, size, truncated) of a regular one-link file NAME in dfd, at most cap bytes; Refuse otherwise."""
    fd = os.open(name, O_FILE, dir_fd=dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise Refuse("not a plain file: %s" % name)
        chunks, n = [], 0
        while n <= cap:
            b = os.read(fd, min(1 << 20, cap + 1 - n))
            if not b:
                break
            chunks.append(b)
            n += len(b)
        data = b"".join(chunks)
        return data[:cap], st.st_size, len(data) > cap
    finally:
        os.close(fd)


def read_path(path, cap):
    """read_at for an absolute file path (its folders opened without following links). None when missing or refused."""
    d, n = os.path.split(path)
    try:
        dfd = open_dir(d)
    except (OSError, Refuse):
        return None
    try:
        return read_at(dfd, n, cap)
    except (OSError, Refuse):
        return None
    finally:
        os.close(dfd)


class Tree:
    """A tree's regular files {rel: (size, sha256 or None, content or None)}, its links and special entries."""

    def __init__(self):
        self.files, self.links, self.special, self.unreadable = {}, [], [], []
        self.entries, self.read = 0, 0


def scan(root, keep=lambda rel: False, skip_top=(".git",)):
    """Walk ROOT without following any link. keep(rel): keep that file's content (capped at MAX_FILE + 1 bytes)."""
    t = Tree()
    top = open_dir(root)

    def walk(dfd, prefix, depth):
        if depth > MAX_DEPTH:
            raise Refuse("the tree is deeper than %d folders" % MAX_DEPTH)
        for name in sorted(os.listdir(dfd)):
            t.entries += 1
            if t.entries > MAX_ENTRIES:
                raise Refuse("the tree has more than %d entries" % MAX_ENTRIES)
            if depth == 0 and name in skip_top:
                continue
            rel = prefix + name
            try:
                st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            except OSError:
                t.unreadable.append(rel)
                continue
            if stat.S_ISDIR(st.st_mode):
                try:
                    sub = os.open(name, O_DIR, dir_fd=dfd)
                except OSError:
                    t.unreadable.append(rel + "/")
                    continue
                try:
                    walk(sub, rel + "/", depth + 1)
                finally:
                    os.close(sub)
            elif stat.S_ISLNK(st.st_mode):
                t.links.append(rel)
            elif not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                t.special.append(rel)
            else:
                want = keep(rel)
                if st.st_size > HASH_CAP and not want:
                    t.files[rel] = (st.st_size, None, None)
                    continue
                if t.read + st.st_size > READ_BUDGET:
                    raise Refuse("more than %d MB of files to read" % (READ_BUDGET >> 20))
                try:
                    data, size, trunc = read_at(dfd, name, MAX_FILE if want else HASH_CAP)
                except (OSError, Refuse):
                    t.special.append(rel)
                    continue
                t.read += len(data)
                sha = None if trunc else hashlib.sha256(data).hexdigest()
                t.files[rel] = (size, sha, data if want and not trunc else None)

    try:
        walk(top, "", 0)
    finally:
        os.close(top)
    return t


# --------------------------------------------------------------------------------------------------------- text helpers
def clean(s, cap=300):
    """An agent-influenced string made safe for a record: printable (newlines kept), no address or 9+ digit run."""
    s = "".join(c if (c.isprintable() or c == "\n") else " " for c in str(s))
    s = QUAD.sub("[address]", s)
    s = re.sub(r"[0-9]{9,}", "[number]", s)
    s = SKIP_CI.sub("(ci token removed)", s)
    return s[:cap]


def leaks(text):
    """agent_take's leak scan (a public IPv4, a dotted quad that does not parse, a 12-digit number) over TEXT."""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in IP_RE.finditer(line):
            try:
                a = ipaddress.ip_address(m.group())
            except ValueError:
                out.append("line %d: a dotted number that is not an address" % i)
                continue
            if not any(a in n for n in IP_OK):
                out.append("line %d: a public IPv4 address" % i)
        if N12_RE.search(line):
            out.append("line %d: a 12-digit number" % i)
    return out


def read_text_file(path, cap):
    r = read_path(path, cap)
    if r is None:
        return None
    return r[0].decode("utf-8", "replace")


def ticket_title(td, ticket):
    meta = load_json(os.path.join(td, "meta.json"), 65536) or {}
    t = meta.get("title") if isinstance(meta, dict) else None
    if not isinstance(t, str) or not t.strip():
        t = ticket
        for line in (read_text_file(os.path.join(td, "task.md"), 65536) or "").splitlines():
            line = line.strip().lstrip("#").strip()
            if line:
                t = re.sub(r"^(?i:title)\s*:\s*", "", line)
                break
    return " ".join("".join(c for c in t if c.isprintable()).split())


def load_json(path, cap):
    r = read_path(path, cap)
    if r is None or r[2]:
        return None
    try:
        return json.loads(r[0].decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


# --------------------------------------------------------------------------------------------------------------- prompt
def cmd_prompt(a):
    task = read_text_file(os.path.abspath(a.task), 65536)
    if task is None or not task.strip():
        sys.exit("export.py prompt: cannot read the ticket's task.md")
    out = task.rstrip("\n") + "\n"
    if a.iter > 1:
        if not a.feedback:
            sys.exit("export.py prompt: iteration %d needs the feedback file" % a.iter)
        r = read_path(os.path.abspath(a.feedback), FEEDBACK_CAP)
        if r is None:
            sys.exit("export.py prompt: cannot read the feedback file (a regular file, no link)")
        fb = r[0].decode("utf-8", "replace")
        fb = "".join(c if (c.isprintable() or c in "\n\t") else " " for c in fb).strip("\n")
        if not fb.strip():
            sys.exit("export.py prompt: the feedback file is empty")
        if r[2]:
            fb += "\n[the feedback was cut at %d bytes]" % FEEDBACK_CAP
        out += "\n---\n\n" + LEAD + "\n\n" + fb + "\n"
    elif a.feedback:
        sys.exit("export.py prompt: iteration 1 takes no feedback (both arms start from the same text)")
    sys.stdout.write(out)


# ------------------------------------------------------------------------------------------------------------- previews
def preview_rows(home):
    d = os.path.join(home, ".local/state/rhobound-mcp/server/previews")
    rows = {}
    try:
        dfd = open_dir(d)
    except (OSError, Refuse):
        return {"found": False, "files": {}}
    try:
        for n in sorted(os.listdir(dfd))[:200]:
            if not n.endswith(".jsonl"):
                continue
            try:
                data, _, _ = read_at(dfd, n, LOG_CAP)
            except (OSError, Refuse):
                continue
            rows[clean(n, 120)] = data.count(b"\n")
    finally:
        os.close(dfd)
    return {"found": True, "files": rows}


def cmd_previews(a):
    print(json.dumps(preview_rows(os.path.abspath(a.home)), sort_keys=True))


# ----------------------------------------------------------------------------------------------------- Muse's event logs
def small(v, depth=0, budget=None):
    """A JSON value cut to numbers, booleans and short clean strings (depth 6, 300 leaves): records, not data dumps."""
    budget = budget if budget is not None else [300]
    if budget[0] <= 0 or depth > 6:
        return None
    if isinstance(v, bool) or v is None or isinstance(v, (int, float)):
        budget[0] -= 1
        return v
    if isinstance(v, str):
        budget[0] -= 1
        return clean(v, 120)
    if isinstance(v, list):
        return [small(x, depth + 1, budget) for x in v[:40]]
    if isinstance(v, dict):
        return {clean(k, 60): small(x, depth + 1, budget) for k, x in list(v.items())[:60]}
    return None


def tokens_of(usage):
    """Token totals from the run.usage payload. Its shape is not documented (per model, maybe with an aggregate): the
    numeric leaves whose key path names tokens, classified by their key; when some sit under a "total"/"sum" folder,
    only those count (no double counting of an aggregate and its parts). The raw payload is kept beside this."""
    leaves = []

    def walk(v, path):
        if isinstance(v, dict):
            for k, x in v.items():
                walk(x, path + [str(k).lower()])
        elif isinstance(v, list):
            for x in v:
                walk(x, path)
        elif isinstance(v, (int, float)) and not isinstance(v, bool) and "token" in ".".join(path):
            leaves.append((path, int(v)))

    walk(usage, [])
    agg = [(p, v) for p, v in leaves if any(("total" in s or "sum" in s or "aggregate" in s) for s in p[:-1])]
    tot, seen = {"input": 0, "output": 0, "cached": 0, "reasoning": 0, "total": 0}, set()
    for path, v in (agg or leaves):
        leaf, p = path[-1], ".".join(path)
        for cat, keys in (("total", ("total",)), ("cached", ("cache",)), ("reasoning", ("reasoning", "thinking")),
                          ("input", ("input", "prompt")), ("output", ("output", "completion"))):
            if any(k in leaf for k in keys) or (leaf in ("tokens", "count", "value") and any(k in p for k in keys)):
                tot[cat] += v
                seen.add(cat)
                break
    return {k: (tot[k] if k in seen else None) for k in tot}


def session_ids(v, out, key=""):
    """Session ids in a session.* payload: a string under a key naming a session, or {"kind": "session", "id"}."""
    if isinstance(v, dict):
        if v.get("kind") == "session" and isinstance(v.get("id"), str):
            out.append(v["id"])
        for k, x in v.items():
            session_ids(x, out, str(k).lower())
    elif isinstance(v, list):
        for x in v:
            session_ids(x, out, key)
    elif isinstance(v, str) and "session" in key and UUIDISH.fullmatch(v):
        out.append(v)


def strings_in(v, keys, out):
    if isinstance(v, dict):
        for k, x in v.items():
            if isinstance(x, str) and k in keys:
                out.append(x)
            else:
                strings_in(x, keys, out)
    elif isinstance(v, list):
        for x in v:
            strings_in(x, keys, out)


def parse_events(data):
    """Muse's --json events (one record a line: payload_type, payload, stream, ...) -> the session's numbers."""
    kinds, stages, blobs, order = {}, {}, {}, []
    offered, sessions = set(), {}
    usage, terminal, texts = None, None, []
    lines = bad = tool_results = 0
    for raw in data.splitlines():
        if not raw.strip():
            continue
        lines += 1
        try:
            e = json.loads(raw)
        except ValueError:
            bad += 1
            continue
        if not isinstance(e, dict):
            bad += 1
            continue
        pt = e.get("payload_type") if isinstance(e.get("payload_type"), str) else ""
        p = e.get("payload") if isinstance(e.get("payload"), dict) else {}
        st = e.get("stream") if isinstance(e.get("stream"), dict) else {}
        if st.get("kind") == "session" and isinstance(st.get("id"), str):
            sessions[st["id"]] = sessions.get(st["id"], 0) + 1
        if pt == "run.model.configured":
            offered |= set(MCP_RE.findall(json.dumps(p)))
        elif pt.startswith("task.lifecycle."):
            stage = pt.rsplit(".", 1)[1]
            ev = p.get("event") if isinstance(p.get("event"), dict) else {}
            tid = p.get("task_id") or ev.get("task_id")
            tk = ev.get("task_kind") or p.get("task_kind")
            if not isinstance(tid, str):
                continue
            if tid not in stages:
                stages[tid] = set()
                order.append(tid)
            stages[tid].add(stage)
            if isinstance(tk, str):
                kinds[tid] = tk
            if stage not in ("output", "status", "tool_output_ref") and len(blobs.get(tid, "")) < 16384:
                blobs[tid] = blobs.get(tid, "") + json.dumps(p)[:4096]   # never a tool's output: names in data
        elif pt == "tool.result":
            tool_results += 1
        elif pt == "run.usage":
            usage = p
        elif pt.startswith("run.terminal."):
            terminal = {"type": clean(pt, 80), "payload": small(p)}
        elif pt == "run.output.delta":
            strings_in(p, ("delta", "text", "content"), texts)
        elif pt.startswith("session."):
            ids = []
            session_ids(p, ids)
            for s in ids:
                sessions.setdefault(s, 0)
    by_kind = {}
    for tid in order:
        k = clean(kinds.get(tid, "unknown"), 80)
        d = by_kind.setdefault(k, {})
        for s in stages[tid]:
            d[s] = d.get(s, 0) + 1
    model_kinds = [k for k in by_kind if k.startswith("model.")]
    mcp = []
    for tid in order:   # an MCP call is a tool task: its kind says mcp, or its (non-output) records name mcp__rhobound__*
        k = kinds.get(tid, "")
        if not (k.startswith("tool.") or "mcp" in k.lower()) or k.startswith(("model.", "reminder.")):
            continue
        m = MCP_RE.search(k) or MCP_RE.search(blobs.get(tid, ""))
        if m or "mcp" in k.lower():
            name = m.group(1) if m else (re.sub(r"[^A-Za-z0-9_]", "_", k.split(".")[-1])[:40] or "unknown")
            mcp.append({"tool": name if PLAIN.fullmatch(name) else "unknown", "task_kind": clean(k, 80),
                        "stages": sorted(stages[tid])})
    text = "".join(texts)
    return {
        "lines": lines, "bad_lines": bad, "tool_results": tool_results,
        "model_steps": sum(by_kind[k].get("proposed", 0) for k in model_kinds),
        "model_steps_completed": sum(by_kind[k].get("completed", 0) for k in model_kinds),
        "tasks_by_kind": by_kind,
        "tool_calls_by_kind": {k: v.get("proposed", 0) for k, v in by_kind.items() if k.startswith("tool.") or "mcp" in k},
        "mcp_offered": sorted(offered), "mcp_calls": mcp, "run_usage": small(usage) if usage is not None else None,
        "tokens": tokens_of(usage) if usage is not None else None, "terminal": terminal,
        "sessions": sorted(sessions, key=lambda s: -sessions[s]), "final_text": text[-6000:],
    }


def parse_hooks(data):
    """Muse's session log -> its hook runs, and the MCP tools it offered (the runtime.mcp_tool_identity_catalog
    record: the --json stream does not carry it)."""
    recs, offered = [], set()
    for raw in data.splitlines():
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("payload_type") == "runtime.mcp_tool_identity_catalog":
            cat = e.get("payload") if isinstance(e.get("payload"), dict) else {}
            for x in cat.get("entries") if isinstance(cat.get("entries"), list) else []:
                cid = x.get("canonical_id") if isinstance(x, dict) else None
                if isinstance(cid, str) and MCP_RE.fullmatch(cid):
                    offered.add(MCP_RE.fullmatch(cid).group(1))
        p = e.get("payload") if isinstance(e, dict) and isinstance(e.get("payload"), dict) else {}
        ev = p.get("event") if isinstance(p.get("event"), dict) else None
        if not ev or ev.get("kind") not in ("hook_run_started", "hook_run_terminal"):
            continue
        origin = ev.get("origin") if isinstance(ev.get("origin"), dict) else {}
        r = {"kind": clean(ev.get("kind"), 40), "event": clean(ev.get("event", ""), 40),
             "hook_key": clean(ev.get("hook_key", ""), 120), "plugin": clean(origin.get("plugin_id", ""), 60)}
        if ev.get("kind") == "hook_run_terminal":
            ec = ev.get("exit_code")
            r.update(exit_code=ec if isinstance(ec, int) and not isinstance(ec, bool) else None,
                     effects=[clean(x, 40) for x in ev.get("effects") or [] if isinstance(x, str)][:8],
                     duration_ms=ev.get("duration_ms") if isinstance(ev.get("duration_ms"), (int, float)) else None,
                     error=None if ev.get("error") is None else clean(json.dumps(ev.get("error")), 300))
        recs.append(r)
    summ = {}
    for r in recs:
        s = summ.setdefault(r["event"] or "?", {"started": 0, "exit_codes": [], "effects": []})
        if r["kind"] == "hook_run_started":
            s["started"] += 1
        else:
            s["exit_codes"].append(r.get("exit_code"))
            s["effects"].append(r.get("effects") or [])
    stop_blocked = sum(1 for r in recs if r["kind"] == "hook_run_terminal" and r["event"] == "Stop"
                       and "blocked" in (r.get("effects") or []))
    return {"records": [r for r in recs if r["kind"] == "hook_run_terminal"][:100], "summary": summ,
            "stop_blocked": stop_blocked, "mcp_offered": sorted(offered)[:40]}


def find_session_log(home, ids, t0):
    """Muse's session log for this run: sessions/YYYY/MM/DD/<id>/session.jsonl for a session id named in the events,
    else the newest session.jsonl modified since the run started. (path, how) or (None, why)."""
    root = os.path.join(home, ".local/share/muse/sessions")
    try:
        rfd = open_dir(root)
    except (OSError, Refuse):
        return None, "no sessions folder (or a link on its path)"
    found, newest = {}, (0, None)
    try:
        def walk(dfd, rel, depth):
            nonlocal newest
            for n in sorted(os.listdir(dfd))[:5000]:
                try:
                    st = os.stat(n, dir_fd=dfd, follow_symlinks=False)
                except OSError:
                    continue
                if not stat.S_ISDIR(st.st_mode):
                    continue
                if depth == 3:
                    try:
                        sfd = os.open(n, O_DIR, dir_fd=dfd)
                    except OSError:
                        continue
                    try:
                        s2 = os.stat("session.jsonl", dir_fd=sfd, follow_symlinks=False)
                    except OSError:
                        continue
                    finally:
                        os.close(sfd)
                    if stat.S_ISREG(s2.st_mode):
                        p = os.path.join(root, rel, n, "session.jsonl")
                        found[n] = p
                        if s2.st_mtime >= t0 - 5 and s2.st_mtime > newest[0]:
                            newest = (s2.st_mtime, p)
                elif depth < 3:
                    try:
                        sub = os.open(n, O_DIR, dir_fd=dfd)
                    except OSError:
                        continue
                    try:
                        walk(sub, os.path.join(rel, n), depth + 1)
                    finally:
                        os.close(sub)
        walk(rfd, "", 0)
    finally:
        os.close(rfd)
    for i in ids:
        if i in found:
            return found[i], "session id from the events"
    if newest[1]:
        return newest[1], "the newest session log since the run started"
    return None, "no session log for this run"


# ------------------------------------------------------------------------------------------------------- services, image
def service_of(spec, meta, changed):
    """(service, services for rhobound-change.json, error). The ticket's meta.json services[0] when it names a service
    of spec.json; else the one image the changed paths point at. The request lists every service of that image."""
    svc = None
    if isinstance(meta, dict) and isinstance(meta.get("services"), list) and meta["services"]:
        s0 = meta["services"][0]
        if isinstance(s0, str) and s0 in spec:
            svc = s0
    if svc is None:
        imgs = set()
        for p in changed:
            parts = p.split("/")
            if len(parts) > 3 and parts[2] == "cmd" and any(v.get("image") == parts[3] for v in spec.values()):
                imgs.add(parts[3])
            elif len(parts) > 4 and parts[2:4] == ["internal", "svc"] and parts[4] in spec:
                imgs.add(spec[parts[4]].get("image"))
        if len(imgs) != 1:
            return None, None, ("cannot tell which service the change is for (the ticket's meta.json names none; the "
                                "changed paths point at %d images)" % len(imgs))
        img = imgs.pop()
        runs = sorted(n for n in spec if spec[n].get("image") == img)
        svc = img if img in runs else runs[0]
    img = spec[svc].get("image")
    runs = sorted(n for n in spec if spec[n].get("image") == img)
    if len(runs) > 3:
        return svc, None, ("service %s runs image %s with %d services; a change request carries at most 3 (agent_take)"
                           % (svc, img, len(runs)))
    return svc, [svc] + [n for n in runs if n != svc], None


def touched(changed):
    out = set()
    for p in changed:
        parts = p.split("/")
        if len(parts) > 3 and parts[2] == "cmd":
            out.add("cmd/" + parts[3])
        elif len(parts) > 4 and parts[2:4] == ["internal", "svc"]:
            out.add("internal/svc/" + parts[4])
        elif len(parts) > 3:
            out.add("/".join(parts[2:4]))
    return sorted(out)


def is_build_file(p):
    b = os.path.basename(p)
    return p.startswith("maze/app/") and (b in BUILD_NAMES or b.endswith(BUILD_EXT) or "/vendor/" in "/" + p[9:])


# --------------------------------------------------------------------------------------------------------------- export
def write(path, data, mode=0o640):
    os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
    os.chmod(path, mode)


def cmd_export(a):
    if a.arm not in ("R", "C"):
        sys.exit("export.py export: --arm R or C")
    if os.path.lexists(a.stage):
        sys.exit("export.py export: %s exists" % a.stage)
    os.makedirs(a.stage, mode=0o750)
    os.makedirs(a.raw, mode=0o750, exist_ok=True)
    errors, warnings = [], []

    # the session's logs: capped copies into RAW, parsed from those bytes
    ev = read_path(os.path.join(os.path.abspath(a.session), "events.jsonl"), LOG_CAP)
    if ev is None:
        warnings.append("no events.jsonl from the session (Muse did not start, or a link)")
        ev = (b"", 0, False)
    write(os.path.join(a.raw, "events.jsonl"), ev[0])
    E = parse_events(ev[0].decode("utf-8", "replace"))
    E["events_bytes"], E["events_truncated"] = ev[1], ev[2]
    st_err = read_path(os.path.join(os.path.abspath(a.session), "stderr.txt"), 1 << 20)
    if st_err is not None:
        write(os.path.join(a.raw, "stderr.tail"), st_err[0][-8192:])
    slog, how = find_session_log(os.path.abspath(a.home), E["sessions"], a.t0)
    hooks = {"records": [], "summary": {}, "stop_blocked": 0, "mcp_offered": []}
    sl_info = {"found": False, "by": how}
    if slog:
        r = read_path(slog, LOG_CAP)
        if r is not None:
            write(os.path.join(a.raw, "session.jsonl"), r[0])
            hooks = parse_hooks(r[0].decode("utf-8", "replace"))
            sl_info = {"found": True, "by": how, "bytes": r[1], "truncated": r[2]}
    before = load_json(os.path.abspath(a.previews_before), 1 << 20) if a.previews_before else None
    after = preview_rows(os.path.abspath(a.home))
    pnew = None
    if isinstance(before, dict) and isinstance(before.get("files"), dict):
        pnew = sum(max(0, n - (before["files"].get(k) or 0)) for k, n in after["files"].items() if isinstance(n, int))
    elif after["found"]:
        pnew = sum(after["files"].values())

    # the workspace against main (the snapshot taken when the workspace was made), never the workspace's own .git
    ws_t = base_t = None
    try:
        base_t = scan(os.path.abspath(a.base), keep=lambda r: GO_PATH.fullmatch(r) is not None, skip_top=(".git",))
        ws_t = scan(os.path.abspath(a.ws), keep=lambda r: r.startswith("maze/app/") and r.endswith(".go"))
    except (OSError, Refuse) as e:
        errors.append("cannot read the workspace: %s" % clean(e, 200))
    changed, deleted, ignored, notcarried, outfiles = [], [], [], [], []
    if ws_t is not None:
        wsgo = {p for p in ws_t.files if p.startswith("maze/app/") and p.endswith(".go")}
        basego = {p for p in base_t.files if p.startswith("maze/app/") and p.endswith(".go")}
        changed = sorted(p for p in wsgo if p not in base_t.files or ws_t.files[p][1] is None
                         or ws_t.files[p][1] != base_t.files[p][1])
        deleted = sorted(p for p in basego if p not in ws_t.files)
        for p in sorted(ws_t.links + ws_t.special + ws_t.unreadable):
            if p.startswith("maze/app/") and p.endswith(".go"):
                errors.append("maze/app holds a link or special file where a .go file is expected: %s" % clean(p, 200))
            elif p.startswith("maze/app/"):
                notcarried.append(p)
            else:
                ignored.append(p)
        allp = set(ws_t.files) | set(base_t.files)
        for p in sorted(allp):
            if p in changed or p in deleted or (p.startswith("maze/app/") and p.endswith(".go")):
                continue
            w, b = ws_t.files.get(p), base_t.files.get(p)
            if w is not None and b is not None and w[1] is not None and w[1] == b[1]:
                continue
            (notcarried if is_build_file(p) else ignored).append(p)
        if deleted:
            errors.append("the change deletes %s: a deleted file cannot be carried to the pull request (keep the file, "
                          "or restore it)" % ", ".join(clean(p, 200) for p in deleted[:10]))
        for p in notcarried:
            if is_build_file(p):
                warnings.append("%s changed in the workspace but is not carried (only maze/app/**/*.go is): the change "
                                "is compiled against main's" % clean(p, 200))
        if not changed and not deleted:
            errors.append("no change under maze/app/**/*.go (nothing to carry)")
        if len(changed) > MAX_FILES:
            errors.append("%d .go files changed (at most %d): %s" % (len(changed), MAX_FILES,
                                                                      ", ".join(clean(p, 120) for p in changed[:12])))
        for p in changed:
            size, sha, data = ws_t.files[p]
            if not GO_PATH.fullmatch(p) or "/../" in "/%s/" % p or "/./" in "/%s/" % p:
                errors.append("file name not allowed: %r" % clean(p, 200))
                continue
            if size > MAX_FILE or data is None:
                errors.append("%s is %d bytes (at most %d)" % (p, size, MAX_FILE))
                continue
            try:
                t = data.decode("utf-8")
            except UnicodeDecodeError:
                errors.append("%s is not UTF-8 text" % p)
                continue
            if any(c in t for c in HIDDEN_CHARS):
                errors.append("%s: a byte-order mark or bidirectional/line-separator character" % p)
            orig = ""
            if p in base_t.files and base_t.files[p][2] is not None:
                orig = base_t.files[p][2].decode("utf-8", "replace")
            if [x.strip() for x in DIRECTIVE.findall(t)] != [x.strip() for x in DIRECTIVE.findall(orig)]:
                errors.append("%s: its build constraint lines differ from main's (%s): a change may not change which "
                              "files build" % (p, clean("; ".join(x.strip() for x in DIRECTIVE.findall(t)), 160) or "none"))
            m = BANNED.search(t)
            if m and not BANNED.search(orig):
                errors.append("%s: %s is not allowed in a change (no go:embed, go:linkname, cgo)" % (p, clean(m.group().strip(), 60)))
            lk = leaks(t)
            if lk and not leaks(orig):
                errors.append("%s: %s (the bed refuses addresses and 12-digit numbers in a change)" % (p, "; ".join(lk[:3])))
            outfiles.append((p, data, p not in base_t.files))

    spec = {}
    sp = load_json(os.path.join(os.path.abspath(a.base), "maze/spec.json"), 4 << 20)
    if isinstance(sp, dict) and isinstance(sp.get("services"), dict):
        spec = sp["services"]
    meta = load_json(os.path.join(os.path.abspath(a.ticket_dir), "meta.json"), 65536)
    svc, svcs, serr = service_of(spec, meta, changed) if spec else (None, None, "no maze/spec.json in main's snapshot")
    if serr and changed:
        errors.append(serr)
    if svc and not serr:   # the bed builds and deploys one image per change: code of another image's service goes nowhere
        img = spec[svc].get("image")
        other = sorted({t for t in touched(changed) if (t.startswith("cmd/") and t[4:] != img) or
                        (t.startswith("internal/svc/") and t[13:] in spec and spec[t[13:]].get("image") != img)})
        if other:
            warnings.append("the change also touches %s, which is not image %s: this change request builds and deploys "
                            "only %s (%s)" % (", ".join(other), img, img, ", ".join(svcs)))
    wr = [w for w in (meta.get("writable") or []) if isinstance(w, str)] if isinstance(meta, dict) else []
    wr = [w if w.startswith("maze/app/") else "maze/app/" + w for w in wr]
    outside = [p for p in changed if wr and not any(p.startswith(w) for w in wr)]
    if outside:
        warnings.append("the ticket asks for changes only under %s; this change also edits %s"
                        % (", ".join(wr), ", ".join(clean(p, 120) for p in outside[:8])))

    title_t = ticket_title(os.path.abspath(a.ticket_dir), a.ticket)
    head = "[muse-%s i%d] %s: " % (a.arm, a.iter, a.ticket)
    title = head + (title_t if len(head + title_t) <= 72 else title_t[:69 - len(head)].rstrip() + "...")
    note = clean(E["final_text"].strip(), 4000).strip()
    note = re.sub(r"\n{3,}", "\n\n", note)
    files_s = ", ".join(p[9:] for p, _, _ in outfiles[:8])
    summ = ("Muse Code (%s, effort %s), arm %s, ticket %s, iteration %d: %d file(s) under maze/app (%s)."
            % (MODEL, EFFORT, a.arm, a.ticket, a.iter, len(outfiles), files_s))
    if note:
        summ += "\n\nThe agent's closing note:\n" + note
    if len(summ) > 1000:
        summ = summ[:997].rstrip() + "..."

    wall = max(0.0, a.t1 - a.t0)
    mcp_names = [c["tool"] for c in E["mcp_calls"]]
    usage = {
        "schema": "rbd.muse-usage/v1", "arm": a.arm, "ticket": a.ticket, "iteration": a.iter, "run": a.run, "user": a.user,
        "model": MODEL, "effort": EFFORT, "steps_cap": a.steps,
        "session": {"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(a.t0)),
                    "ended": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(a.t1)), "wall_s": round(wall, 1),
                    "rc": a.rc, "timed_out": a.rc == 124, "terminal": E["terminal"]},
        "model_steps": E["model_steps"], "model_steps_completed": E["model_steps_completed"],
        "tokens": E["tokens"], "run_usage": E["run_usage"],
        "tasks_by_kind": E["tasks_by_kind"], "tool_calls_by_kind": E["tool_calls_by_kind"],
        "mcp_offered": sorted(set(E["mcp_offered"]) | set(hooks["mcp_offered"])), "mcp_calls": E["mcp_calls"],
        "mcp_call_counts": {n: mcp_names.count(n) for n in sorted(set(mcp_names))},
        "previews_new": pnew,
        "hooks": dict(hooks, session_log=sl_info),
        "events": {"lines": E["lines"], "bad_lines": E["bad_lines"], "bytes": E["events_bytes"],
                   "truncated": E["events_truncated"], "tool_results": E["tool_results"]},
        "workspace": {"commit": a.commit or None, "commit_note": clean(a.commit_note or "", 300) or None,
                      "base_commit": a.base_commit or None, "main_sha": a.main_sha, "changed": [clean(p, 200) for p in changed],
                      "deleted": [clean(p, 200) for p in deleted], "touched": touched(changed),
                      "not_carried": [clean(p, 200) for p in notcarried[:50]],
                      "ignored": [clean(p, 200) for p in ignored[:50]], "ignored_count": len(ignored)},
    }
    write(os.path.join(a.stage, "usage.json"), json.dumps(usage, indent=1) + "\n")
    tokens = E["tokens"] or {}
    res = {"step": "agent", "ok": not errors, "arm": a.arm, "ticket": a.ticket, "iteration": a.iter, "run": a.run,
           "session_rc": a.rc, "turns": E["model_steps"], "mcp_calls": mcp_names, "usage": tokens, "provider": PROVIDER,
           "model": MODEL, "served_by": [SERVED_BY], "warnings": warnings[:20]}
    if errors:
        res.update(error=clean(errors[0], 1000), errors=[clean(e, 1000) for e in errors[:20]])
    else:
        files = []
        patch = []
        for p, data, new in outfiles:
            write(os.path.join(a.stage, "files", p), data)
            files.append({"path": p, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "new": new})
            orig = "" if new else base_t.files[p][2].decode("utf-8", "replace")
            patch.extend(difflib.unified_diff(orig.splitlines(True), data.decode("utf-8").splitlines(True),
                                              "/dev/null" if new else "a/" + p, "b/" + p))
        man = {"schema": "rbd.agent-change/v1", "provider": PROVIDER, "model": MODEL, "served_by": [SERVED_BY],
               "effort": EFFORT, "base_sha": a.main_sha, "service": svc, "title": title, "summary": summ, "files": files,
               "turns": E["model_steps"], "usage": tokens,
               "mcp_calls": [{"tool": c["tool"], "task_kind": c["task_kind"]} for c in E["mcp_calls"]],
               "arm": a.arm, "ticket": a.ticket, "iteration": a.iter, "run": a.run,
               "workspace_commit": a.commit or None, "session_rc": a.rc}
        if len(svcs) == 1:
            req = {"schema": "rbd.change-request/v1", "services": svcs, "summary": summ}
        else:
            req = {"schema": "rbd.change-request/v2", "services": svcs, "summary": summ}
        write(os.path.join(a.stage, "manifest.json"), json.dumps(man, indent=1) + "\n")
        write(os.path.join(a.stage, "rhobound-change.json"), json.dumps(req) + "\n")
        write(os.path.join(a.stage, "change.patch"), "".join(patch))
        write(os.path.join(a.stage, "title.txt"), title + "\n")
        res.update(service=svc, services=svcs, title=title, files=len(files))
    write(os.path.join(a.stage, "result.json"), json.dumps(res, indent=1) + "\n")   # last: the run is complete
    line = {"step": "muse-task", "ok": res["ok"], "out": a.out, "arm": a.arm, "ticket": a.ticket, "iteration": a.iter,
            "session_rc": a.rc, "wall_s": round(wall, 1), "files": res.get("files", 0), "service": res.get("service"),
            "model_steps": E["model_steps"], "mcp_calls": mcp_names, "stop_blocked": hooks["stop_blocked"]}
    if errors:
        line["error"] = res["error"]
    print(json.dumps(line))


# ------------------------------------------------------------------------------------------------------- hidden tests
def copy_tree(src_fd, dst):
    """Regular files and folders of an open folder into dst (links and special files skipped)."""
    os.makedirs(dst, mode=0o755, exist_ok=True)
    for n in sorted(os.listdir(src_fd)):
        st = os.stat(n, dir_fd=src_fd, follow_symlinks=False)
        if stat.S_ISDIR(st.st_mode):
            sub = os.open(n, O_DIR, dir_fd=src_fd)
            try:
                copy_tree(sub, os.path.join(dst, n))
            finally:
                os.close(sub)
        elif stat.S_ISREG(st.st_mode):
            data, _, trunc = read_at(src_fd, n, 64 << 20)
            if trunc:
                raise Refuse("a file over 64 MB in main's tree: %s" % n)
            write(os.path.join(dst, n), data, 0o644)


def cmd_hidden_copy(a):
    dest = os.path.abspath(a.dest)
    if os.path.lexists(os.path.join(dest, "maze")):
        sys.exit("export.py hidden-copy: %s/maze exists" % dest)
    fd = open_dir(os.path.join(os.path.abspath(a.base), "maze/app"))
    try:
        copy_tree(fd, os.path.join(dest, "maze/app"))
    finally:
        os.close(fd)
    out = os.path.abspath(a.out)
    res = load_json(os.path.join(out, "result.json"), 1 << 20)
    man = load_json(os.path.join(out, "manifest.json"), 4 << 20)
    if not isinstance(res, dict) or res.get("ok") is not True or not isinstance(man, dict):
        sys.exit("export.py hidden-copy: %s holds no exported change (result.json ok is not true)" % out)
    for f in man.get("files") or []:
        p = f.get("path") if isinstance(f, dict) else None
        if not isinstance(p, str) or not GO_PATH.fullmatch(p) or "/../" in "/%s/" % p or "/./" in "/%s/" % p:
            sys.exit("export.py hidden-copy: manifest path %r" % (p,))
        r = read_path(os.path.join(out, "files", p), MAX_FILE)
        if r is None or r[2] or hashlib.sha256(r[0]).hexdigest() != f.get("sha256"):
            sys.exit("export.py hidden-copy: %s is missing or differs from the manifest" % p)
        write(os.path.join(dest, p), r[0], 0o644)
    hid = os.path.abspath(a.hidden)
    t = scan(hid, keep=lambda r: r.endswith(".go"), skip_top=())
    if t.links or t.special:
        sys.exit("export.py hidden-copy: links or special files in the ticket's hidden/")
    pkgs, over, names = set(), [], set()
    for rel in sorted(t.files):
        p = rel if rel.startswith("maze/app/") else ("maze/app/" + rel if rel.split("/")[0] in ("internal", "cmd") else None)
        if p is None or not p.endswith("_test.go") or not GO_PATH.fullmatch(p):
            sys.exit("export.py hidden-copy: hidden/%s: hidden tests are *_test.go files under maze/app/..." % rel)
        data = t.files[rel][2]
        if data is None:
            sys.exit("export.py hidden-copy: hidden/%s is too large" % rel)
        if os.path.lexists(os.path.join(dest, p)):
            over.append(p)
        write(os.path.join(dest, p), data, 0o644)
        names |= set(re.findall(r"^func (Test[A-Za-z0-9_]*)\(\w+ \*testing\.T\)", data.decode("utf-8", "replace"), re.M))
        pkgs.add("./" + os.path.dirname(p)[len("maze/app/"):])
    if not pkgs:
        sys.exit("export.py hidden-copy: the ticket has no hidden tests")
    print(json.dumps({"packages": sorted(pkgs), "tests": sorted(names), "overwrote": over}))


def cmd_hidden_summary(a):
    r = read_path(os.path.abspath(a.json), LOG_CAP)
    data = r[0].decode("utf-8", "replace") if r else ""
    tests, out_lines, build_failed, pkg_failed, other = {}, [], False, [], []
    for raw in data.splitlines():
        try:
            e = json.loads(raw)
        except ValueError:
            other.append(raw)
            continue
        if not isinstance(e, dict):
            continue
        act, test, pkg = e.get("Action"), e.get("Test"), e.get("Package") or e.get("ImportPath") or ""
        if isinstance(e.get("Output"), str):
            out_lines.extend(e["Output"].rstrip("\n").split("\n"))
        if act == "build-fail" or (act == "fail" and not test and "build failed" in json.dumps(e)):
            build_failed = True
        if act in ("pass", "fail", "skip") and isinstance(test, str):
            tests[test] = act
        elif act == "fail" and not test:
            pkg_failed.append(clean(pkg, 120))
    for line in other:
        out_lines.append(line)
        if "build failed" in line or "setup failed" in line:
            build_failed = True
    if any("[build failed]" in x or "[setup failed]" in x for x in out_lines):
        build_failed = True
    failed = sorted(t for t, v in tests.items() if v == "fail")
    passed = sum(1 for v in tests.values() if v == "pass")
    cp = load_json(os.path.abspath(a.copy), 1 << 20) if a.copy else None
    cp = cp if isinstance(cp, dict) else {}
    expect = [x for x in cp.get("tests") or [] if isinstance(x, str)]
    missing = sorted(x for x in expect if tests.get(x) != "pass" and tests.get(x) != "fail")
    err = clean(a.error, 500) if a.error else None
    if err is None and a.rc not in (0, 1):
        err = "go test exit %d (timeout or crash)" % a.rc if a.rc != 124 else "go test timed out"
    if err is None and not build_failed and not pkg_failed and (not tests or (missing and a.rc == 0)):
        err = "hidden tests did not run: %s (wrong build tag or package, or the test binary exited early?)" % (
            ", ".join(missing[:10]) or "none reported")
    tail = "\n".join(out_lines[-60:])
    if a.strip:
        tail = tail.replace(a.strip, "<copy>")
    tail = clean(tail, 8000)
    ok = (a.rc == 0 and not failed and not build_failed and not pkg_failed and passed > 0 and not missing
          and err is None)
    h = {"schema": "rbd.muse-hidden/v1", "run": a.run, "iteration": a.iter, "ticket": a.ticket, "arm": a.arm,
         "pass": ok, "failed": [clean(t, 200) for t in failed[:50]], "ran": len(tests), "passed": passed,
         "expected": expect[:50], "missing": missing[:50], "build_failed": build_failed, "packages_failed": pkg_failed[:20],
         "go_test_rc": a.rc, "error": err, "race": False,
         "modcache_verified": None if a.verify_rc is None else a.verify_rc == 0,
         "packages": [clean(x, 120) for x in cp.get("packages") or []][:20],
         "overwrote": [clean(x, 200) for x in cp.get("overwrote") or []][:20],
         "wall_s": a.wall, "go": clean(a.go or "", 80) or None, "output_tail": tail}
    write(os.path.abspath(a.out), json.dumps(h, indent=1) + "\n")
    print(json.dumps(h))


# ----------------------------------------------------------------------------------------------------------------- main
def cmd_events(a):
    r = read_path(os.path.abspath(a.events), LOG_CAP)
    if r is None:
        sys.exit("export.py events: cannot read %s (a regular file, no link)" % a.events)
    E = parse_events(r[0].decode("utf-8", "replace"))
    out = {k: E[k] for k in ("lines", "bad_lines", "model_steps", "model_steps_completed", "tokens", "tool_calls_by_kind",
                             "mcp_offered", "mcp_calls", "sessions", "terminal", "run_usage", "tasks_by_kind")}
    out["final_text_chars"] = len(E["final_text"])
    if a.session_log:
        s = read_path(os.path.abspath(a.session_log), LOG_CAP)
        out["hooks"] = parse_hooks(s[0].decode("utf-8", "replace")) if s else None
    print(json.dumps(out, indent=1))


def main():
    ap = argparse.ArgumentParser(prog="export.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prompt")
    p.add_argument("--task", required=True)
    p.add_argument("--iter", type=int, default=1)
    p.add_argument("--feedback")
    p = sub.add_parser("previews")
    p.add_argument("--home", required=True)
    p = sub.add_parser("export")
    for k in ("ws", "base", "main-sha", "session", "home", "ticket-dir", "arm", "ticket", "run", "user", "stage", "out", "raw"):
        p.add_argument("--" + k, required=True)
    for k in ("iter", "rc", "steps"):
        p.add_argument("--" + k, type=int, required=True)
    p.add_argument("--t0", type=float, required=True)
    p.add_argument("--t1", type=float, required=True)
    for k in ("commit", "commit-note", "base-commit", "previews-before"):
        p.add_argument("--" + k)
    p = sub.add_parser("events")
    p.add_argument("--events", required=True)
    p.add_argument("--session-log")
    p = sub.add_parser("hidden-copy")
    for k in ("base", "out", "hidden", "dest"):
        p.add_argument("--" + k, required=True)
    p = sub.add_parser("hidden-summary")
    p.add_argument("--json", required=True)
    p.add_argument("--rc", type=int, required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--verify-rc", type=int)
    p.add_argument("--strip")
    for k in ("copy", "run", "ticket", "arm", "go", "error"):
        p.add_argument("--" + k)
    p.add_argument("--iter", type=int)
    p.add_argument("--wall", type=float)
    a = ap.parse_args()
    if a.cmd == "export" and not re.fullmatch(r"[0-9a-f]{40}", a.main_sha):
        sys.exit("export.py export: --main-sha must be 40 hex")
    {"prompt": cmd_prompt, "previews": cmd_previews, "export": cmd_export, "events": cmd_events,
     "hidden-copy": cmd_hidden_copy, "hidden-summary": cmd_hidden_summary}[a.cmd](a)


if __name__ == "__main__":
    main()
