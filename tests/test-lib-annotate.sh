#!/bin/bash
# Tests lib/annotate.sh, the annotation helpers update-image-queue and
# move-branch-tags share (#8), and that they share it: each script sources it,
# and neither defines a helper of its own.
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

# shellcheck source=../lib/annotate.sh
source "$LIB"

echo "== escape(): GitHub's escaping for a command's message"
for row in \
    "plain|main is at abc|main is at abc" \
    "percent|50% done|50%25 done" \
    "an escape already|x%0Ay|x%250Ay" \
    "CR|a"$'\r'"b|a%0Db" \
    "a tab stays|a"$'\t'"b|a"$'\t'"b"; do
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
# shellcheck disable=SC2034  # read inside expect's eval
got="$(annotate warning $'a\n::error::b %')"
expect "annotate: one line, ::warning::, escaped" '[[ "$got" == "::warning::a%0A::error::b %25" && $(wc -l <<< "$got") == 1 ]]' "got: $got"

echo "== first_err(): the first non-blank line of \$ERR, without gh's prefix"
ERR="$WORK/err"
printf '\n  \ngh: Not Found (HTTP 404)   \nhint: a later line\n' > "$ERR"
# shellcheck disable=SC2034  # read inside expect's eval
got="$(first_err)"
expect "first_err: skips blanks, drops 'gh: ' and trailing blanks, stops at the first line" '[[ "$got" == "Not Found (HTTP 404)" ]]' "got: $got"

echo "== one copy: each script sources the library and defines no helper of its own"
for script in update-image-queue/update.sh move-branch-tags/move.sh; do
    f="$REPO_ROOT/$script"
    # shellcheck disable=SC2016,SC2034  # the literal source line, read inside expect's eval
    want='source "$(dirname "${BASH_SOURCE[0]}")/../lib/annotate.sh"'
    expect "$script sources lib/annotate.sh" 'grep -qxF -- "$want" "$f"' "$(grep -n 'source' "$f")"
    expect "$script defines no escape(), annotate() or first_err()" \
        '! grep -qE "^(escape|annotate|first_err)\(\) *\{" "$f"' "$(grep -nE '^(escape|annotate|first_err)\(\)' "$f")"
done

echo
echo "lib-annotate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
