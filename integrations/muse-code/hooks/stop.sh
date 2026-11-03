#!/bin/sh
# rhobound for Muse Code: the Stop hook (see ../README.md). It runs `rhobound-mcp muse-hook stop`, which exits 10 with a
# fixed reason when an armed session changed files and made no rhobound preview, once per session. Exit 10 becomes
# Muse's blocking exit 2 (one continuation, with the reason); every other status, an older binary's 2, a crash or a
# signal, becomes 0 with nothing printed. It never execs the binary, so no other status can reach Muse.
set -f
# --- find rhobound-mcp (the same block in every hook): absolute PATH entries, then the usual install folders of the
# home folder from the user database (HOME only when the database has none), never a folder under the current one (the
# workspace: a host that points HOME or PATH into it must not make the hook run a binary the repository ships) ---
home=$( (PATH=/usr/bin:/bin; getent passwd "$(id -u)" | cut -d: -f6) 2>/dev/null)
case $home in /*) ;; *) home=$( (PATH=/usr/bin:/bin; dscl . -read "/Users/$(id -un)" NFSHomeDirectory | sed -n 's/^NFSHomeDirectory: //p') 2>/dev/null) ;; esac
case $home in /*) ;; *) case ${HOME-} in /*) home=$HOME ;; *) home= ;; esac ;; esac
# The current folder and each candidate are compared as the kernel resolves them (links, "//", ".."), and as written.
here=$(pwd -P 2>/dev/null) || here=/
bin=
_ifs=$IFS
IFS=:
for d in ${PATH-} ${home:+$home/.local/bin} ${home:+$home/go/bin} /usr/local/bin /opt/homebrew/bin; do
	case $d in /*) ;; *) continue ;; esac
	dp=$(cd "$d" 2>/dev/null && pwd -P) || continue
	if [ "$here" != / ]; then
		case $dp/ in "$here"/*) continue ;; esac
		case $d/ in "${PWD%/}"/*) continue ;; esac
	fi
	if [ -f "$dp/rhobound-mcp" ] && [ -x "$dp/rhobound-mcp" ]; then bin=$dp/rhobound-mcp; break; fi
done
IFS=$_ifs
# --- end ---
[ -n "$bin" ] || exit 0
# The binary's stderr (the reason) and then its exit status, one per line, from a subshell whose own stderr (a shell's
# notice of a signal) is discarded.
out=$( ( "$bin" muse-hook stop 2>&1 >/dev/null; echo "$?" ) 2>/dev/null )
nl='
'
st=${out##*"$nl"}
case $out in *"$nl"*) reason=${out%"$nl"*} ;; *) reason= ;; esac
if [ "$st" = 10 ] && [ -n "$reason" ]; then
	printf '%s\n' "$reason" >&2
	exit 2
fi
exit 0
