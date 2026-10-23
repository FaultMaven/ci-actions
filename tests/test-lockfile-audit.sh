#!/bin/bash
# Drives lockfile-audit/audit.sh the way action.yml runs it, against a stub
# `pnpm` whose attempts are scripted per row.
#
# Each row sets what every `pnpm audit` attempt prints and exits, then checks
# the script's exit code, its `result` output, its job-summary heading, its
# annotation, how many attempts ran and the backoff between them:
#   clean            exit 0                                -> clean, 0
#   advisories       "3 vulnerabilities found", exit 1     -> advisories, 1
#   advisory+network an advisory whose text names ETIMEDOUT -> advisories, not a retry
#   down, fail       a transport error on every attempt    -> 4 attempts (20 40 60), unreachable, 1
#   down, warn       the same with on-unreachable: warn    -> unreachable, 0, a warning
#   blip             one transport error, then clean       -> clean after 2 attempts
#   5xx only         "responded with 503" on every attempt -> retried, unreachable
#   5xx and 403      a 503 and a 403 in one attempt        -> error at once, not retried
#   other failure    exit 1 with no advisory line          -> error, 1
#   bad input        on-unreachable: maybe                 -> error, 2, no attempt
# The attempt time limit (a 90-second `timeout`) is not driven: the stub
# `timeout` runs the command directly.
#
# SAFETY: nothing here reaches npm. `pnpm`, `timeout` and `sleep` are stubs,
# and the run refuses to start unless `command -v` resolves them to the stubs.
#
# Run: tests/test-lockfile-audit.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ACTION="$REPO_ROOT/lockfile-audit/action.yml"
SCRIPT="$REPO_ROOT/lockfile-audit/audit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          /'; }
# The condition is text, evaluated here, so each assertion reads as one line;
# the single quotes at each call site are deliberate (SC2016).
expect() { # label, condition-text (evaluated), detail
    if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi
}
command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah v4) is required"; exit 1; }

# ------------------------------------------------------------------ stubs
BIN="$WORK/bin"; mkdir -p "$BIN"
# pnpm: attempt N prints $SC/out.N and exits $SC/code.N; past the last
# scripted attempt it repeats the last one. Every call is logged.
cat > "$BIN/pnpm" <<'PNPM'
#!/bin/bash
printf '%s\n' "$*" >> "$SC/calls"
n=$(grep -c . "$SC/calls")
last=$(find "$SC" -maxdepth 1 -name 'code.*' | sed 's/.*code\.//' | sort -n | tail -1)
[ "$n" -gt "$last" ] && n=$last
cat "$SC/out.$n"
exit "$(cat "$SC/code.$n")"
PNPM
# timeout: drops its options and its duration, then runs the command.
cat > "$BIN/timeout" <<'TIMEOUT'
#!/bin/bash
while [[ ${1:-} == --* ]]; do shift; done
shift
exec "$@"
TIMEOUT
cat > "$BIN/sleep" <<'SLEEP'
#!/bin/sh
printf '%s\n' "$*" >> "$SC/sleeps"
SLEEP
chmod +x "$BIN/pnpm" "$BIN/timeout" "$BIN/sleep"
export PATH="$BIN:$PATH"
for c in pnpm timeout sleep; do
    if [ "$(command -v "$c")" != "$BIN/$c" ]; then
        echo "REFUSING TO RUN: '$c' resolves to '$(command -v "$c")', not the stub $BIN/$c"
        exit 1
    fi
done

# row <name> <on-unreachable> then attempt specs "code|output"...
# Sets OUT, RC, RESULT, SUM, CALLS, SLEEPS.
row() {
    local name="$1" on="$2" i=0 spec
    shift 2
    SC="$WORK/$name"; mkdir -p "$SC"; : > "$SC/calls"; : > "$SC/sleeps"
    for spec in "$@"; do
        i=$((i + 1))
        printf '%s' "${spec%%|*}" > "$SC/code.$i"
        printf '%s\n' "${spec#*|}" > "$SC/out.$i"
    done
    : > "$SC/output"; : > "$SC/summary"
    OUT="$(env SC="$SC" ON_UNREACHABLE="$on" npm_config_fetch_retries=0 \
        GITHUB_OUTPUT="$SC/output" GITHUB_STEP_SUMMARY="$SC/summary" \
        bash "$SCRIPT" 2>&1)"; RC=$?
    RESULT="$(sed -n 's/^result=//p' "$SC/output")"
    SUM="$(cat "$SC/summary")"
    CALLS="$(grep -c . "$SC/calls")"
    SLEEPS="$(tr '\n' ' ' < "$SC/sleeps")"
}
ctx() { printf 'rc=%s result=%s calls=%s sleeps=[%s]\nout:\n%s\nsummary:\n%s' "$RC" "$RESULT" "$CALLS" "$SLEEPS" "$OUT" "$SUM"; }
outcome() { # label, rc, result, calls, sleeps, summary heading
    # shellcheck disable=SC2034  # read inside expect's eval
    W_RC="$2" W_RESULT="$3" W_CALLS="$4" W_SLEEPS="$5" W_HEAD="$6"
    expect "$1: exits $2, result=$3, $4 attempt(s), sleeps [$5], summary '$6'" \
        '[[ "$RC" == "$W_RC" && "$RESULT" == "$W_RESULT" && "$CALLS" == "$W_CALLS" && "$SLEEPS" == "$W_SLEEPS" && "$SUM" == "$W_HEAD"* ]]' "$(ctx)"
}
NET='ERR_PNPM_AUDIT_BAD_RESPONSE  request to https://registry.npmjs.org/-/npm/v1/security/audits/quick failed, reason: ETIMEDOUT'

