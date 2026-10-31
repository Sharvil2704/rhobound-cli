#!/usr/bin/env bash
# test_regate.sh: RUNBOOK step 6's re-gate snippet, run as written against a local bare repo (round-2 day walk-through finding:
# git has no identity on this box, so a plain `git commit` failed and the push then pushed nothing). The snippet's GitHub URL
# and scratch folder are pointed at T; gh is a stand-in that answers `gh api user`; HOME is an empty folder (no gitconfig).
# shellcheck disable=SC2016  # test code: single-quoted programs
# shellcheck source=orch/tests/lib.sh
. "$(dirname "$0")/lib.sh"
RB=$DEMO/orch/RUNBOOK.md
snip=$(awk '/^\*\*Re-gate\.\*\*/{r=1} r&&/^```$/{if(f){exit}; f=1; next} r&&f' "$RB")
check "the RUNBOOK has the re-gate snippet (a subshell with set -euo pipefail)" grep -q '^( set -euo pipefail$' <<< "$snip"
snip=${snip//https:\/\/github.com\/Sharvil2704\/rhobound-demo.git/$T/origin.git}
snip=${snip//\$HOME\/rbd-dev\/tmp\/regate-/$T/regate-}
snip=${snip//<c>/c9}
check "every GitHub URL and the scratch path of the snippet were redirected to T" bash -c '! grep -q "https://github.com" <<< "$1" && grep -qF "D=$2/regate-c9;" <<< "$1"' _ "$snip" "$T"

git init -q --bare -b main "$T/origin.git"
git -C "$T" init -q -b rbd/c9 seed
git -C "$T/seed" -c user.name=s -c user.email=s@e commit -q --allow-empty -m "c9"
git -C "$T/seed" push -q "$T/origin.git" rbd/c9
before=$(git -C "$T/origin.git" rev-parse rbd/c9)
mkdir -p "$T/home"
printf '#!/bin/bash\n[ "$1 $2" = "api user" ] && { [ -n "${GH_FAIL:-}" ] && exit 1; echo "4242 tester"; exit 0; }\necho "gh stand-in: unexpected: $*" >&2; exit 97\n' > "$T/bin/gh"
chmod +x "$T/bin/gh"
regate() { env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u EMAIL \
  HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$T/home/.config" "$@" bash -c "$snip" > "$T/out" 2>&1; }

GH_FAIL=1 regate env
rc=$?
check "gh cannot name the account: the snippet stops before any commit or push (exit $rc)" \
  test "$rc" -ne 0 -a "$(git -C "$T/origin.git" rev-parse rbd/c9)" = "$before"
regate env
rc=$?
after=$(git -C "$T/origin.git" rev-parse rbd/c9)
check "with no git identity on the box: commits as the gh account and pushes one new empty commit (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  [ '$after' != '$before' ] && [ \"\$(git -C '$T/origin.git' rev-parse '$after^')\" = '$before' ] &&
  [ \"\$(git -C '$T/origin.git' log -1 --format='%an <%ae> %s' '$after')\" = 'tester <4242+tester@users.noreply.github.com> regate c9' ] &&
  [ -z \"\$(git -C '$T/origin.git' diff '$before' '$after')\" ]" || cat "$T/out"
finish
