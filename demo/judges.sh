#!/usr/bin/env bash
# judges.sh: rhobound in about 10 minutes, offline. No AWS, no network after the Go module download, no credentials.
#   bash demo/judges.sh [--quick]        (from the repository's root; Go 1.25 or later, python3, git, jq; shellcheck optional)
# 1. builds bin/rhobound and bin/rhobound-mcp from this checkout
# 2. the agent's loop over MCP on the repository's sample traces (examples/mcp/demo.sh): fit, context, budget, a measured
#    A/B, a prediction that passes and one that the gate blocks
# 3. the Muse Code plugin's install, for real but in a scratch home: rhobound-mcp init (the dry run, then --write), the
#    files it writes, and the settings entry Muse reads
# 4. the AWS bed, offline: its spawn script against a fake AWS, the live demo's changes rebuilt from their patches and
#    checked against the code that was gated, and (unless --quick) the CI pipeline's and the measurement scripts' tests
#    (multi-image changes, parallel A/Bs, signing, deploy; truth brackets, staged rollouts)
# 5. the results
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
QUICK=0; [[ ${1:-} == --quick ]] && QUICK=1
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/judges
mkdir -p "$SCR"
T=$(mktemp -d "$SCR/run.XXXXXX")
step() { printf '\n== %s\n' "$*"; }
cd "$ROOT"
for c in go python3 git jq; do command -v "$c" > /dev/null || { echo "judges.sh: needs $c" >&2; exit 2; }; done

step "1-2. build, then the agent's loop over MCP (examples/mcp/demo.sh)"
bash examples/mcp/demo.sh

step "3. the Muse Code plugin, installed in a scratch home ($T/home)"
mkdir -p "$T/home/.config/muse" "$T/work"
printf '{"schema_version": 1}\n' > "$T/home/.config/muse/settings.json"
cp testdata/mcp/loop/policy.json "$T/policy.json"
init() { (cd "$T/work" && env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" \
  "$ROOT/bin/rhobound-mcp" init --engine "$ROOT/bin/rhobound" --capture "loop=$ROOT/testdata/mcp/loop" \
  --policy "default=$T/policy.json" "$@"); }
init > "$T/init-dry.json"
echo "   dry run: $(jq -c '{config_action: (.config.action // .action // null), muse_settings: (.muse_settings.action // null)}' "$T/init-dry.json" 2> /dev/null || head -c 300 "$T/init-dry.json")"
init --write > "$T/init-write.json"
echo "   --write: the server's configuration and Muse's settings entry:"
jq '.mcp_servers.rhobound // .mcpServers.rhobound' "$T/home/.config/muse/settings.json" | sed 's/^/     /'
init > "$T/init-check.json"
echo "   the check after it: muse_settings $(jq -r '.muse_settings.action // "?"' "$T/init-check.json") (keep = installed as written)"
echo "   in Muse Code itself (not run here): muse plugins install ./integrations/muse-code; muse plugins approve rhobound;"
echo "   then the init above with --write against your real home (integrations/muse-code/README.md)"

step "4a. the bed's spawn script against a fake AWS (bed/aws/tests/run_tests.sh)"
RBD_SCRATCH=$T bash bed/aws/tests/run_tests.sh | tail -n 1
step "4b. the live demo's changes, rebuilt from changes/demo/*.patch and checked against the gated code (demo_live.sh --dry)"
RBD_SCRATCH=$T bash bed/orch/demo_live.sh --dry pass block single edge | grep -E 'matches|done'
if (( ! QUICK )); then
  step "4c. the CI pipeline's tests (bed/tools1/tests/ci): pr-check, multi-image builds, parallel A/Bs, predict, sign, deploy"
  RBD_SCRATCH=$T bash bed/tools1/tests/ci/run_tests.sh | grep -E ' -- |ALL PASSED|FAILURES' | tail -n 12
  step "4d. the measurement scripts' tests (bed/verify): truth brackets, multi-image brackets, staged rollouts"
  RBD_SCRATCH=$T bash bed/verify/tests/truthx/run.sh | grep -E 'passed|PASSED|FAIL' | tail -n 6
fi

step "5. the results (docs/RESULTS.md; every number measured on AWS, predictions sealed before production)"
sed -n '/^| what the gate said/,/^$/p' docs/RESULTS.md
sed -n '/^## What the time saving is/,/^- \*\*Longer/p' docs/RESULTS.md | sed '$d'
echo
echo "judges.sh: done (scratch $T). Next: JUDGES.md, tier 2 (the gate live on AWS) and tier 3 (the agent experiments)."
