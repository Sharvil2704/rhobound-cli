#!/usr/bin/env bash
# rhobound-fast.sh - one front door for the Go CLI (bed-spec3) and the Rust accelerator (rbfast).
#
# RULE (from the dry test on the AWS spec3 captures, 4 captures x 7 variants, see the matrix below):
#   1. rbfast ports the FIRST-release Go (6841f9f), not bed-spec3. On every AWS capture it is byte-identical to that
#      Go and ~8x faster (0.077 s vs 0.64 s), but it is NOT byte-identical to bed-spec3's Go: the newer Go reads the
#      network time per edge (hop), so model_ms differs by up to 0.34% per service and `infer` writes call objects with hops.
#      So the Go binary (bed-spec3) answers by default.
#   2. rbfast answers only where parity with bed-spec3 holds on this data, or where there is no Go equivalent:
#        model TOPOLOGY      byte-identical to bed-spec3 when the topology has no `hop` on a call (all 4 captures'
#                            first-release topologies); rbfast refuses a topology with a call hop (fix rbfast-fix), and then
#                            this script falls back to Go.
#        sweep, read         rbfast only (Go has no such command).
#   3. Opt-in speed mode: RHOBOUND_FAST_APPROX=1 sends `predict CAPTURE` and `infer CAPTURE` (capture form, no --fit/--changes/
#      --load-scale) to rbfast too, accepting the first-release network-time rule (<=0.34% on model_ms here; no top-level field differs).
#      A note on stderr says so. Without it these go to Go.
#   4. Everything else is Go only (rbfast lacks it): fit, check, budget, context, diff-fit, explain, gate (incl. policy block_band
#      "model"), judge-check, judge-packet, preview, predict --fit/--changes/--load-scale/--report, structured --json refusals.
#
# COVERAGE MATRIX (bed-spec3 command / flag -> rbfast ; implementation used by this script)
#   predict CAPTURE [--patch --workers --kept-share --max-rho --plain --out --json]  rbfast: yes (first-release rules) ; Go default, rbfast with RHOBOUND_FAST_APPROX=1
#   infer CAPTURE                                                                    rbfast: yes (no per-call hop)    ; Go default, rbfast with RHOBOUND_FAST_APPROX=1
#   model TOPOLOGY --rps ...                                                         rbfast: yes (identical w/o call hop; refuses call hop) ; rbfast, Go on refusal
#   sweep / read                                                                     rbfast only                      ; rbfast
#   fit, check (--window mixed_images SPEC3 F5, --manifest, --write-manifest, --cut) rbfast: no                       ; Go (bed-spec3)
#   predict --fit F [--changes C] [--load-scale S] [--report v1]  (SPEC3 F4)         rbfast: no                       ; Go (bed-spec3)
#   gate, policy key block_band "model" (SPEC3 F1), judge-check, judge-packet        rbfast: no                       ; Go (bed-spec3)
#   budget, context, diff-fit, explain, preview                                      rbfast: no                       ; Go (bed-spec3)
#   structured JSON refusal on stdout (--json error codes)                           rbfast: no (stderr text only)    ; Go (bed-spec3)
#   capture (tools1 capture scripts; check --write-manifest)                         not a rhobound command / rbfast: no ; Go + the kit's scripts
#   rhobound-mcp (MCP server, nested Go module bed/mcp)                              rbfast: no                       ; Go (rhobound-mcp binary, not wrapped here)
#
# Binaries: RHOBOUND_BIN (bed-spec3 Go, default: rhobound next to this script, else on PATH),
#           RBFAST_BIN (default: rbfast next to this script, else on PATH).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pick() { # name, env override
  local v=${!2:-}; if [ -n "$v" ]; then echo "$v"; elif [ -x "$here/$1" ]; then echo "$here/$1"; else command -v "$1" || echo "$1"; fi
}
GO=$(pick rhobound RHOBOUND_BIN)
FAST=$(pick rbfast RBFAST_BIN)
cmd=${1:-}
has() { local a; for a in "${@:2}"; do case $a in "$1"|"$1"=*) return 0;; esac; done; return 1; }
fast_ok_binary() { [ -x "$FAST" ] || command -v "$FAST" >/dev/null 2>&1; }

case $cmd in
  sweep|read)
    exec "$FAST" "$@" ;;
  model)
    if fast_ok_binary; then
      err=$(mktemp); out=$(mktemp); trap 'rm -f "$err" "$out"' EXIT
      "$FAST" "$@" >"$out" 2>"$err"; rc=$?
      if [ $rc -ne 0 ] && grep -q "a call with its own hop is not supported" "$err"; then
        exec "$GO" "$@"   # (exec drops the trap; temp files are in $TMPDIR and tiny)
      fi
      cat "$out"; cat "$err" >&2; exit $rc
    fi
    exec "$GO" "$@" ;;
  predict|infer)
    if [ "${RHOBOUND_FAST_APPROX:-}" = 1 ] && fast_ok_binary && ! has --fit "$@" && ! has --changes "$@" \
       && ! has --load-scale "$@" && ! has --report "$@"; then
      echo "rhobound-fast: RHOBOUND_FAST_APPROX=1: answered by rbfast (first-release network-time rule; model_ms within ~0.4% of the Go CLI on the AWS captures)" >&2
      exec "$FAST" "$@"
    fi
    exec "$GO" "$@" ;;
  *)
    exec "$GO" "$@" ;;
esac
