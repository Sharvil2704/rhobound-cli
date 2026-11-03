#!/bin/sh
# rhobound for Muse Code: the SessionStart hook (see ../README.md). It runs `rhobound-mcp muse-hook session-start`, which
# arms the once-per-session Stop reminder in a repository that opts in (.rhobound/muse.json). It prints nothing, since
# Muse reads a SessionStart hook's standard output as context, and it always exits 0. It never execs the binary: an
# older rhobound-mcp answers an unknown verb with exit 2, which Muse would take as a block.
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
# In a subshell with a second command, so a shell's own notice of a signal ("Killed") is discarded too.
( "$bin" muse-hook session-start; : ) >/dev/null 2>&1
exit 0
