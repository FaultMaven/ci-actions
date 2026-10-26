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
#   429/502, 408     retryable statuses, as pnpm 10 and 9 print them -> retried
#   real transports  ECONNRESET, ERR_SOCKET_TIMEOUT, ECONNREFUSED -> retried
#   124 at once      a kill from outside the limit         -> error, not retried
#   limit ran out    a 1 s copy whose stub waits out the limit (124, 137) -> retried
#   coloured         the summary in terminal colour (FORCE_COLOR) -> advisories
# The stub `timeout` logs its arguments (the 90 s limit and --kill-after are
# asserted), and can exit 124 or 137 at once or after waiting out the limit.
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
printf '%s\n' "$*" >> "$SC/timeouts"
[ -n "${TO_NOW:-}" ] && exit "$TO_NOW"
while [[ ${1:-} == --* ]]; do shift; done
if [ -n "${TO_CODE:-}" ]; then /bin/sleep "$1"; exit "$TO_CODE"; fi
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
        TO_CODE="${TO_CODE:-}" TO_NOW="${TO_NOW:-}" ${ROW_LC_ALL:+LC_ALL="$ROW_LC_ALL"} \
        bash "${RUN_SCRIPT:-$SCRIPT}" 2>&1)"; RC=$?
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
NET=' ETIMEDOUT  request to https://registry.npmjs.org/-/npm/v1/security/audits/quick failed, reason: connect ETIMEDOUT 104.16.0.35:443'

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
1 vulnerabilities found"
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
row only5xx fail "1| ERR_PNPM_AUDIT_BAD_RESPONSE  The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits) responded with 503: Service Unavailable"
outcome "5xx only" 1 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"

echo "== a 503 and a 403 in one attempt: not an outage"
row mixed fail "1| ERR_PNPM_AUDIT_BAD_RESPONSE  The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits/quick) responded with 503: Service Unavailable. Fallback endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits) responded with 403: Forbidden"
outcome "5xx and 403" 1 error 1 "" "### Dependency audit: failed"

echo "== any other failure"
row other fail "1|ERR_PNPM_LOCKFILE_BREAKING_CHANGE  Lockfile /x/pnpm-lock.yaml not compatible"
outcome "other failure" 1 error 1 "" "### Dependency audit: failed"
expect "other failure: ::error:: says it failed without advisories" \
    'grep -qxF "::error::pnpm audit failed without reporting advisories." <<< "$OUT"' "$(ctx)"

# The coloured rows run under en_US.UTF-8, where sed's byte ranges are
# collation ranges: audit.sh's LC_ALL=C is what makes the stripping work
# there, and the runner's default C.UTF-8 would hide its removal.
UTF8_LOCALE="$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -1)"
[ -n "$UTF8_LOCALE" ] || { echo "the en_US.UTF-8 locale is required for the coloured rows (locale -a lists none)"; exit 1; }
echo "== a coloured summary (FORCE_COLOR): still advisories"
ROW_LC_ALL="$UTF8_LOCALE" row colour fail "1|$(printf '\e[31m1\e[39m vulnerabilities found')"
outcome "coloured summary" 1 advisories 1 "" "### Dependency audit: advisories found"
echo "== a coloured summary whose advisory names a network error, under warn: still advisories, never retried"
ROW_LC_ALL="$UTF8_LOCALE" row colourwarn warn "1|lib: ECONNRESET on retry (GHSA-yyyy)
$(printf '\e[31m1\e[39m vulnerabilities found')"
outcome "coloured advisory+network, warn" 1 advisories 1 "" "### Dependency audit: advisories found"

echo "== on-unreachable is neither fail nor warn"
row badinput maybe "0|No known vulnerabilities found"
outcome "bad input" 2 error 0 "" "### Dependency audit: not run"
# The input is escaped as GitHub decodes an annotation (#8).
row badescape $'a%0Ab\n::warning::c' "0|No known vulnerabilities found"
# shellcheck disable=SC2034  # read inside expect's eval
WANT_BAD="::error::on-unreachable must be 'fail' or 'warn', got 'a%250Ab%0A::warning::c'."
expect "bad input with % and a line break: one annotation, escaped" \
    '[[ "$(grep -c "^::" <<< "$OUT")" == 1 ]] && grep -qxF -- "$WANT_BAD" <<< "$OUT"' "$OUT"

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

expect "clean: one 90 s limit with --kill-after=10" '[[ "$(cat "$WORK/clean/timeouts")" == "--kill-after=10 90 pnpm audit --audit-level=moderate" ]]' "$(cat "$WORK/clean/timeouts")"
echo "== 429 and 502 (pnpm 10): retried"
row r429 fail "1| ERR_PNPM_AUDIT_BAD_RESPONSE  The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits/quick) responded with 429: x. Fallback endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits) responded with 502: y"
outcome "429+502" 1 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"
row r408 fail "1| ERR_PNPM_AUDIT_BAD_RESPONSE  The audit endpoint (at https://registry.npmjs.org/-/npm/v1/security/audits) responded with 408: x"
outcome "408" 1 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"
k=0; for e in "ECONNRESET  request to https://registry.npmjs.org/-/npm/v1/security/audits/quick failed, reason: read ECONNRESET" "ERR_SOCKET_TIMEOUT  request to https://registry.npmjs.org/-/npm/v1/security/audits/quick failed, reason: Socket timeout" "ECONNREFUSED  request to https://registry.npmjs.org/-/npm/v1/security/audits failed, reason: connect ECONNREFUSED 1.2.3.4:443"; do
  row "net$((++k))" fail "1| $e"; outcome "real transport error ${e%% *}" 1 unreachable 4 "20 40 60 " "### Dependency audit: DID NOT RUN"; done
echo "== 124 from outside the limit: not an outage"
TO_NOW=124 row to_now fail "0|x"; outcome "124 at once" 1 error 0 "" "### Dependency audit: failed"
# The copy sits in the repository's layout, so its ../lib/annotate.sh is found.
mkdir -p "$WORK/lockfile-audit" "$WORK/lib" && cp "$REPO_ROOT/lib/annotate.sh" "$WORK/lib/"
sed 's/^attempt_seconds=[0-9]*$/attempt_seconds=1/' "$SCRIPT" > "$WORK/lockfile-audit/fast.sh"
# Fail, not hang: an unrewritten copy would wait out the real limit.
grep -qx 'attempt_seconds=1' "$WORK/lockfile-audit/fast.sh" || { echo "the fast copy's attempt_seconds was not rewritten"; exit 1; }
for c in 124 137; do RUN_SCRIPT="$WORK/lockfile-audit/fast.sh" TO_CODE=$c row "limit$c" fail "0|x"; outcome "limit ran out ($c)" 1 unreachable 0 "20 40 60 " "### Dependency audit: DID NOT RUN"; done
echo ""
echo "lockfile-audit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
