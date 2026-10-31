#!/usr/bin/env bash
# publish_main.sh   the PRIVATE GitHub repo's main = this kit's repo/ (part D), pushed once from here (SPEC 6, 8). The orchestrator
#   runs it with gh before `rbd_bootstrap.sh images`, which then builds production from exactly that commit:
#   1. gh must be logged in with the repo and workflow scopes (the first push holds .github/workflows/*.yml)
#   2. repo/ is copied into a fresh folder under RBD_TMP, leak-scanned (no IPv4 literal outside 127/8, 0.0.0.0, RFC 1918 and the
#      documentation ranges; no standalone 12-digit number that is not part of a decimal fraction: an AWS account id) and
#      committed once on main (author: the gh account's noreply address; a Co-Authored-By trailer)
#   3. REPO is created (private) when missing; an existing one must be private. Merge commits only (no squash, no rebase:
#      deploy.yml finds the PR as the merge commit's second parent), the workflow token read-only by default
#   4. GitHub has no main: it is pushed. GitHub's main holds the same tree: nothing is pushed. Another tree: refused (never a
#      force-push; merged PRs move main on, and state/main.sha keeps the published commit)
#   5. state/main.sha = GitHub main's sha; printed as the last line
# Env: REPO [RBD_GH_REPO, as rbd_bootstrap.sh; Sharvil2704/rhobound-demo]  URL [https://github.com/REPO.git; tests: a local bare repo]  DRYRUN [0; 1 = steps 1-2,
#   the reads of 3-4, no create, no edit, no push, no state/main.sha]  RBD_REPO_DIR [demo1/repo]  RBD_TMP [$HOME/rbd-dev/tmp]
# Exit 0 published (or already there); 1 refused or failed; 2 usage. git over https uses gh as its credential helper.
# shellcheck disable=SC2015
set -uo pipefail
RBD_ME=publish_main
# shellcheck source=rbd_lib.sh
. "$(dirname "$(readlink -f "$0")")/rbd_lib.sh"
REPO=${REPO:-${RBD_GH_REPO:-Sharvil2704/rhobound-demo}}
URL=${URL:-https://github.com/$REPO.git}
DRYRUN=${DRYRUN:-0}
REPO_DIR=${RBD_REPO_DIR:-$DEMO/repo}
SCRATCH=${RBD_TMP:-$HOME/rbd-dev/tmp}
[ $# = 0 ] || { sed -n '2,/^# shellcheck/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
[[ $REPO =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "bad REPO: $REPO" 2
[ -d "$REPO_DIR/kshop/app" ] && [ -f "$REPO_DIR/policy/gate.json" ] || die "no $REPO_DIR/kshop/app or policy/gate.json (part D's repo/)" 2
for c in gh git python3 jq; do command -v "$c" > /dev/null || die "$c is required"; done
gitc() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }

# ------------------------------------------------------------------------------------------------------------------------- 1. gh
st=$(gh auth status 2>&1) || die "gh is not logged in (gh auth login)"
scopes=$(sed -n 's/.*Token scopes: *//p' <<< "$st" | head -n 1)
for s in repo workflow; do
  grep -q "'$s'" <<< "$scopes" || die "gh's token lacks the '$s' scope (scopes: ${scopes:-none shown}): gh auth refresh -h github.com -s repo,workflow"
done
read -r gid glogin < <(gh api user -q '"\(.id) \(.login)"') && [[ ${gid:-} =~ ^[0-9]+$ && -n ${glogin:-} ]] || die "cannot read the gh account (gh api user)"

# ------------------------------------------------------------------------------------------------------------------------- 2. copy, scan, commit
mkdir -p "$SCRATCH"; W=$(mktemp -d "$SCRATCH/publish_main.XXXXXX") || die "mktemp"
trap 'rm -rf "$W"' EXIT
M=$W/main; mkdir -p "$M"
tar -C "$REPO_DIR" --exclude=.git -cf - . | tar -x -C "$M" || die "cannot copy $REPO_DIR"
git -C "$M" init -q -b main && git -C "$M" add -A || die "git init/add failed in $M"
git -C "$M" ls-files -z | (cd "$M" && xargs -0 python3 -I -c '
import ipaddress, re, sys
ok = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "0.0.0.0/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                        "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
ip = re.compile(rb"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])(?!\.[0-9])")
n12 = re.compile(rb"(?<![0-9A-Za-z_])(?<![0-9]\.)[0-9]{12}(?![0-9A-Za-z_])(?!\.[0-9])")
bad = 0
for p in sys.argv[1:]:
    for i, line in enumerate(open(p, "rb"), 1):
        for m in ip.finditer(line):
            try:
                a = ipaddress.ip_address(m.group().decode())
            except ValueError:
                continue
            if not any(a in n for n in ok):
                print("%s:%d: IPv4 %s" % (p, i, a), file=sys.stderr); bad += 1
        for m in n12.finditer(line):
            print("%s:%d: 12-digit number %s (an account id?)" % (p, i, m.group().decode()), file=sys.stderr); bad += 1
sys.exit(1 if bad else 0)
') || die "the leak scan refuses $REPO_DIR (the lines above): nothing was created or pushed"
nf=$(git -C "$M" ls-files | wc -l)
git -C "$M" -c user.name="$glogin" -c user.email="$gid+$glogin@users.noreply.github.com" -c commit.gpgsign=false commit -q \
  -m "kshop demo main: the services, the gate policy and the workflows" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" || die "git commit failed"
tree=$(git -C "$M" rev-parse 'HEAD^{tree}') || die "no tree"
log "repo/: $nf files scanned clean, tree ${tree:0:12}"

# ------------------------------------------------------------------------------------------------------------------------- 3. the GitHub repo
view() { gh repo view "$REPO" --json visibility,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed 2> "$W/view.err"; }
missing=""
if ! info=$(view); then
  grep -qE 'Could not resolve to a Repository|HTTP 404' "$W/view.err" || die "gh repo view $REPO failed: $(head -c 300 "$W/view.err")"
  if [ "$DRYRUN" = 1 ]; then log "DRYRUN: would create $REPO (private)"; info='{"visibility":"PRIVATE"}'; missing=1
  else
    gh repo create "$REPO" --private --description "rhobound demo: kshop and its latency gate (private)" > /dev/null || die "gh repo create $REPO failed"
    log "created $REPO (private)"
    info=$(view) || die "gh repo view $REPO failed after the create: $(head -c 300 "$W/view.err")"
  fi
fi
[ "$(jq -r .visibility <<< "$info")" = PRIVATE ] || die "$REPO is $(jq -r .visibility <<< "$info"), not PRIVATE: refusing"
if [ "$DRYRUN" = 1 ]; then log "DRYRUN: would set merge commits only and the workflow token to read"
else
  gh repo edit "$REPO" --enable-merge-commit --enable-squash-merge=false --enable-rebase-merge=false > /dev/null || die "gh repo edit $REPO failed"
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" -f default_workflow_permissions=read > /dev/null || die "cannot set $REPO's workflow token to read"
  info=$(view) || die "gh repo view $REPO failed: $(head -c 300 "$W/view.err")"
  [ "$(jq -c '[.mergeCommitAllowed, .squashMergeAllowed, .rebaseMergeAllowed]' <<< "$info")" = '[true,false,false]' ] \
    || die "$REPO does not allow merge commits only: $info"
  [ "$(gh api "repos/$REPO/actions/permissions/workflow" --jq .default_workflow_permissions)" = read ] || die "$REPO's workflow token is not read-only"
fi

# ------------------------------------------------------------------------------------------------------------------------- 4. main
rsha=""
[ -n "$missing" ] || rsha=$(gitc ls-remote "$URL" refs/heads/main 2> "$W/ls.err" | cut -f1) || die "cannot read $URL: $(head -c 300 "$W/ls.err")"
if [ -n "$rsha" ]; then
  gitc -C "$M" fetch -q "$URL" refs/heads/main 2> "$W/fetch.err" || die "cannot fetch $URL main: $(head -c 300 "$W/fetch.err")"
  rtree=$(git -C "$M" rev-parse 'FETCH_HEAD^{tree}') || die "no tree for GitHub main"
  [ "$rtree" = "$tree" ] || die "GitHub main ${rsha:0:12} (tree ${rtree:0:12}) is not repo/ (tree ${tree:0:12}): refusing, never a force-push (merged PRs move main on: state/main.sha keeps the published commit)"
  log "GitHub main ${rsha:0:12} already holds repo/'s tree: nothing pushed"
  sha=$rsha
elif [ "$DRYRUN" = 1 ]; then
  log "DRYRUN: would push main $(git -C "$M" rev-parse HEAD) to $URL"; exit 0
else
  gitc -C "$M" push -q "$URL" refs/heads/main:refs/heads/main 2> "$W/push.err" || die "push of main to $URL failed: $(head -c 300 "$W/push.err")"
  sha=$(git -C "$M" rev-parse HEAD)
  [ "$(gitc ls-remote "$URL" refs/heads/main | cut -f1)" = "$sha" ] || die "GitHub main is not $sha after the push"
  log "pushed main ${sha:0:12} to $REPO"
fi
[ "$DRYRUN" = 1 ] && { log "DRYRUN: state/main.sha not written"; echo "$sha"; exit 0; }

# ------------------------------------------------------------------------------------------------------------------------- 5. state/main.sha
mkdir -p "$STATE" && printf '%s\n' "$sha" > "$STATE/.main.sha.new" && mv -f "$STATE/.main.sha.new" "$STATE/main.sha" || die "cannot write $STATE/main.sha"
log "state/main.sha = $sha (rbd_bootstrap.sh images builds production from it)"
echo "$sha"
