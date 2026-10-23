#!/usr/bin/env bash
# `pnpm audit` of pnpm-lock.yaml for the lockfile-audit action (faultmaven#2159).
#
# Each attempt is classified, first match wins:
#   exit 0                                      clean
#   the audit's own summary line is printed     advisories (an audit completed)
#   the endpoint is unreachable, every status   retried; after the last attempt,
#   it answered is 5xx, 408 or 429, or the      unreachable
#   attempt ran out its time limit
#   anything else                               error
# Every path sets the step output `result` and writes one job-summary block.
# ON_UNREACHABLE (`fail` or `warn`) decides whether "unreachable" fails the step.
set -uo pipefail

level=moderate
audit=(pnpm audit "--audit-level=$level")
attempts=4
attempt_seconds=90
# The transport failures seen when npm's advisory endpoint is down
# (faultmaven-website's outage handling).
transport='ERR_SOCKET_TIMEOUT|FetchError|socket timeout|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|request to .* failed'

# Whether every HTTP status pnpm reports from the audit endpoints is one worth
# retrying (5xx, 408, 429). pnpm 10 names both the quick endpoint's and the
# fallback's status, so one refusal (403) among them is not an outage.
only_retryable_statuses() {
  local statuses
  statuses=$(grep -oE 'responded with [0-9]{3}' <<<"$1" | grep -oE '[0-9]{3}$')
  [ -n "$statuses" ] && ! grep -qvE '^(5[0-9][0-9]|408|429)$' <<<"$statuses"
}

# finish <result> <exit code> <summary line>...
finish() {
  local result=$1 code=$2
  shift 2
  echo "result=$result" >>"${GITHUB_OUTPUT:-/dev/null}"
  printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit "$code"
}

case "${ON_UNREACHABLE:-}" in
  fail | warn) ;;
  *)
    echo "::error::on-unreachable must be 'fail' or 'warn', got '${ON_UNREACHABLE:-}'."
    finish error 2 "### Dependency audit: not run" "" \
      "The lockfile-audit action needs \`on-unreachable: fail\` or \`warn\`."
    ;;
esac

for i in $(seq 1 "$attempts"); do
  started=$SECONDS
  out="$(timeout --kill-after=10 "$attempt_seconds" "${audit[@]}" 2>&1)"
  code=$?
  # 124, or 137 after --kill-after, from the limit itself; not a kill from outside.
  timed_out=false
  if { [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; } && [ $((SECONDS - started)) -ge "$attempt_seconds" ]; then
    timed_out=true
  fi
  printf '%s\n' "$out"
  if [ "$code" -eq 0 ]; then
    finish clean 0 "### Dependency audit: clean" "" \
      "\`${audit[*]}\` found no advisory at or above $level outside \`pnpm.auditConfig.ignoreGhsas\`."
  fi
  # Checked before the transport patterns, so an advisory whose title names a
  # network error is never taken for an outage.
  if grep -qE '^[0-9]+ vulnerabilit(y|ies) found' <<<"$out"; then
    echo "::error::pnpm audit found advisories at or above $level."
    finish advisories 1 "### Dependency audit: advisories found" "" \
      "\`${audit[*]}\` reported advisories at or above $level; the step log lists them." \
      "Bump or override each one. One with no fixed version may go in \`pnpm.auditConfig.ignoreGhsas\` only as this repository's rule for that list allows (see the gate's comment in ci.yml), with the reason in the PR that adds it."
  fi
  if $timed_out || grep -qiE "$transport" <<<"$out" || only_retryable_statuses "$out"; then
    echo "::notice::Attempt $i/$attempts: npm's advisory endpoint is unreachable or failing (exit $code)."
    if [ "$i" -lt "$attempts" ]; then sleep $((i * 20)); fi
    continue
  fi
  echo "::error::pnpm audit failed without reporting advisories."
  finish error 1 "### Dependency audit: failed" "" \
    "\`${audit[*]}\` exited $code without reporting advisories; the step log says why."
done

did_not_run=("### Dependency audit: DID NOT RUN" ""
  "npm's advisory endpoint was unreachable or failing for all $attempts attempts, so **no audit was performed**. This is not a clean result.")
if [ "$ON_UNREACHABLE" = warn ]; then
  echo "::warning::npm's advisory endpoint was unreachable after $attempts attempts; this audit did not run."
  finish unreachable 0 "${did_not_run[@]}"
fi
echo "::error::npm's advisory endpoint was unreachable after $attempts attempts; this audit did not run."
finish unreachable 1 "${did_not_run[@]}"
