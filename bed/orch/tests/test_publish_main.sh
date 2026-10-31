#!/usr/bin/env bash
# test_publish_main.sh: orch/publish_main.sh against a gh stub (a fake GitHub: the repo's settings kept in files) and a LOCAL bare
# repo as URL (nothing reaches GitHub): the scope check, the leak scan, DRYRUN, the first push (one commit, the trailer, the noreply
# author, state/main.sha), a second run that pushes nothing, a changed repo/ refused without a push, a public repo refused.
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
P=$DEMO/orch/publish_main.sh
GH=$T/gh; mkdir -p "$GH"
cat > "$T/bin/gh" << 'EOF'
#!/usr/bin/env bash
# fake gh: logs every call; the repo's settings live in $GH (exists, visibility, merge flags, workflow permission)
echo "gh $*" >> "$STUB_LOG"
G=${FAKE_GH:?}
case "$*" in
  "auth status") printf 'github.com\n  ✓ Logged in to github.com account tester (keyring)\n  - Token: gho_************************************\n  - Token scopes: %s\n' "${STUB_GH_SCOPES-'gist', 'repo', 'workflow'}" ;;
  "api user -q "*) echo "4242 tester" ;;
  "repo view "*) [ -e "$G/exists" ] || { echo "GraphQL: Could not resolve to a Repository with the name '${3}'. (repository)" >&2; exit 1; }
                 printf '{"visibility":"%s","mergeCommitAllowed":%s,"squashMergeAllowed":%s,"rebaseMergeAllowed":%s}\n' \
                   "$(cat "$G/visibility")" "$(cat "$G/merge")" "$(cat "$G/squash")" "$(cat "$G/rebase")" ;;
  "repo create "*" --private "*) touch "$G/exists"; echo PRIVATE > "$G/visibility"; echo true > "$G/merge"; echo true > "$G/squash"; echo true > "$G/rebase" ;;
  "repo edit "*" --enable-merge-commit --enable-squash-merge=false --enable-rebase-merge=false") echo true > "$G/merge"; echo false > "$G/squash"; echo false > "$G/rebase" ;;
  "api -X PUT repos/"*"/actions/permissions/workflow -f default_workflow_permissions=read") echo read > "$G/wfperm" ;;
  "api repos/"*"/actions/permissions/workflow --jq .default_workflow_permissions") cat "$G/wfperm" 2> /dev/null || echo write ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$T/bin/gh"
export FAKE_GH=$GH RBD_STATE=$T/state RBD_TMP=$T/scratch URL=$T/bare.git REPO=Sharvil2704/rhobound-demo
mkdir -p "$T/repo" && tar -C "$DEMO/repo" --exclude=.git -cf - . | tar -x -C "$T/repo"
export RBD_REPO_DIR=$T/repo
git init -q --bare "$URL"
bare() { git --git-dir="$URL" "$@"; }
pub() { bash "$P" > "$T/p.out" 2> "$T/p.err"; }
scratch_empty() { [ -z "$(ls -A "$T/scratch" 2> /dev/null)" ]; }

echo "-- refusals before anything is created"
STUB_GH_SCOPES="'gist', 'repo'" pub; rc=$?
check "a token without the workflow scope is refused (rc $rc)" [ $rc = 1 ] && check "...naming the scope and the fix" grep -q "lacks the 'workflow' scope.*gh auth refresh" "$T/p.err"
check "...nothing created" bash -c "! grep -q 'gh repo create' '$STUB_LOG' && [ ! -e '$GH/exists' ]"
pubip=$(printf '%d.%d.%d.%d' 8 8 4 4); acct=$(printf '%06d%06d' 112233 445566)
cp -a "$T/repo" "$T/leak1"; printf 'the cluster answers on %s\n' "$pubip" >> "$T/leak1/README.md"
RBD_REPO_DIR=$T/leak1 pub; rc=$?
check "a public IPv4 in repo/ is refused (rc $rc)" [ $rc = 1 ] && check "...file, line and address named" grep -q "README.md:[0-9]*: IPv4 $pubip" "$T/p.err"
check "...nothing created, no main pushed, the temp folder gone" bash -c "! grep -q 'gh repo create' '$STUB_LOG' && [ -z \"\$(git --git-dir='$URL' for-each-ref)\" ] && [ -z \"\$(ls -A '$T/scratch')\" ]"
cp -a "$T/repo" "$T/leak2"; printf 'arn:aws:iam::%s:role/x\n' "$acct" > "$T/leak2/kshop/notes.txt"
RBD_REPO_DIR=$T/leak2 pub; rc=$?
check "a standalone 12-digit number (an account id) is refused (rc $rc)" [ $rc = 1 ] && check "...named" grep -q "kshop/notes.txt:1: 12-digit number $acct" "$T/p.err"
cp -a "$T/repo" "$T/leak3"
printf 'docs %s %s %s %s %s %s\npi 0.%s, %s.5, hex a%sb, 13 digits %s1, version 1.26.9\n' 198.51.100.7 192.0.2.1 203.0.113.9 10.42.0.1 192.168.1.1 127.0.0.53 \
  "$acct" "$acct" "$acct" "$acct" > "$T/leak3/kshop/ok.txt"
