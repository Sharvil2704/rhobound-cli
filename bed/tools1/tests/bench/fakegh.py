"""fakegh.py: a stateful stand-in for the GitHub that orch/automerge.sh and orch/bench.sh talk to (through fakebin/gh).

The world is one JSON file (STUB_WORLD), read and rewritten by every call; every call is appended to STUB_DIR/calls.log.
Never touches the network. World keys:
  me                 the gh account's login
  main               main's tip (40 hex)
  clock              seconds after 2026-10-30T21:00:00Z; every call advances it by 60 (timestamps are deterministic)
  prs {N: {...}}     gh pr view fields (number state isDraft labels headRefName headRefOid baseRefName isCrossRepository
                     author mergeable files url mergeCommit mergedAt) + behind_by (what compare main...head answers)
                     + labels_next (a list: the PR's labels from its first gh pr view on, as if relabelled between two
                     reads; pr list sees the labels of the moment)
  statuses {sha: [newest first]}   + pending_reads {sha: k}: the first k reads answer one 'pending' status only
  runs [ {databaseId workflow headSha status conclusion createdAt startedAt updatedAt polls_left final} ]: a run that is
                     not completed answers 'in_progress' polls_left more times, then completes with 'final'
  deploy_polls, deploy_final        what a merge's deploy.yml run does [1, success]
  merge_fails        gh pr merge exits 1 (GitHub refused)
"""
import json
import os
import sys

WORLD = os.environ["STUB_WORLD"]
LOG = os.path.join(os.environ["STUB_DIR"], "calls.log")


