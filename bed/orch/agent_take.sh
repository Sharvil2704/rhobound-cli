#!/usr/bin/env bash
# agent_take.sh RUN [CHANGE]   the model-written change (tools1/agent/agent.py's /var/lib/rbd/agent/RUN on rbd-tools1) -> changes/CHANGE/ (default c5-model)
#   1. rbd.sh get: OUT -> a fresh scratch folder (W/fetch). The run's files are untrusted model output: nothing here writes
#      into them, follows a link in them, or runs them; everything is read as data (python3 -I) after the tree check
#   2. tree check: only real folders and regular files (no symlink, device, fifo), nothing beside RUN, at most 5 MB in all
#   3. content checks: result.json ok; manifest rbd.agent-change/v1 lists exactly the files under files/ (sha256 and size as
#      listed, .go under maze/app/, at most 8); base_sha = state/main.sha (repo/ is that commit); the service is one of
#      repo/maze/spec.json; title one printable line <= 72; summary 1..1000 printable (newlines allowed); no CI-skip token
#      ([skip ci] and kin: the gate would never run); served_by/model names plain; a changed file keeps its build constraints
#      exactly (a new file has none) and has no //go:embed, //go:linkname, cgo directive or import "C";
#      rhobound-change.json is exactly {schema v1, services: [service], summary} or (SPEC2 4, the bench's runs)
#      {schema "rbd.change-request/v2", services: 1..3 distinct names of spec.json, the first the manifest's service,
#      summary, base?}: base (optional) must be a key of the kit's tools1/maze/bases.json (no bases.json: refused)
#   4. the files over a copy of repo/maze in a fresh git repo -> change.patch (git diff; only maze/app/*.go)
#   5. compiled here, never run, inside capped.sh (2G, GOMAXPROCS=2, timeout 600 s): go build ./... (default tags and
#      maze_v11) and go vet -tags maze_v11, offline (GOPROXY=off GOFLAGS=-mod=readonly GOTOOLCHAIN=local CGO_ENABLED=0
#      -buildvcs=false, GOTMPDIR on disk). The workstation's Go may be newer than the image's (1.26.9): an API newer than 1.26 compiles
#      here and fails in the CI build. Errors -> state/agent/RUN.compile.txt (exit 3: agent.py --feedback takes it)
#   6. the leak scan of publish_main.sh on the patch, title and summary (no public IPv4, no 12-digit number)
#   7. changes/c5-model/{change.patch, rhobound-change.json, title.txt, manifest.json}, the checked run in state/agent/RUN;
#      then: bash changes/make_prs.sh c5-model   (CHANGE is cN-model, or cN-bench for the pick of an earlier run's bench funnel)
# Exit 0 ok, 1 refused, 3 does not compile. Env: RBD_AGENT_LOCAL (tests: an OUT folder here instead of the fetch),
# RBD_AGENT_TAR (tests: a crafted tar stream instead of the fetch),
# RBD_CAPPED (the capped.sh to use; tests may set it to "" for none).
# shellcheck disable=SC2015,SC2016  # A && B || die is meant; go list templates are single-quoted
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
CAPPED=${RBD_CAPPED-$(dirname "$(readlink -f "$0")")/capped.sh}
say() { echo "[agent_take $(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "agent_take: error: $*" >&2; exit "${2:-1}"; }
[[ ($# -eq 1 || $# -eq 2) && $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "usage: agent_take.sh RUN [CHANGE] (letters, digits, - _)" 1
RUN=$1 CHANGE=${2:-c5-model}
[[ $CHANGE =~ ^c[0-9]{1,2}-(model|bench|muse)$ ]] || die "CHANGE must be cN-model, cN-bench or cN-muse (make_prs.sh opens it), not $CHANGE" 1
[[ -s $DEMO/state/main.sha ]] || die "no state/main.sha (orch/publish_main.sh writes it)"
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}; mkdir -p "$SCR"; W=$(mktemp -d "$SCR/agent_take.XXXXXX") || die "mktemp"
W=$(cd "$W" && pwd -P)   # canonical: go list prints real paths
trap 'rm -rf "$W"' EXIT
F=$W/fetch; mkdir -p "$F"
MAXTAR=6000000   # bytes of tar stream: a sparse or huge file on rbd-tools1 never becomes gigabytes here
if [[ -n ${RBD_AGENT_TAR:-} ]]; then
  head -c $((MAXTAR + 1)) "$RBD_AGENT_TAR" > "$W/run.tar"   # tests: a crafted tar stream
elif [[ -n ${RBD_AGENT_LOCAL:-} ]]; then
  tar -C "$(dirname "$RBD_AGENT_LOCAL")" -cf - --transform "s,^$(basename "$RBD_AGENT_LOCAL"),$RUN," "$(basename "$RBD_AGENT_LOCAL")" |
    head -c $((MAXTAR + 1)) > "$W/run.tar" || true   # tests: the same stream a fetch would bring (links stay links)
else
  bash "$DEMO/orch/rbd.sh" run tar -C /var/lib/rbd/agent -cf - "$RUN" 2> "$W/fetch.err" | head -c $((MAXTAR + 1)) > "$W/run.tar" || true
fi
sz=$(stat -c %s "$W/run.tar")
(( sz > 0 )) || die "cannot fetch /var/lib/rbd/agent/$RUN: $(head -c 300 "$W/fetch.err" 2> /dev/null | tr -cd '[:print:]\n')"
(( sz <= MAXTAR )) || die "the run's tar stream is over $MAXTAR bytes: refused before unpacking"
tar -xf "$W/run.tar" -C "$F" --no-same-owner --no-same-permissions --delay-directory-restore 2> "$W/untar.err" ||
  die "cannot unpack the run: $(head -c 300 "$W/untar.err" | tr -cd '[:print:]\n')"
chmod -R u+rwX,go-w "$F" 2> /dev/null || true   # a mode the archive asked for never hides a file from the check below
L=$F/$RUN

python3 -I - "$F" "$RUN" << 'EOF' || die "the fetched run is refused (above)"
import os, stat, sys
F, run = sys.argv[1], sys.argv[2]
def no(msg):
    sys.exit("agent_take: refused: " + msg)
top = os.listdir(F)
if top != [run]:
    no("the fetch holds %s, not only %s" % (sorted(top), run))
total = 0
def boom(e):
    no("cannot read %s: %s" % (getattr(e, "filename", "?"), e.strerror))
for d, dirs, names in os.walk(F, followlinks=False, onerror=boom):
    for n in dirs + names:
        q = os.path.join(d, n)
        st = os.lstat(q)
        if stat.S_ISDIR(st.st_mode):
            if st.st_mode & 0o700 != 0o700:
                no("a folder this user cannot list: %s" % os.path.relpath(q, F))
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            no("not a plain regular file or folder (link, device, fifo or hard link): %r" % os.path.relpath(q, F))
        if len(n.encode()) > 120 or not n.isprintable():
            no("an odd file name: %r" % n)
        total += st.st_size
if not stat.S_ISDIR(os.lstat(os.path.join(F, run)).st_mode):
    no("%s is not a folder" % run)
if total > 5_000_000:
    no("%d bytes in the run (at most 5 MB)" % total)
EOF

python3 -I - "$L" "$DEMO/repo" "$(head -c 64 "$DEMO/state/main.sha")" "$DEMO/tools1/maze/bases.json" << 'EOF' || die "the agent's output is refused (above)"
import hashlib, json, os, re, sys
L, repo, main_sha, bases = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def no(msg):
    sys.exit("agent_take: refused: " + msg)
def load(name, cap=1_000_000):
    p = os.path.join(L, name)
    if not os.path.isfile(p):
        no("no %s (the agent crashed? rbd.sh tail NAME)" % name)
    with open(p, "rb") as f:
        b = f.read(cap + 1)
    if len(b) > cap:
        no("%s is larger than %d bytes" % (name, cap))
    return json.loads(b.decode("utf-8"))
res = load("result.json")
if res.get("ok") is not True:
    no("the run did not submit: %s" % ascii(str(res.get("error"))[:500]))
man = load("manifest.json", 4_000_000)
if man.get("schema") != "rbd.agent-change/v1":
    no("manifest schema %r" % man.get("schema"))
if man.get("base_sha") != main_sha:
    no("the model worked on %r, but repo/ and state/main.sha are %s: re-run it on the current main" % (man.get("base_sha"), main_sha))
pat = re.compile(r"maze/app/(?:[A-Za-z0-9_][A-Za-z0-9_.-]*/)*[A-Za-z0-9_][A-Za-z0-9_.-]*\.go")
listed = {}
for f in man.get("files") or []:
    p = f.get("path", "") if isinstance(f, dict) else ""
    if not isinstance(p, str) or not pat.fullmatch(p) or "/../" in "/%s/" % p or "/./" in "/%s/" % p or p in listed:
        no("file path %r" % p)
    listed[p] = f
if not 1 <= len(listed) <= 8:
    no("%d files (1..8)" % len(listed))
root = os.path.join(L, "files")
found = set()
for d, dirs, names in os.walk(root, followlinks=False):
    for n in names:
        found.add(os.path.relpath(os.path.join(d, n), root).replace(os.sep, "/"))
if found != set(listed):
    no("files/ holds %s, the manifest lists %s" % (sorted(found), sorted(listed)))
directive = re.compile(r"^\s*//\s*(?:go:build|\+build)\b.*$", re.M)
banned = re.compile(r"^\s*//\s*(?:go:embed|go:linkname|go:cgo_\w+|export\s)|^\s*import\s+(?:\(\s*)?\"C\"|^\s*\"C\"\s*$", re.M)
for p, f in listed.items():
    with open(os.path.join(root, p), "rb") as fh:
        b = fh.read(100001)
    if len(b) > 100000 or hashlib.sha256(b).hexdigest() != f.get("sha256") or len(b) != f.get("bytes"):
        no("%s: size or sha256 differs from the manifest" % p)
    t = b.decode("utf-8")
    if "\ufeff" in t or any(c in t for c in "\u2028\u2029\u202e\u2066\u2067\u2068\u2069\u202a\u202b\u202c\u202d"):
        no("%s: a byte-order mark or bidirectional/line-separator character (it can hide a build constraint or code)" % p)
    o = os.path.join(repo, p)
    orig = open(o, encoding="utf-8").read() if os.path.isfile(o) else ""
    if [x.strip() for x in directive.findall(t)] != [x.strip() for x in directive.findall(orig)]:
        no("%s: its build constraints differ from main's (%s): the model may not change which files build" % (p, directive.findall(t)))
    m = banned.search(t)
    if m and not banned.search(orig):
        no("%s: %r is not allowed in a model-written change" % (p, m.group().strip()))
svcs = sorted(json.load(open(os.path.join(repo, "maze", "spec.json")))["services"])
svc, title, summ = man.get("service"), man.get("title"), man.get("summary")
if not isinstance(man.get("turns"), int):
    no("turns is not a number")
if svc not in svcs:
    no("service %r is not one of %s" % (svc, svcs))
if not isinstance(title, str) or not 1 <= len(title) <= 72 or not title.isprintable():
    no("title %r" % title)
if not isinstance(summ, str) or not 1 <= len(summ) <= 1000 or not all(c.isprintable() or c == "\n" for c in summ):
    no("summary: 1..1000 printable characters")
skip = re.compile(r"\[\s*(?:skip\s+ci|ci\s+skip|no\s+ci|skip\s+actions|actions\s+skip)\s*\]|skip-checks\s*:\s*true", re.I)
if skip.search(title) or skip.search(summ):
    no("the title or summary holds a CI-skip token (%r): the gate would not run" % (skip.search(title) or skip.search(summ)).group())
plain = re.compile(r"[A-Za-z0-9._:/-]{1,64}")
names = list(man.get("served_by") or []) + [man.get("model") or ""] + [c.get("tool", "") for c in man.get("mcp_calls") or []]
if not all(isinstance(n, str) and plain.fullmatch(n) for n in names):
    no("served_by / model / tool names are not plain names: %r" % names[:8])
rc = load("rhobound-change.json")
if not isinstance(rc, dict) or rc.get("schema") not in ("rbd.change-request/v1", "rbd.change-request/v2"):
    no("rhobound-change.json: schema must be rbd.change-request/v1 or /v2")
if rc["schema"] == "rbd.change-request/v1" and rc != {"schema": "rbd.change-request/v1", "services": [svc], "summary": summ}:
    no("rhobound-change.json is not {schema, services: [%s], summary} of the manifest" % svc)
if rc["schema"] == "rbd.change-request/v2":
    sv = rc.get("services")
    if set(rc) - {"schema", "services", "summary", "base"} or rc.get("summary") != summ:
        no("rhobound-change.json v2 is {schema, services, summary (the manifest's), base?}, not %s" % sorted(rc))
    if not isinstance(sv, list) or not 1 <= len(sv) <= 3 or not all(isinstance(s, str) for s in sv) or len(set(sv)) != len(sv) \
            or not all(s in svcs for s in sv) or sv[0] != svc:
        no("rhobound-change.json v2 services %r: 1..3 distinct names of spec.json, the first the manifest's %s" % (sv, svc))
    if "base" in rc:
        if not os.path.isfile(bases):
            no("rhobound-change.json names base %r but the kit has no tools1/maze/bases.json" % (rc["base"],))
        keys = json.load(open(bases))
        if not isinstance(rc["base"], str) or not isinstance(keys, dict) or rc["base"] not in keys:
            no("rhobound-change.json base %r is not a key of tools1/maze/bases.json" % (rc["base"],))
print("agent_take: %s: %d file(s) for %s by %s (%d turns, MCP calls: %s)" % (os.path.basename(L), len(listed), svc,
      ", ".join(man.get("served_by") or [man.get("model")]), man["turns"], ", ".join(c.get("tool", "?") for c in man.get("mcp_calls") or [])), file=sys.stderr)
EOF

G=$W/g; mkdir -p "$G"
cp -r "$DEMO/repo/maze" "$G/maze"
gi() { git -C "$G" -c user.name=agent_take -c user.email=agent-take@localhost "$@"; }
gi init -q -b main && gi add -A && gi commit -q -m base || die "git init/commit of repo/maze failed"
python3 -I - "$L/files" "$G" << 'EOF' || die "cannot place the files"
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for d, _, names in os.walk(src, followlinks=False):
    for n in names:
        rel = os.path.relpath(os.path.join(d, n), src)
        out = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        if os.path.lexists(out) and not os.path.isfile(out):
            sys.exit("not a file in repo/: %s" % rel)
        with open(os.path.join(d, n), "rb") as i, open(out, "wb") as o:
            shutil.copyfileobj(i, o)
EOF
gi add -A
outside=$(gi diff --cached --name-only | grep -Ev '^maze/app/.+\.go$' || true)
[[ -z $outside ]] || die "the change touches paths outside maze/app/*.go: $outside"
[[ -n $(gi diff --cached --name-only) ]] || die "the change is empty against repo/"
gi diff --cached > "$W/change.patch"

say "compiling (never running) the change here, capped: go build (default, maze_v11), go vet -tags maze_v11"
mkdir -p "$W/gotmp"   # go's work files on disk, never the /tmp tmpfs (it can fill)
# agent_take's own build cache (not the user's): trimmed when over 3 GB; every file the compile writes is capped at
# 256 MB (ulimit -f), so a model-written giant array fails to compile instead of filling the disk
GC=$SCR/agent-gocache; mkdir -p "$GC"
(( $(du -sm "$GC" | cut -f1) < 3000 )) || { say "trimming $GC"; rm -rf "$GC"; mkdir -p "$GC"; }
(( $(df -Pm "$GC" | awk 'NR==2 {print $4}') > 4000 )) || die "less than 4 GB free for the compile: refused (free space first)"
goenv=(env -i "PATH=$PATH" "HOME=$HOME" "GOPATH=$(go env GOPATH)" "GOCACHE=$GC" "GOMODCACHE=$(go env GOMODCACHE)"
  "GOTMPDIR=$W/gotmp" "TMPDIR=$W/gotmp" GOMAXPROCS=2 GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPROXY=off CGO_ENABLED=0
  GOOS=linux GOARCH=amd64)
cap=()
[[ -z $CAPPED ]] || cap=(env RB_MEM_MAX=2G bash "$CAPPED")
: > "$W/compile.txt"
ok=1
gorun() { (cd "$G/maze/app" && ulimit -f 262144 && "${cap[@]}" timeout 600 "${goenv[@]}" "$@"); }
for tags in "" maze_v11; do
  (gorun go build -trimpath -buildvcs=false -tags "$tags" -o /dev/null ./...) >> "$W/compile.txt" 2>&1 ||
    { ok=0; echo "(go build -tags '$tags' failed)" >> "$W/compile.txt"; }
done
(gorun go vet -tags maze_v11 ./...) >> "$W/compile.txt" 2>&1 ||
  { ok=0; echo "(go vet -tags maze_v11 failed)" >> "$W/compile.txt"; }
if [[ $ok == 1 ]]; then   # a changed file that neither tag set compiles here was never checked: refused
  for tags in "" maze_v11; do
    lf='{{$d := .Dir}}{{range .GoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}'
    # go vet -tags maze_v11 compiled the packages' test files too: they were checked
    [[ $tags == maze_v11 ]] && lf+='{{range .TestGoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .XTestGoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}'
    gorun go list -tags "$tags" -f "$lf" ./... >> "$W/built.txt" 2>> "$W/compile.txt" || ok=0
  done
  while IFS= read -r f; do
    grep -qxF "$G/$f" "$W/built.txt" || die "$f is compiled under neither the default tags nor maze_v11 here: it was never checked (refused)"
  done < <(gi diff --cached --name-only)
fi
mkdir -p "$DEMO/state/agent"
if [[ $ok != 1 ]]; then
  rm -f "$DEMO/state/agent/$RUN.compile.txt"; cp "$W/compile.txt" "$DEMO/state/agent/$RUN.compile.txt"
  sed 's/[^[:print:]\t]//g' "$W/compile.txt" | tail -30 >&2
  die "the change does not compile: state/agent/$RUN.compile.txt (agent.py --feedback takes it)" 3
fi
fmt=$(cd "$G" && gi diff --cached --name-only -z | xargs -0 gofmt -l 2> /dev/null || true)   # the changed files only
[[ -z $fmt ]] || say "gofmt would reformat: $fmt (not refused)"

python3 -I - "$W/change.patch" "$L/manifest.json" << 'EOF' || die "the leak scan refuses the change (above)"
import ipaddress, json, re, sys
ok = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "0.0.0.0/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                        "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
ip = re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])(?!\.[0-9])")
n12 = re.compile(r"(?<![0-9A-Za-z_])(?<![0-9]\.)[0-9]{12}(?![0-9A-Za-z_])(?!\.[0-9])")
man = json.load(open(sys.argv[2]))
texts = [("change.patch", open(sys.argv[1], encoding="utf-8").read()), ("title", man["title"]), ("summary", man["summary"])]
bad = 0
for name, t in texts:
    for i, line in enumerate(t.splitlines(), 1):
        for m in ip.finditer(line):
            try:
                a = ipaddress.ip_address(m.group())
            except ValueError:
                print("%s:%d: %s looks like an address and does not parse: refused" % (name, i, m.group()), file=sys.stderr); bad += 1
                continue
            if not any(a in n for n in ok):
                print("%s:%d: IPv4 %s" % (name, i, a), file=sys.stderr); bad += 1
        for m in n12.finditer(line):
            print("%s:%d: 12-digit number %s" % (name, i, m.group()), file=sys.stderr); bad += 1
sys.exit(1 if bad else 0)
EOF

C=$DEMO/changes/$CHANGE
rm -rf "$C"; mkdir -p "$C"
cp "$W/change.patch" "$C/change.patch"
cp "$L/rhobound-change.json" "$C/rhobound-change.json"
python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$L/manifest.json" > "$C/title.txt"
cp "$L/manifest.json" "$C/manifest.json"
rm -rf "$DEMO/state/agent/$RUN"; cp -R "$L" "$DEMO/state/agent/$RUN"   # the checked run (regular files only), for the record
git -C "$G" diff --cached --stat >&2
say "changes/$CHANGE written ($(wc -l < "$C/change.patch") patch lines); next: bash changes/make_prs.sh $CHANGE"
