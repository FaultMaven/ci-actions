#!/bin/bash
# Tests lib/annotate.sh, the output helpers every action's script shares
# (#8), and that they share it: each script sources it, defines none of the
# helpers itself, and says so when the library cannot be loaded.
#
# Run: tests/test-lib-annotate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LIB="$REPO_ROOT/lib/annotate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          /'; }
expect() { # label, condition-text (evaluated), detail
    if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi
}

# shellcheck source=SCRIPTDIR/../lib/annotate.sh
source "$LIB"

echo "== escape(): GitHub's escaping for a command's message"
for row in \
    "plain|main is at abc|main is at abc" \
    "percent|50% done|50%25 done" \
    "an escape already|x%0Ay|x%250Ay" \
    "CR|a"$'\r'"b|a%0Db" \
    "a tab stays|a"$'\t'"b|a"$'\t'"b"; do
    # shellcheck disable=SC2034  # want is read inside expect's eval
    IFS='|' read -r label in want <<< "$row"
    # shellcheck disable=SC2034  # read inside expect's eval
    got="$(escape "$in")"
    expect "escape: $label" '[[ "$got" == "$want" ]]' "got: $got"
done
# A LF inside a here-string row would split the read, so LF is checked apart.
# shellcheck disable=SC2034  # read inside expect's eval
got="$(escape $'a\nb')"
expect "escape: LF" '[[ "$got" == "a%0Ab" ]]' "got: $got"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(escape $'a\r\nb')"
expect "escape: CR LF" '[[ "$got" == "a%0D%0Ab" ]]' "got: $got"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(escape $'one\ntwo\n::error::three')"
expect "escape: an injected line cannot start a command" '[[ "$got" == "one%0Atwo%0A::error::three" ]]' "got: $got"

echo "== annotate(): one line, the level, the escaped message"
# $(...) strips only trailing newlines, so an exact match is one line.
# shellcheck disable=SC2034  # read inside expect's eval
got="$(annotate warning $'a\n::error::b %')"
expect "annotate: ::warning:: and the escaped message, on one line" '[[ "$got" == "::warning::a%0A::error::b %25" ]]' "got: $got"

echo "== flat(): one line for plain text, shown as written"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(flat $'a\r\nb\tc 50%')"
expect "flat: CR, LF and tab become spaces; % stays" '[[ "$got" == "a  b c 50%" ]]' "got: $got"

echo "== first_err() and last_err(): a file of a tool's stderr"
printf '\n  \ngh: Not Found (HTTP 404)   \nhint: a later line\n' > "$WORK/e1"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(first_err "$WORK/e1")"
expect "first_err: skips blank lines, drops 'gh: ' and trailing blanks, stops at the first line" '[[ "$got" == "Not Found (HTTP 404)" ]]' "got: $got"
printf ' \r\ngh: Not Found (HTTP 404)\r\n' > "$WORK/e2"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(first_err "$WORK/e2")"
expect "first_err: a CRLF line of spaces is blank, and the CR is cut from the error" '[[ "$got" == "Not Found (HTTP 404)" ]]' "got: [$got]"
printf '#1 copying\nERROR: push refused   \r\n \r\n' > "$WORK/e3"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(last_err "$WORK/e3")"
expect "last_err: the last non-blank line, a trailing CRLF line of spaces skipped" '[[ "$got" == "ERROR: push refused" ]]' "got: [$got]"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(first_err /dev/null < <(echo stdin-line))"
expect "first_err: reads only the file it is given, never stdin" '[[ -z "$got" ]]' "got: [$got]"

echo "== log_tool_output(): no line of a tool's output can start a command"
printf 'progress\n::error::from a server\n  ::warning::indented\n\n' > "$WORK/e4"
log_tool_output imagetools "$WORK/e4" 2> "$WORK/log"
expect "every line is prefixed by the tool's name, so none begins :: after its leading blanks are trimmed" \
    '[[ "$(cat "$WORK/log")" == "imagetools: progress"$'"'"'\n'"'"'"imagetools: ::error::from a server"$'"'"'\n'"'"'"imagetools:   ::warning::indented"$'"'"'\n'"'"'"imagetools: " ]] && ! sed "s/^[[:space:]]*//" "$WORK/log" | grep -q "^::"' "$(cat "$WORK/log")"