echo "== clean"
row clean fail "0|No known vulnerabilities found"
outcome "clean" 0 clean 1 "" "### Dependency audit: clean"
expect "clean: the audit ran with --audit-level=moderate" '[[ "$(cat "$SC/calls")" == "audit --audit-level=moderate" ]]' "$(cat "$SC/calls")"

echo "== advisories"
row advisories fail "1|3 vulnerabilities found
Severity: 2 moderate | 1 high"
outcome "advisories" 1 advisories 1 "" "### Dependency audit: advisories found"
expect "advisories: ::error:: names the level" 'grep -qxF "::error::pnpm audit found advisories at or above moderate." <<< "$OUT"' "$(ctx)"

echo "== an advisory whose text names a network error"
row advnet fail "1|lib: ETIMEDOUT handling (GHSA-xxxx)
1 vulnerability found"
outcome "advisory+network" 1 advisories 1 "" "### Dependency audit: advisories found"

echo "== the endpoint is down on every attempt, on-unreachable: fail"
row downfail fail "1|$NET"
outcome "down, fail" 1 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"
expect "down, fail: a notice per attempt, then ::error:: that the audit did not run" \
    '[[ "$(grep -c "^::notice::Attempt" <<< "$OUT")" == 4 ]] && grep -qxF "::error::npm'"'"'s advisory endpoint was unreachable after 4 attempts; this audit did not run." <<< "$OUT"' "$(ctx)"

echo "== the same, on-unreachable: warn"
row downwarn warn "1|$NET"
outcome "down, warn" 0 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"
expect "down, warn: a ::warning::, no ::error::" \
    'grep -q "^::warning::" <<< "$OUT" && ! grep -q "^::error::" <<< "$OUT"' "$(ctx)"

echo "== one transport error, then clean"
row blip fail "1|$NET" "0|No known vulnerabilities found"
outcome "blip" 0 clean 2 "20 " "### Dependency audit: clean"

echo "== only 5xx statuses: retried"
row only5xx fail "1|ERR_PNPM_AUDIT_BAD_RESPONSE  The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits/quick) responded with 503: Service Unavailable"
outcome "5xx only" 1 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"

echo "== a 503 and a 403 in one attempt: not an outage"
row mixed fail "1|The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits/quick) responded with 503: Service Unavailable
The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits) responded with 403: Forbidden"
outcome "5xx and 403" 1 error 1 "" "### Dependency audit: failed"

echo "== any other failure"
row other fail "1|ERR_PNPM_LOCKFILE_BREAKING_CHANGE  Lockfile /x/pnpm-lock.yaml not compatible"
outcome "other failure" 1 error 1 "" "### Dependency audit: failed"
expect "other failure: ::error:: says it failed without advisories" \
    'grep -qxF "::error::pnpm audit failed without reporting advisories." <<< "$OUT"' "$(ctx)"

echo "== on-unreachable is neither fail nor warn"
row badinput maybe "0|No known vulnerabilities found"
outcome "bad input" 2 error 0 "" "### Dependency audit: not run"

# ------------------------------------------------------------------ action.yml's wiring
echo "== action.yml runs what this harness runs"
st='.runs.steps[0]'
expect "the action has one step, id audit, shell bash" \
    '[[ "$(yq ".runs.steps | length" "$ACTION")" == 1 && "$(yq "$st.id" "$ACTION")" == audit && "$(yq "$st.shell" "$ACTION")" == bash ]]' "$(yq ".runs" "$ACTION")"
# shellcheck disable=SC2016,SC2034  # the literal command line, as action.yml spells it; read inside expect's eval
WANT_RUN='bash "$GITHUB_ACTION_PATH/audit.sh"'
expect "its command line is the one this harness runs" \
    '[[ "$(yq "$st.run" "$ACTION")" == "$WANT_RUN" ]]' "$(yq "$st.run" "$ACTION")"
# shellcheck disable=SC2016,SC2034  # literal GitHub expressions; read inside expect's eval
WANT_ENV='{"ON_UNREACHABLE":"${{ inputs.on-unreachable }}","npm_config_fetch_retries":"0"}'
expect "it binds exactly this env map (the input, and npm's own retries off: audit.sh owns them)" \
    '[[ "$(yq -o=json -I0 "$st.env" "$ACTION")" == "$WANT_ENV" ]]' "$(yq -o=json -I0 "$st.env" "$ACTION")"
# shellcheck disable=SC2016,SC2034  # a literal GitHub expression; read inside expect's eval
WANT_OUT='${{ steps.audit.outputs.result }}'
expect "the result output is the step's" '[[ "$(yq ".outputs.result.value" "$ACTION")" == "$WANT_OUT" ]]' "$(yq ".outputs" "$ACTION")"

echo ""
echo "lockfile-audit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
