#!/usr/bin/env bash
# run_all.sh [--quick]   every offline test of part B (orch/ and its tools1/ files). No ssh, aws, kubectl, docker or gh runs:
# stubs stand in for them. --quick skips test_capture_refit.sh (570 MB of spans, ~1 min; it runs under capped.sh, RB_MEM_MAX=4G).
# Needs build/rhobound-arm64, $HOME/rbd-dev/capture and, for test_mcp.sh, an arm64 rhobound-mcp
# ($HOME/rbd-dev/tmp/partB/arm64/rhobound-mcp; built from this repository like build/linux-amd64). Exit 0 when all pass.
set -uo pipefail
H=$(dirname "$(readlink -f "$0")")
rc=0
run() { echo "== $1"; if "${@:2}"; then :; else rc=1; echo "!! $1 FAILED"; fi; }
run static bash "$H/test_static.sh"
run copy_traces bash "$H/test_copy_traces.sh"
run lock bash "$H/test_lock.sh"
run orch_dry bash "$H/test_orch_dry.sh"
run publish_main bash "$H/test_publish_main.sh"
run regate bash "$H/test_regate.sh"
run tools1_steps bash "$H/test_tools1_steps.sh"
run load bash "$H/test_load.sh"
run mcp bash "$H/test_mcp.sh"
[ "${1:-}" = --quick ] || run capture_refit env RB_MEM_MAX=4G bash "$HOME"/rbd-dev/capped.sh bash "$H/test_capture_refit.sh"
echo "== run_all: $([ $rc = 0 ] && echo ALL PASSED || echo FAILURES)"
exit $rc
