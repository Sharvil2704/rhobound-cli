#!/usr/bin/env bash
# fake_run.sh USER WORKSPACE PROMPT_FILE OUT_DIR [MAX_STEPS]: the tests' stand-in for /opt/muse/run.sh. Instead of Muse it
# runs FAKE_AGENT (a bash script, cwd = the workspace) and writes what Muse 1.4.14 writes, in the record shapes seen live
# on rbd-tools1 (reports/muse-live): OUT/events.jsonl ({schema_version, id, stream, sequence, recorded_at, record_type,
# payload_type, payload}), OUT/{prompt.md, started, ended, rc, stderr.txt}, the session log
# ~/.local/share/muse/sessions/2026/11/02/<id>/session.jsonl with the plugin's hook records (muser only), and for muser
# two rows in the rhobound-mcp preview log. FAKE_RC: the exit code (default 0). FAKE_LOG: each call's args appended.
set -euo pipefail
u=$1 ws=$2 pf=$3 out=$4 steps=${5:-80}
R=${MUSE_TEST_ROOT:?}
H=$R/home/$u
[ -z "${FAKE_LOG:-}" ] || echo "$u $ws $pf $out $steps" >> "$FAKE_LOG"
mkdir -p "$out"
cp "$pf" "$out/prompt.md"
date -u +%FT%TZ > "$out/started"
echo "muse: workspace root: $ws (cwd default)" > "$out/stderr.txt"
[ -z "${FAKE_AGENT:-}" ] || (cd "$ws" && bash "$FAKE_AGENT") >> "$out/stderr.txt" 2>&1
SID=01a19dfb-cc5a-7453-8326-$(printf '%012d' $((RANDOM * 32768 + RANDOM)))
python3 -I - "$u" "$out/events.jsonl" "$H" "$SID" "$steps" << 'PY'
import json, os, sys, time
u, path, home, sid, steps = sys.argv[1:]
seq = [0]
def rec(pt, payload, stream=None):
    seq[0] += 1
    return {"schema_version": 1, "id": "rec-%d" % seq[0], "stream": stream or {"kind": "run", "id": "run-1"},
            "sequence": seq[0], "recorded_at": int(time.time() * 1e6), "record_type": "event", "durability": "durable",
            "causation_id": None, "payload_type": pt, "payload_schema_version": 1, "payload": payload}
def task(tid, kind, extra=None, stages=("proposed", "accepted", "scheduled", "started", "completed")):
    out = []
    for st in stages:
        p = {"command_id": "cmd-1", "event": {"kind": st, "task_id": tid, "task_kind": kind} if st == "proposed" else
             {"kind": st, "task_id": tid}, "kind": "task_lifecycle", "task_id": tid,
             "task_stream": {"id": tid, "kind": "task"}}
        if extra and st in extra:
            p.update(extra[st])
        out.append(rec("task.lifecycle." + st, p, {"kind": "task", "id": tid}))
    return out
R = u == "muser"
ev = [rec("runtime.command.accepted", {"command_id": "cmd-1"}),
      rec("session.run.linked", {"session": {"kind": "session", "id": sid}, "run": {"kind": "run", "id": "run-1"}},
          {"kind": "session", "id": sid}),
      rec("run.model.configured", {"model": "muse-spark-1.3", "tools": ["read_file", "edit_file", "shell"] +
          (["mcp__rhobound__" + t for t in ("budget", "context", "explain", "fit_start", "job_status", "predict")] if R else [])}),
      rec("turn.input.user", {"text": "the prompt"}), rec("run.lifecycle.started", {})]
ev += task("t-rem1", "reminder.agent.skill-reminder", stages=("proposed", "rejected"))
ev += task("t-m1", "model.meta.response", {"completed": {"note": "the model asked for mcp__rhobound__predict"}})
ev += task("t-r1", "tool.read_file", {"output": {"text": "SKILL.md names mcp__rhobound__budget"}})
ev.append(rec("tool.result", {"call_id": "call_1"}))
if R:
    ev += task("t-m2", "model.meta.response")
    ev += task("t-c1", "tool.mcp__rhobound__context")
    ev += task("t-c2", "tool.mcp", {"scheduled": {"tool": {"name": "mcp__rhobound__predict", "server": "rhobound"}}})
ev += task("t-m3", "model.meta.response")
ev += task("t-e1", "tool.edit_file")
ev += task("t-e2", "tool.edit_file", stages=("proposed", "rejected"))
ev.append(rec("run.output.delta", {"delta": "Done: I added Hello to catalog. Talked to 10.0.0.5, 100.64.7.9 and "}))
ev.append(rec("run.output.delta", {"delta": "account 123456789012 [skip ci]\x07."}))
ev.append(rec("run.usage", {"models": {"muse-spark-1.3": {"input_tokens": 1200, "cached_input_tokens": 300,
                                                           "output_tokens": 450, "reasoning_tokens": 200}}}))
ev.append(rec("run.terminal.completed", {"status": "completed"}))
with open(path, "w") as f:
    for e in ev:
        f.write(json.dumps(e) + "\n")
        if e["payload_type"] == "run.model.configured":
            f.write("not json at all\n")
d = os.path.join(home, ".local/share/muse/sessions/2026/11/02", sid)
os.makedirs(d, exist_ok=True)
os.makedirs(os.path.join(home, ".local/share/muse/sessions/.msp-view-g6", sid), exist_ok=True)
def hook(n, ev_name, kind, **kw):
    e = {"display_order": 100000, "event": ev_name, "hook_key": "plugin:rhobound:rhobound-" +
         ("session-start" if ev_name == "SessionStart" else "stop"), "kind": kind,
         "origin": {"capability_id": "rhobound-stop", "plugin_id": "rhobound", "source_digest": "sha256:9845"}}
    e.update(kw)
    return {"schema_version": 1, "id": "s-%d" % n, "stream": {"kind": "session", "id": sid}, "sequence": n,
            "record_type": "event", "payload_type": "runtime.session", "payload_schema_version": 1, "payload": {"event": e}}
recs = [{"schema_version": 1, "payload_type": "runtime.session", "payload": {"event": {"kind": "session_started"}}}]
if R:
    recs += [hook(1, "SessionStart", "hook_run_started"), hook(2, "SessionStart", "hook_run_terminal", exit_code=0, error=None,
                                                                duration_ms=20),
             hook(3, "Stop", "hook_run_started"), hook(4, "Stop", "hook_run_terminal", exit_code=2, effects=["blocked"],
                                                       error=None, duration_ms=16),
             hook(5, "Stop", "hook_run_started"), hook(6, "Stop", "hook_run_terminal", exit_code=0, error=None, duration_ms=9)]
with open(os.path.join(d, "session.jsonl"), "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
if R:
    p = os.path.join(home, ".local/state/rhobound-mcp/server/previews")
    os.makedirs(p, exist_ok=True)
    with open(os.path.join(p, "3f1857d6038229f74704c996e0278652.jsonl"), "a") as f:
        f.write('{"preview": 1}\n{"preview": 2}\n')
PY
rc=${FAKE_RC:-0}
date -u +%FT%TZ > "$out/ended"
echo "$rc" > "$out/rc"
exit "$rc"