echo "== one copy: each script sources the library and defines none of its helpers"
DEF='^[[:space:]]*(function[[:space:]]+)?(escape|annotate|flat|first_err|last_err|log_tool_output)[[:space:]]*(\([[:space:]]*\))?[[:space:]]*\{'
# shellcheck disable=SC2016,SC2034  # the literal source line, read inside expect's eval
WANT_SOURCE='source "$(dirname "${BASH_SOURCE[0]}")/../lib/annotate.sh" || {'
for script in update-image-queue/update.sh move-branch-tags/move.sh setup-js/check-inputs.sh lockfile-audit/audit.sh; do
    f="$REPO_ROOT/$script"
    expect "$script sources lib/annotate.sh, guarded" 'grep -qxF -- "$WANT_SOURCE" "$f"' "$(grep -n 'source' "$f")"
    expect "$script defines none of the helpers (any spelling: name(), name (), function name, indented)" \
        '! grep -qE "$DEF" "$f"' "$(grep -nE "$DEF" "$f")"
done
# The guard's own check must catch each spelling, or it proves nothing.
for spelling in 'annotate() {' 'annotate () {' 'function annotate {' 'function annotate() {' '  flat() {'; do
    # shellcheck disable=SC2034  # read inside expect's eval
    line="$spelling"
    expect "the one-copy check catches '$spelling'" 'grep -qE "$DEF" <<< "$line"' ""
done

echo "== a script whose library cannot be loaded still says so"
SHA=1111111111111111111111111111111111111111
for state in missing broken; do
    root="$WORK/$state"
    mkdir -p "$root/move-branch-tags" "$root/update-image-queue"
    cp "$REPO_ROOT/move-branch-tags/move.sh" "$root/move-branch-tags/"
    cp "$REPO_ROOT/update-image-queue/update.sh" "$root/update-image-queue/"
    if [ "$state" = broken ]; then
        mkdir -p "$root/lib" && printf 'escape() {\n  printf "%%s" "unterminated\n' > "$root/lib/annotate.sh"
    fi
    : > "$WORK/out"
    env -i PATH=/usr/bin:/bin GITHUB_OUTPUT="$WORK/out" IMAGE=ghcr.io/faultmaven/svc \
        DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa RUN_SHA="$SHA" \
        TAG_REF=refs/heads/main REPO=FaultMaven/svc GH_TOKEN=stub \
        bash --noprofile --norc -eo pipefail "$root/move-branch-tags/move.sh" > "$WORK/stdout" 2>/dev/null
    rc=$?
    # shellcheck disable=SC2034  # read inside expect's eval
    {
        ann="$(grep '^::' "$WORK/stdout")"
        outs="$(paste -sd' ' "$WORK/out")"
    }
    expect "move.sh, library $state: rc 0, a warning, moved=false reason=stopped written" \
        '[[ $rc == 0 && $ann == "::warning::move-branch-tags cannot load ../lib/annotate.sh: latest and the branch tag were not moved" && $outs == "moved=false reason=stopped" ]]' "rc=$rc ann=$ann outs=$outs"
    env -i PATH=/usr/bin:/bin SERVICE_NAME=svc-a RUN_SHA="$SHA" REPO=FaultMaven/svc-a \
        bash --noprofile --norc -eo pipefail "$root/update-image-queue/update.sh" > "$WORK/stdout" 2>/dev/null
    rc=$?
    # shellcheck disable=SC2034  # read inside expect's eval
    ann="$(grep '^::' "$WORK/stdout")"
    expect "update.sh, library $state: rc 1, an error that says what GHCR holds" \
        '[[ $rc == 1 && $ann == "::error::update-image-queue cannot load ../lib/annotate.sh. GHCR holds sha-1111111 but the queue does not name it." ]]' "rc=$rc ann=$ann"
done

echo
echo "lib-annotate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
