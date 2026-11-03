#!/usr/bin/env bash
# run_all.sh [--quick]   every offline test of part B (orch/ and its tools1/ files). No ssh, aws, kubectl, docker or gh runs:
# stubs stand in for them. --quick skips test_capture_refit.sh (570 MB of spans, ~1 min; it runs under capped.sh, RB_MEM_MAX=4G).
# The tests of a recorded production capture and of the MCP server over the tunnel need research data that does not ship
# with this repository; they are not here (the MCP server has its own tests in mcp/). Exit 0 when all pass.
set -uo pipefail
H=$(dirname "$(readlink -f "$0")")
rc=0
run() { echo "== $1"; if "${@:2}"; then :; else rc=1; echo "!! $1 FAILED"; fi; }
run static bash "$H/test_static.sh"
run render python3 -I "$H/test_render.py"
run copy_traces bash "$H/test_copy_traces.sh"
run lock bash "$H/test_lock.sh"
run orch_dry bash "$H/test_orch_dry.sh"
run publish_main bash "$H/test_publish_main.sh"
run tools1_steps bash "$H/test_tools1_steps.sh"
run load bash "$H/test_load.sh"
echo "== run_all: $([ $rc = 0 ] && echo ALL PASSED || echo FAILURES)"
exit $rc