def ts(w):
    s = w["clock"]
    return "2026-10-30T%02d:%02d:%02dZ" % (21 + s // 3600, s // 60 % 60, s % 60)


def opt(args, name, default=None):
    return args[args.index(name) + 1] if name in args else default


def fields(d, args):
    f = opt(args, "--json")
    return {k: d.get(k) for k in f.split(",")} if f else d


def out(x):
    print(json.dumps(x))


def mkpr(w, spec):
    """'N:KEY=VALUE,...' -> one PR (+ its statuses and gate run) in w (see s8lib.sh world())."""
    import hashlib
    n, _, kv = spec.partition(":")
    o = dict(x.split("=", 1) for x in kv.split(",") if x)
    head = o.get("head") or hashlib.sha1(("head-%s-%s" % (n, o.get("rev", "1"))).encode()).hexdigest()
    pr = {"number": int(n), "state": "OPEN", "isDraft": o.get("draft") == "1",
          "labels": ([{"name": x} for x in o["labels"].split("|") if x] if "labels" in o
                     else [] if o.get("label") == "0" else [{"name": "rbd-bench"}]),
          "headRefName": o.get("branch", "rbd/c%s-bench" % n), "headRefOid": head, "baseRefName": o.get("base", "main"),
          "isCrossRepository": o.get("cross") == "1", "author": {"login": o.get("author", "rbd-demo-bot")},
          "mergeable": o.get("mergeable", "MERGEABLE"),
          "files": [{"path": p} for p in o.get("files", "kshop/app/internal/hot/rank.go|rhobound-change.json").split("|")],
          "url": "https://github.com/Sharvil2704/rhobound-demo/pull/%s" % n, "mergeCommit": None, "mergedAt": None,
          "behind_by": int(o.get("behind", "0"))}
    if "labels2" in o:
        pr["labels_next"] = [{"name": x} for x in o["labels2"].split("|") if x]
    w["prs"][n] = pr
    v = o.get("verdict", "pass")
    if v != "none":
        state = {"pass": "success", "block": "failure", "inconclusive": "failure", "error": "error"}[v]
        desc = o.get("desc", {"pass": "pass: mean_change@storefront", "block": "block: mean_change@storefront",
                              "inconclusive": "inconclusive: unmeasured_delta", "error": "no signed verdict: ab failure (see the run)"}[v])
        w["statuses"][head] = [{"context": "rhobound/verdict", "state": state, "description": desc,
                                "creator": {"login": o.get("creator", "github-actions[bot]")}, "created_at": "2026-10-30T21:20:00Z",
                                "target_url": "https://github.com/Sharvil2704/rhobound-demo/actions/runs/%d" % (500 + int(n))},
                               {"context": "rhobound/verdict", "state": "pending", "description": "gate running",
                                "creator": {"login": "github-actions[bot]"}, "created_at": "2026-10-30T21:01:00Z"}]
        w["runs"].append({"databaseId": 500 + int(n), "workflow": "gate.yml", "headSha": head, "status": "completed",
                          "conclusion": "success" if v == "pass" else "failure", "createdAt": "2026-10-30T21:00:30Z",
                          "startedAt": "2026-10-30T21:01:00Z", "updatedAt": "2026-10-30T21:20:00Z"})
    if int(o.get("pending", "0")):
        w["pending_reads"][head] = int(o["pending"])


def admin(cmd, specs):
    """__world SPEC...: a fresh world; __add SPEC...: more PRs in the current one."""
    if cmd == "__world":
        w = {"me": "rbd-demo-bot", "main": "a" * 40, "clock": 0, "prs": {}, "statuses": {}, "pending_reads": {}, "runs": []}
    else:
        w = json.load(open(WORLD))
    for spec in specs:
        mkpr(w, spec)
    with open(WORLD, "w") as f:
        json.dump(w, f, indent=1)
    return 0


def main(args):
    if args and args[0] in ("__world", "__add"):
        return admin(args[0], args[1:])
    with open(LOG, "a") as f:
        f.write("gh " + " ".join(args) + "\n")
    w = json.load(open(WORLD))
    w["clock"] = w.get("clock", 0) + 60
    rc = run(w, args)
    with open(WORLD + ".tmp", "w") as f:
        json.dump(w, f, indent=1)
    os.replace(WORLD + ".tmp", WORLD)
    return rc


def run(w, a):
    two = " ".join(a[:2])
    if two == "auth status":
        return 0
    if two == "api user":
        out({"login": w["me"], "id": 1234567})
        return 0
    if a[0] == "api":
        path = a[1].split("?")[0]
        p = path.split("/")
        if p[-1] == "statuses":
            sha = p[-2]
            k = w.setdefault("pending_reads", {}).get(sha, 0)
            if k > 0:
                w["pending_reads"][sha] = k - 1
                out([{"context": "rhobound/verdict", "state": "pending", "description": "gate running",
                      "creator": {"login": "github-actions[bot]"}, "created_at": ts(w)}])
            else:
                out(w.get("statuses", {}).get(sha, []))
            return 0
        if p[-3:] == ["git", "ref", "heads"] or path.endswith("git/ref/heads/main"):
            out({"ref": "refs/heads/main", "object": {"sha": w["main"], "type": "commit"}})
            return 0
        if "compare" in p:
            base, head = p[-1].split("...")
            pr = next((x for x in w["prs"].values() if x["headRefOid"] == head), None)
            behind = pr.get("behind_by", 0) if pr else 1
            out({"status": "ahead" if behind == 0 else "diverged", "ahead_by": 1, "behind_by": behind,
                 "merge_base_commit": {"sha": base if behind == 0 else "0" * 40}})
            return 0
    if two == "pr list":
        prs = sorted(w["prs"].values(), key=lambda x: x["number"])
        lab, head, state = opt(a, "--label"), opt(a, "--head"), opt(a, "--state", "open")
        sel = [x for x in prs if (state == "all" or x["state"] == state.upper())
               and (lab is None or lab in [l["name"] for l in x.get("labels", [])])
               and (head is None or x["headRefName"] == head)]
        out([fields(x, a) for x in sel])
        return 0
    if two == "pr view":
        key = a[2]
        pr = w["prs"].get(key) or next((x for x in w["prs"].values() if x["headRefName"] == key), None)
        if pr is None:
            print("no pull requests found", file=sys.stderr)
            return 1
        out(fields(pr, a))
        if "labels_next" in pr:   # relabelled after this read (labels2): the next read sees the new labels
            pr["labels"] = pr.pop("labels_next")
        return 0
    if two == "pr merge":
        pr = w["prs"].get(a[2])
        want = opt(a, "--match-head-commit")
        if pr is None or "--merge" not in a or not want:
            print("fakegh: pr merge needs a known PR, --merge and --match-head-commit", file=sys.stderr)
            return 2
        if w.get("merge_fails") or pr["state"] != "OPEN":
            print("GraphQL: Pull Request is not mergeable", file=sys.stderr)
            return 1
        if want != pr["headRefOid"]:
            print("GraphQL: Head branch was modified. Review and try the merge again.", file=sys.stderr)
            return 1
        m = ("%040x" % (int(pr["headRefOid"], 16) ^ 0xFFFF))[-40:]
        pr.update(state="MERGED", mergeCommit={"oid": m}, mergedAt=ts(w))
        w["main"] = m
        for o in w["prs"].values():   # every other open PR was cut from the old main: now behind it
            if o is not pr and o["state"] == "OPEN":
                o["behind_by"] = o.get("behind_by", 0) + 1
        w.setdefault("runs", []).insert(0, {"databaseId": 9000 + len(w["runs"]), "workflow": "deploy.yml", "headSha": m,
                                           "status": "in_progress", "conclusion": None, "createdAt": ts(w),
                                           "startedAt": ts(w), "updatedAt": ts(w),
                                           "polls_left": w.get("deploy_polls", 1), "final": w.get("deploy_final", "success")})
        return 0
    if two == "run list":
        wf, sha = opt(a, "--workflow"), opt(a, "--commit")
        sel = [r for r in w.get("runs", []) if r["workflow"] == wf and (sha is None or r["headSha"] == sha)]
        for r in sel:
            if r["status"] != "completed":
                if r.get("polls_left", 0) > 0:
                    r["polls_left"] -= 1
                else:
                    r.update(status="completed", conclusion=r.get("final", "success"), updatedAt=ts(w))
        lim = int(opt(a, "--limit", "20"))
        out([{k: v for k, v in r.items() if k not in ("workflow", "polls_left", "final")} for r in sel[:lim]])
        return 0
    if two in ("label list", "label create", "pr create"):
        out([]) if two == "label list" else None
        return 0
    print("fakegh: unsupported: %s" % " ".join(a), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
