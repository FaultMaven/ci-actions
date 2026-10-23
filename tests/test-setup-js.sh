#!/bin/bash
# setup-js: check-inputs.sh against every input pair, and action.yml's wiring.
# The setup itself (pnpm and Node from a fixture package.json) runs for real in
# CI's `setup-js` job; this file needs no network.
#
# Run: tests/test-setup-js.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ACTION="$REPO_ROOT/setup-js/action.yml"
CHECK="$REPO_ROOT/setup-js/check-inputs.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          /'; }
expect() { # label, condition-text (evaluated), detail
    if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi
}
command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah v4) is required"; exit 1; }

echo "== check-inputs.sh"
check() { # pnpm, install, want rc, want output
    local out rc
    out="$(env WANT_PNPM="$1" WANT_INSTALL="$2" bash --noprofile --norc -eo pipefail "$CHECK" 2>&1)"; rc=$?
    # shellcheck disable=SC2034  # read inside expect's eval
    O="$out" R="$rc" W_RC="$3" W_OUT="$4"
    expect "pnpm=$1 install=$2: exits $3${4:+, '$4'}" '[[ "$R" == "$W_RC" && "$O" == "$W_OUT" ]]' "rc=$rc out=$out"
}
check true true 0 ""
check true false 0 ""
check false false 0 ""
check false true 1 "::error::setup-js: install: true needs pnpm: true"
check yes true 1 "::error::setup-js: pnpm must be 'true' or 'false', not 'yes'"
check true "" 1 "::error::setup-js: install must be 'true' or 'false', not ''"

echo "== action.yml"
step() { yq ".runs.steps[] | select(.name == \"$1\") | $2" "$ACTION"; }
# shellcheck disable=SC2016,SC2034  # literal GitHub expressions; read inside expect's eval
WANT_CHECK_ENV='{"WANT_PNPM":"${{ inputs.pnpm }}","WANT_INSTALL":"${{ inputs.install }}"}'
expect "the steps are check, pnpm, node, install, in that order" \
    '[[ "$(yq "[.runs.steps[].name] | join(\",\")" "$ACTION")" == "Check the inputs,Set up pnpm,Set up Node,Install dependencies" ]]' "$(yq "[.runs.steps[].name]" "$ACTION")"
expect "the check runs first, unconditionally, binding exactly both inputs" \
    '[[ "$(step "Check the inputs" "has(\"if\")")" == false && "$(yq -o=json -I0 ".runs.steps[0].env" "$ACTION")" == "$WANT_CHECK_ENV" && "$(step "Check the inputs" ".run")" == "bash --noprofile --norc -eo pipefail \"\$GITHUB_ACTION_PATH/check-inputs.sh\"" ]]' "$(yq ".runs.steps[0]" "$ACTION")"
expect "pnpm/action-setup runs only with pnpm: true, with no version (package.json's packageManager decides) and run_install: false" \
    '[[ "$(step "Set up pnpm" ".if")" == "inputs.pnpm == '"'"'true'"'"'" && "$(step "Set up pnpm" ".uses")" == pnpm/action-setup@* && "$(step "Set up pnpm" ".with | keys | join(\",\")")" == run_install && "$(step "Set up pnpm" ".with.run_install")" == false ]]' "$(step "Set up pnpm" ".")"
expect "setup-node always runs, reads node-version-file: package.json, and caches pnpm only for an install" \
    '[[ "$(step "Set up Node" "has(\"if\")")" == false && "$(step "Set up Node" ".uses")" == actions/setup-node@* && "$(step "Set up Node" ".with.node-version-file")" == package.json && "$(step "Set up Node" ".with | keys | sort | join(\",\")")" == "cache,node-version-file" && "$(step "Set up Node" ".with.cache")" == "\${{ inputs.install == '"'"'true'"'"' && '"'"'pnpm'"'"' || '"'"''"'"' }}" ]]' "$(step "Set up Node" ".")"
expect "the install is frozen and runs only with install: true" \
    '[[ "$(step "Install dependencies" ".if")" == "inputs.install == '"'"'true'"'"'" && "$(step "Install dependencies" ".run")" == "pnpm install --frozen-lockfile" ]]' "$(step "Install dependencies" ".")"
expect "every run step declares shell: bash, and every action is pinned by a 40-hex commit" \
    '[[ "$(yq "[.runs.steps[] | select(has(\"run\")) | select(.shell != \"bash\")] | length" "$ACTION")" == 0 && "$(yq "[.runs.steps[] | select(has(\"uses\")) | select(.uses | test(\"@[0-9a-f]{40}$\") | not)] | length" "$ACTION")" == 0 ]]' "$(yq ".runs.steps" "$ACTION")"
expect "both inputs default to true" \
    '[[ "$(yq ".inputs.pnpm.default" "$ACTION")" == true && "$(yq ".inputs.install.default" "$ACTION")" == true ]]' "$(yq ".inputs" "$ACTION")"

echo ""
echo "setup-js: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
