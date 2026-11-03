#!/usr/bin/env python3
"""from_branch.py: a maze change branch (github.com/Sharvil2704/rhobound-maze, campaign/DECLARE.md) as a planted change
in the layout make_prs.sh consumes (changes/cN-plant: a DRAFT PR labelled rbd-plant, never merged).

  python3 -I changes/from_branch.py MAZE_REPO BRANCH cN-plant [--force]

MAZE_REPO is a local clone of rhobound-maze holding BRANCH and its base (main's app commit, BASE below). The patch is
'git diff BASE BRANCH -- internal cmd', re-rooted under maze/app/; it must apply to repo/ (the frozen main), touch only
.go files of ONE image (cmd/<image> or internal/svc/<image>, or a package only that image imports), and compile there
(orch/gocheck.sh). rhobound-change.json lists every service that runs the image (pr-check.sh requires exactly that).
Writes changes/cN-plant/{change.patch, rhobound-change.json, title.txt, manifest.json (rbd.plant-change/v1)}.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = "02eae9f373ed97dd4a407e5d03b56bd9f4a61868"   # maze main's app code (internal/, cmd/ unchanged since)
HERE = Path(__file__).resolve().parent
KIT = HERE.parent
SPEC = json.loads((KIT / "repo" / "maze" / "spec.json").read_text())["services"]


def die(m):
    sys.exit(f"from_branch: {m}")


def git(repo, *a):
    return subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True, text=True).stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("branch")
    ap.add_argument("name")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    if not re.fullmatch(r"c[0-9]{1,2}-plant", a.name):
        die("NAME must be cN-plant")
    out = HERE / a.name
    if out.exists() and not a.force:
        die(f"{out} exists (--force replaces it)")
    sha = git(a.repo, "rev-parse", "--verify", a.branch + "^{commit}").strip()
    git(a.repo, "merge-base", "--is-ancestor", BASE, sha)
    files = git(a.repo, "diff", "--name-only", BASE, sha, "--", "internal", "cmd").split()
    if not files or any(not f.endswith(".go") for f in files):
        die(f"the branch must change .go files under internal/ or cmd/ only: {files}")
    images = set()
    for f in files:
        m = re.match(r"(?:cmd|internal/svc)/([a-z][a-z0-9-]*)/", f)
        if not m:
            die(f"{f}: not in cmd/<image>/ or internal/svc/<image>/ (a shared package changes several images)")
        images.add(m.group(1))
    if len(images) != 1:
        die(f"the branch changes {len(images)} images ({', '.join(sorted(images))}): one image per change")
    image = images.pop()
    svcs = sorted(n for n, s in SPEC.items() if s["image"] == image)
    if not svcs:
        die(f"no service of spec.json runs image {image}")
    patch = git(a.repo, "diff", "--no-color", "--src-prefix=a/maze/app/", "--dst-prefix=b/maze/app/", BASE, sha, "--",
                "internal", "cmd")
    subject = git(a.repo, "log", "-1", "--format=%s", sha).strip()
    body = git(a.repo, "log", "-1", "--format=%b", sha).strip()
    scr = os.environ.get("RBD_SCRATCH") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "rbd")
    os.makedirs(scr, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scr) as w:
        tree = Path(w) / "tree"
        shutil.copytree(KIT / "repo", tree, symlinks=True)
        (Path(w) / "p.patch").write_text(patch)
        subprocess.run(["git", "apply", "--check", "-p1", str(Path(w) / "p.patch")], cwd=tree, check=True)
        subprocess.run(["git", "apply", "-p1", str(Path(w) / "p.patch")], cwd=tree, check=True)
        r = subprocess.run(["bash", str(KIT / "orch" / "gocheck.sh"), str(tree), str(Path(w) / "compile.txt"),
                            *["maze/app/" + f for f in files if not f.endswith("_test.go")]], capture_output=True, text=True)
        if r.returncode != 0:
            die("does not compile on repo/:\n" + r.stderr[-2000:] + (Path(w) / "compile.txt").read_text()[-2000:])
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()
    (out / "change.patch").write_text(patch)
    summary = (f"{subject}. Image {image} (services {', '.join(svcs)}), branch {a.branch} of rhobound-maze. "
               + body.replace("\n", " "))[:1000]
    (out / "rhobound-change.json").write_text(json.dumps(
        {"schema": "rbd.change-request/v2", "services": svcs, "summary": summary}, indent=1) + "\n")
    title = subject if len("PLANT do-not-merge: " + subject) <= 72 else subject[:72 - 23] + "..."
    (out / "title.txt").write_text("PLANT do-not-merge: " + title + "\n")
    (out / "manifest.json").write_text(json.dumps({
        "schema": "rbd.plant-change/v1", "name": a.name, "never_merge": True, "compiled": True,
        "patch_sha256": hashlib.sha256(patch.encode()).hexdigest(), "mechanism": "branch", "service": svcs[0],
        "services": svcs, "image": image, "function": "branch " + a.branch, "placement": sha[:12],
        "maze_branch": a.branch, "maze_commit": sha, "files": ["maze/app/" + f for f in files]}, indent=1) + "\n")
    print(f"{a.name}: {a.branch} ({sha[:12]}) image {image}, services {','.join(svcs)}, {len(files)} file(s)")


if __name__ == "__main__":
    main()