printf '%s\n' "$pubip" > "$T/leak3/ignored.jsonl"   # repo/.gitignore drops *.jsonl: never committed, never scanned
: > "$STUB_LOG"
DRYRUN=1 RBD_REPO_DIR=$T/leak3 pub; rc=$?
check "documentation/private ranges, decimal fractions, hex and longer numbers pass; ignored files are not scanned (DRYRUN, rc $rc)" [ $rc = 0 ] || cat "$T/p.err"

echo "-- DRYRUN"
: > "$STUB_LOG"
DRYRUN=1 pub; rc=$?
check "DRYRUN exit 0 (rc $rc)" [ $rc = 0 ] && check "...would create, set and push" bash -c "grep -q 'DRYRUN: would create' '$T/p.err' && grep -q 'DRYRUN: would push main' '$T/p.err'"
check "...nothing created, edited or pushed; no state/main.sha" bash -c "! grep -qE 'gh (repo (create|edit)|api -X)' '$STUB_LOG' && [ -z \"\$(git --git-dir='$URL' for-each-ref)\" ] && [ ! -e '$RBD_STATE/main.sha' ]"

echo "-- the first push"
: > "$STUB_LOG"
pub; rc=$?
sha=$(tail -n 1 "$T/p.out")
check "publish exit 0 (rc $rc)" [ $rc = 0 ] || cat "$T/p.err"
check "the repo was created private, merge commits only, workflow token read" bash -c "grep -q 'gh repo create Sharvil2704/rhobound-demo --private' '$STUB_LOG' && grep -q 'gh repo edit Sharvil2704/rhobound-demo --enable-merge-commit --enable-squash-merge=false --enable-rebase-merge=false' '$STUB_LOG' && grep -q 'gh api -X PUT repos/Sharvil2704/rhobound-demo/actions/permissions/workflow -f default_workflow_permissions=read' '$STUB_LOG'"
check "main pushed: the printed sha is the bare repo's main ($sha)" [ "$(bare rev-parse refs/heads/main 2> /dev/null)" = "$sha" ]
check "state/main.sha = that sha" [ "$(cat "$RBD_STATE/main.sha")" = "$sha" ]
check "one commit, no other branch" bash -c "[ \$(git --git-dir='$URL' rev-list --count main) = 1 ] && [ \"\$(git --git-dir='$URL' for-each-ref --format='%(refname)')\" = refs/heads/main ]"
check "author: the gh account's noreply address; the Co-Authored-By trailer" bash -c "[ \"\$(git --git-dir='$URL' log -1 --format='%an <%ae>' main)\" = 'tester <4242+tester@users.noreply.github.com>' ] && git --git-dir='$URL' log -1 --format=%B main | grep -qx 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'"
want=$(cd "$T/repo" && git init -q "$T/ref" && cp -a . "$T/ref/" && cd "$T/ref" && git add -A && git ls-files | sort | tr '\n' ' ')
check "main holds repo/'s files (gitignored ones excluded)" [ "$(bare ls-tree -r --name-only main | sort | tr '\n' ' ')" = "$want" ]
check "...byte for byte (policy/gate.json, the workflows)" bash -c "for f in policy/gate.json .github/workflows/gate.yml .github/workflows/deploy.yml kshop/app/internal/work/lib_v11.go; do cmp -s <(git --git-dir='$URL' show main:\$f) '$T/repo/'\$f || { echo \$f; exit 1; }; done"
check "the temp folder is gone" scratch_empty

echo "-- again: nothing to push"
: > "$STUB_LOG"; rm -f "$RBD_STATE/main.sha"
pub; rc=$?
check "a second run: exit 0 (rc $rc), nothing pushed" bash -c "[ $rc = 0 ] && grep -q 'already holds repo/.s tree: nothing pushed' '$T/p.err' && [ \"\$(git --git-dir='$URL' rev-parse main)\" = $sha ]"
check "...state/main.sha written again, the same sha" [ "$(cat "$RBD_STATE/main.sha" 2> /dev/null)" = "$sha" ] && [ "$(tail -n 1 "$T/p.out")" = "$sha" ]
check "...no repo create (it exists)" bash -c "! grep -q 'gh repo create' '$STUB_LOG'"

echo "-- repo/ changed after the push: refused"
echo "// changed" >> "$T/repo/kshop/app/internal/work/lib_v11.go"
pub; rc=$?
check "a different tree is refused (rc $rc), never force-pushed" bash -c "[ $rc = 1 ] && grep -q 'is not repo/ .*refusing, never a force-push' '$T/p.err' && [ \"\$(git --git-dir='$URL' rev-parse main)\" = $sha ]"
check "...state/main.sha keeps the published sha" [ "$(cat "$RBD_STATE/main.sha")" = "$sha" ]
echo PUBLIC > "$GH/visibility"
pub; rc=$?
check "a public repo is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'is PUBLIC, not PRIVATE' '$T/p.err'"
check "gh was asked nothing unexpected" bash -c "! grep -q 'unexpected' '$T/p.err'"
finish
