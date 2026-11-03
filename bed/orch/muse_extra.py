"""muse_extra.py: per-iteration evidence for reports/muse-live/RESULTS.md that muse_score.py does not tabulate: the
agent's shell attempts (Muse's tool.bash tasks: proposed, failed in the sandbox, refused unsandboxed, completed), MCP
calls by tool, the Stop hook's exit codes, and the files each change carries. Reads state/muse/*/iter-*/agent/usage.json
and changes/CHANGE/change.patch as data.   python3 -I orch/muse_extra.py [--state state/muse]  -> Markdown on stdout."""
import argparse, json, os, re, sys

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

ap = argparse.ArgumentParser()
ap.add_argument("--state", default="state/muse")
a = ap.parse_args()
print("| ticket | arm | iter | change | files | shell: proposed / sandbox-failed / refused / completed | MCP calls | Stop exits |")
print("|---|---|---|---|---|---|---|---|")
for arm in sorted(os.listdir(a.state)):
    t = load(os.path.join(a.state, arm, "timeline.json"))
    if not isinstance(t, dict):
        continue
    for it in sorted(d for d in os.listdir(os.path.join(a.state, arm)) if re.fullmatch(r"iter-\d\d", d)):
        u = load(os.path.join(a.state, arm, it, "agent", "usage.json")) or {}
        i = int(it[5:])
        rec = next((x for x in t.get("iterations") or [] if x.get("iter") == i), {})
        ch = rec.get("change")
        files = "(refused at take)" if rec.get("outcome") == "refused" else "-"
        if ch and os.path.isfile(os.path.join("changes", ch, "change.patch")):
            fs = re.findall(r"^diff --git a/(\S+)", open(os.path.join("changes", ch, "change.patch")).read(), re.M)
            files = ", ".join(os.path.basename(f) for f in fs)
        b = (u.get("tasks_by_kind") or {}).get("tool.bash") or {}
        shell = "%s / %s / %s / %s" % (b.get("proposed", 0), b.get("failed", 0), b.get("rejected", 0), b.get("completed", 0))
        mcp = ", ".join("%s %s" % (k, v) for k, v in sorted((u.get("mcp_call_counts") or {}).items())) or "none"
        stop = ((u.get("hooks") or {}).get("summary") or {}).get("Stop", {}).get("exit_codes")
        print("| %s | %s | %d | %s | %s | %s | %s | %s |" % (t.get("ticket"), t.get("arm"), i, ch or "-", files, shell, mcp,
                                                       stop if stop is not None else "-"))
