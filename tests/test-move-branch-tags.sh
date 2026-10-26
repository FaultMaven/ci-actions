#!/bin/bash
# Drives move-branch-tags/move.sh the way action.yml runs it.
#
# WHAT IS DRIVEN, each row a fresh run of the script:
#   | #     | ref / tip / inputs                       | expect                                      |
#   | m1    | main, tip = sha                          | moves :main and :latest to the digest       |
#   | m2    | main, tip moved on                       | ::notice:: naming both, nothing moved       |
#   | m3    | refs/heads/feat/x, tip = sha             | moves :feat-x only, never :latest           |
#   | m4-m6 | a tag, a pull request ref, no ref        | ::notice::, no lookup, nothing moved        |
#   | m7-m9 | the tip lookup 404s, 403s, cannot connect| ::warning:: naming gh's line, nothing moved |
#   | m10   | imagetools fails                         | ::warning:: naming its last line            |
#   | m11   | the image named with an upper-case owner | the moved references are lower-case         |
#   | v1-v9 | invalid sha, digest, image, repository   | ::error::, no lookup, nothing moved         |
#   | b1-b2 | branch names                             | odd ones refused, slashes become -          |
#   | s1-s3 | an injected tip, no GITHUB_OUTPUT, a     | one annotation line; rc 0 every time        |
#   |       | failing mktemp                           |                                             |
# Every row exits 0: the action never fails the step. Then action.yml's own
# wiring: the command line, the env names this harness binds, the inputs'
# defaults and the output.
#
# The script runs as `bash --noprofile --norc -eo pipefail move.sh`, the form
# GitHub gives a `run:` step and the command action.yml runs, so `-e` is on
# from its first line. The wiring check holds the two command lines equal.
#
# SAFETY: nothing here reaches GitHub or a registry. `gh` is a stub that
# answers only `gh api repos/<repo>/git/ref/heads/<branch> --jq .object.sha`
# from a table of tips; GH_MODE gives GitHub's 404, a 403 for a token without
# `contents: read`, a transport failure, or a tip with an injected line.
# `docker` is a stub that records its arguments; DOCKER_FAIL makes it fail the
# way a refused push does. Each run gets only the stubs and /usr/bin:/bin on
# PATH, and the run refuses to start unless they resolve gh and docker to the
# stubs.
#
# Run: tests/test-move-branch-tags.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ACTION_DIR="$REPO_ROOT/move-branch-tags"
ACTION="$ACTION_DIR/action.yml"
SCRIPT="$ACTION_DIR/move.sh"
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
[[ "$(yq --version 2>&1)" == *mikefarah* ]] || { echo "yq must be mikefarah yq v4: $(yq --version 2>&1)"; exit 1; }

# ------------------------------------------------------------------ stubs
BIN="$WORK/bin"; mkdir -p "$BIN"
GH_LOG="$WORK/gh.log"; DOCKER_LOG="$WORK/docker.log"; TIPS="$WORK/tips"
cat > "$BIN/gh" <<'GHSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$#" -eq 4 ] && [ "$1" = api ] && [ "$3" = --jq ] && [ "$4" = .object.sha ] \
    || { echo "stub gh: only 'gh api repos/<repo>/git/ref/heads/<branch> --jq .object.sha' is stubbed: $*" >&2; exit 2; }
case "$2" in
    "repos/$WANT_REPO/git/ref/heads/"?*) ;;
    *) echo "stub gh: unexpected path: $2" >&2; exit 2 ;;
esac
branch="${2#"repos/$WANT_REPO/git/ref/heads/"}"
case "${GH_MODE:-}" in
    notfound)
        printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/git/refs#get-a-reference","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
    permission)
        printf '%s' '{"message":"Resource not accessible by integration","status":"403"}'
        echo "gh: Resource not accessible by integration (HTTP 403)" >&2
        exit 1 ;;
    transport)
        printf '%s\n' "error connecting to api.github.com" "check your internet connection or https://githubstatus.com" >&2
        exit 1 ;;
    inject)
        printf '%s\n%s\n' "0000000" "::error::injected"
        exit 0 ;;
esac
tip="$(awk -v b="$branch" '$1 == b { print $2; exit }' "$TIPS")"
if [ -z "$tip" ]; then
    printf '%s' '{"message":"Not Found","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
fi
printf '%s\n' "$tip"
GHSTUB
cat > "$BIN/docker" <<'DOCKERSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[ "${1:-}" = buildx ] && [ "${2:-}" = imagetools ] && [ "${3:-}" = create ] \
    || { echo "stub docker: only 'docker buildx imagetools create' is stubbed: $*" >&2; exit 2; }
echo "#1 copying sha256:0000 from ghcr.io/x/y" >&2
if [ -n "${DOCKER_FAIL:-}" ]; then
    echo "ERROR: failed to push ghcr.io/faultmaven/svc:main: unexpected status from PUT request: 403 Forbidden" >&2
    exit 1
fi
echo "#1 done" >&2
DOCKERSTUB
chmod +x "$BIN/gh" "$BIN/docker"
for c in gh docker; do
    if [ "$(PATH="$BIN:/usr/bin:/bin" command -v "$c")" != "$BIN/$c" ]; then
        echo "REFUSING TO RUN: '$c' resolves to '$(PATH="$BIN:/usr/bin:/bin" command -v "$c")', not the stub $BIN/$c"
        exit 1
    fi
done
echo "gh and docker resolve to the stubs in $BIN"

WANT_REPO=FaultMaven/svc
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
IMG=ghcr.io/faultmaven/svc

# Runs the script as action.yml does. Arguments: TAG_REF, RUN_SHA, DIGEST,
# IMAGE, REPO, then KEY=VALUE extras for the run's environment. Sets RC, OUT
# (stdout), ERRS (stderr), MOVED (the output written), GHN and DKN (calls),
# DK (docker's arguments), ANN (the :: lines).
run() {
    local ref="$1" sha="$2" digest="$3" image="$4" repo="$5"; shift 5
    : > "$GH_LOG"; : > "$DOCKER_LOG"; : > "$WORK/out"
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" GH_LOG="$GH_LOG" DOCKER_LOG="$DOCKER_LOG" TIPS="$TIPS" \
        WANT_REPO="$WANT_REPO" GITHUB_OUTPUT="$WORK/out" \
        IMAGE="$image" DIGEST="$digest" RUN_SHA="$sha" TAG_REF="$ref" REPO="$repo" GH_TOKEN=stub-token-not-a-credential \
        "$@" bash --noprofile --norc -eo pipefail "$SCRIPT" > "$WORK/stdout" 2> "$WORK/stderr"
    RC=$?
    # shellcheck disable=SC2034  # each is read inside expect's eval
    {
        OUT="$(cat "$WORK/stdout")"
        ERRS="$(cat "$WORK/stderr")"
        MOVED="$(sed -n 's/^moved=//p' "$WORK/out")"
        GHN="$(wc -l < "$GH_LOG" | tr -d ' ')"
        DKN="$(wc -l < "$DOCKER_LOG" | tr -d ' ')"
    }
    DK="$(cat "$DOCKER_LOG")"
    ANN="$(grep -E '^::' "$WORK/stdout")"
}
tips() { printf '%s\n' "$@" > "$TIPS"; }
DETAIL='printf "rc=%s moved=%s gh=%s docker=%s\nstdout: %s\nstderr: %s\ndocker: %s" "$RC" "$MOVED" "$GHN" "$DKN" "$OUT" "$ERRS" "$DK"'

# ============================================================ the rule
echo "== main at this commit moves both tags"
tips "main $SHA"
run refs/heads/main "$SHA" "$DIGEST" "$IMG" "$WANT_REPO"
expect "m1: rc 0, moved=true, one lookup, no annotation" \
    '[[ $RC == 0 && $MOVED == true && $GHN == 1 && -z $ANN ]]' "$(eval "$DETAIL")"
expect "m1: the lookup reads this repository's main" \
    '[[ "$(cat "$GH_LOG")" == "api repos/FaultMaven/svc/git/ref/heads/main --jq .object.sha" ]]' "$(cat "$GH_LOG")"
expect "m1: imagetools points :main and :latest at the digest, keeping a single manifest's digest" \
    '[[ $DK == "buildx imagetools create --prefer-index=false --tag $IMG:main --tag $IMG:latest $IMG@$DIGEST" ]]' "$DK"
expect "m1: says what it moved, and passes imagetools' progress through" \
    '[[ $OUT == "Moved $IMG:main and $IMG:latest to $DIGEST: $SHA is main'"'"'s tip." && $ERRS == *"#1 done"* ]]' "$(eval "$DETAIL")"

echo "== main moved on: nothing moves"
tips "main $OTHER"
run refs/heads/main "$SHA" "$DIGEST" "$IMG" "$WANT_REPO"
expect "m2: rc 0, moved=false, no imagetools" '[[ $RC == 0 && $MOVED == false && $DKN == 0 ]]' "$(eval "$DETAIL")"
expect "m2: a notice names the tip and this commit" \
    '[[ $ANN == "::notice::main is at $OTHER, not $SHA: latest and the branch tag were not moved" ]]' "$ANN"

echo "== another branch at this commit: its tag only"
tips "feat/x $SHA" "main $SHA"
run refs/heads/feat/x "$SHA" "$DIGEST" "$IMG" "$WANT_REPO"
expect "m3: moves :feat-x, never :latest" \
    '[[ $RC == 0 && $MOVED == true && $DK == "buildx imagetools create --prefer-index=false --tag $IMG:feat-x $IMG@$DIGEST" ]]' "$(eval "$DETAIL")"
expect "m3: reads feat/x's tip, not main's" \
    '[[ "$(cat "$GH_LOG")" == "api repos/FaultMaven/svc/git/ref/heads/feat/x --jq .object.sha" ]]' "$(cat "$GH_LOG")"

echo "== refs that are not branches"
tips "main $SHA"
for row in "m4 refs/tags/v1.2.3" "m5 refs/pull/7/merge" "m6 "; do
    id="${row%% *}"; ref="${row#* }"
    run "$ref" "$SHA" "$DIGEST" "$IMG" "$WANT_REPO"
    expect "$id: ${ref:-no ref}: rc 0, moved=false, no lookup, no imagetools" \
        '[[ $RC == 0 && $MOVED == false && $GHN == 0 && $DKN == 0 ]]' "$(eval "$DETAIL")"
    expect "$id: a notice says it is not a branch" \
        '[[ $ANN == "::notice::${ref:-the empty ref} is not a branch, so no branch tag or latest follows it" ]]' "$ANN"
done

echo "== the tip lookup fails: nothing moves, the step passes"
for row in "m7 notfound Not Found (HTTP 404)" "m8 permission Resource not accessible by integration (HTTP 403)" "m9 transport error connecting to api.github.com"; do
    id="${row%% *}"; rest="${row#* }"; mode="${rest%% *}"
    # shellcheck disable=SC2034  # read inside expect's eval
    line="${rest#* }"
    run refs/heads/main "$SHA" "$DIGEST" "$IMG" "$WANT_REPO" GH_MODE="$mode"
    expect "$id: $mode: rc 0, moved=false, no imagetools" '[[ $RC == 0 && $MOVED == false && $DKN == 0 ]]' "$(eval "$DETAIL")"
    expect "$id: $mode: a warning names gh's first line, without its gh: prefix" \
        '[[ $ANN == "::warning::could not read main'"'"'s tip: $line: latest and the branch tag were not moved" ]]' "$ANN"
done

echo "== imagetools fails: nothing moved, the step passes"
tips "main $SHA"
run refs/heads/main "$SHA" "$DIGEST" "$IMG" "$WANT_REPO" DOCKER_FAIL=1
expect "m10: rc 0, moved=false" '[[ $RC == 0 && $MOVED == false && $DKN == 1 ]]' "$(eval "$DETAIL")"
expect "m10: a warning names imagetools' last line, and its output reaches the log" \
    '[[ $ANN == "::warning::could not move the tags: ERROR: failed to push ghcr.io/faultmaven/svc:main: unexpected status from PUT request: 403 Forbidden: latest and the branch tag were not moved" && $ERRS == *"#1 copying"* ]]' "$(eval "$DETAIL")"

echo "== the image as a caller names it, with the owner's capitals"
run refs/heads/main "$SHA" "$DIGEST" "ghcr.io/FaultMaven/svc" "$WANT_REPO"
expect "m11: every reference imagetools gets is lower-case" \
    '[[ $MOVED == true && $DK == "buildx imagetools create --prefer-index=false --tag $IMG:main --tag $IMG:latest $IMG@$DIGEST" ]]' "$(eval "$DETAIL")"

# ============================================================ invalid inputs
echo "== invalid inputs: an error, no lookup, nothing moved, the step passes"
NL=$'\n'
for row in \
    "v1|1111111|$DIGEST|$IMG|$WANT_REPO|the sha input is not a full 40-character lower-case commit sha" \
    "v2|ABCDEF1111111111111111111111111111111111|$DIGEST|$IMG|$WANT_REPO|the sha input is not a full 40-character lower-case commit sha" \
    "v3|$SHA|aaaa|$IMG|$WANT_REPO|the digest input is not a pushed image's digest (sha256:<64 hex>)" \
    "v4|$SHA|$DIGEST|$IMG:main|$WANT_REPO|the image input is not an image repository such as ghcr.io/owner/name (no tag, no digest)" \
    "v5|$SHA|$DIGEST|$IMG@$DIGEST|$WANT_REPO|the image input is not an image repository such as ghcr.io/owner/name (no tag, no digest)" \
    "v6|$SHA|$DIGEST||$WANT_REPO|the image input is not an image repository such as ghcr.io/owner/name (no tag, no digest)" \
    "v7|$SHA|$DIGEST|svc|$WANT_REPO|the image input is not an image repository such as ghcr.io/owner/name (no tag, no digest)" \
    "v8|$SHA|$DIGEST|$IMG|FaultMaven/svc/extra|the repository is not owner/name"; do
    IFS='|' read -r id sha digest image repo msg <<< "$row"
    tips "main $SHA"
    run refs/heads/main "$sha" "$digest" "$image" "$repo"
    expect "$id: rc 0, moved=false, no lookup, no imagetools" \
        '[[ $RC == 0 && $MOVED == false && $GHN == 0 && $DKN == 0 ]]' "$(eval "$DETAIL")"
    expect "$id: $msg" '[[ $ANN == "::error::$msg: latest and the branch tag were not moved" ]]' "$ANN"
done
run refs/heads/main "$SHA" "$DIGEST" "${IMG}${NL}::error::injected" "$WANT_REPO"
expect "v9: an image with a line of its own is refused, and no line it carries starts an annotation" \
    '[[ $RC == 0 && $MOVED == false && $DKN == 0 && $(grep -c "^::" <<< "$OUT") == 1 && $ANN == ::error::the\ image\ input* ]]' "$(eval "$DETAIL")"

# ============================================================ branch names
echo "== branch names"
tips "feat#1 $SHA"
run 'refs/heads/feat#1' "$SHA" "$DIGEST" "$IMG" "$WANT_REPO"
expect "b1: a branch name outside A-Z a-z 0-9 . _ / - is not looked up" \
    '[[ $RC == 0 && $MOVED == false && $GHN == 0 && $DKN == 0 && $ANN == "::warning::the branch name has characters outside A-Z a-z 0-9 . _ / -: latest and the branch tag were not moved" ]]' "$(eval "$DETAIL")"
tips "release/2026.10_rc $SHA"
run refs/heads/release/2026.10_rc "$SHA" "$DIGEST" "$IMG" "$WANT_REPO"
expect "b2: slashes become -, as metadata-action names a branch tag; . and _ stay" \
    '[[ $MOVED == true && $DK == "buildx imagetools create --prefer-index=false --tag $IMG:release-2026.10_rc $IMG@$DIGEST" ]]' "$(eval "$DETAIL")"

# ============================================================ the step always passes
echo "== it never fails the step"
run refs/heads/main "$SHA" "$DIGEST" "$IMG" "$WANT_REPO" GH_MODE=inject
expect "s1: a tip carrying a line of its own makes one annotation, a notice" \
    '[[ $RC == 0 && $MOVED == false && $DKN == 0 && $(grep -c "^::" <<< "$OUT") == 1 && $ANN == "::notice::main is at 0000000 ::error::injected, not $SHA: latest and the branch tag were not moved" ]]' "$(eval "$DETAIL")"
tips "main $SHA"
: > "$GH_LOG"; : > "$DOCKER_LOG"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" GH_LOG="$GH_LOG" DOCKER_LOG="$DOCKER_LOG" TIPS="$TIPS" WANT_REPO="$WANT_REPO" \
    IMAGE="$IMG" DIGEST="$DIGEST" RUN_SHA="$SHA" TAG_REF=refs/heads/main REPO="$WANT_REPO" GH_TOKEN=stub \
    bash --noprofile --norc -eo pipefail "$SCRIPT" > "$WORK/stdout" 2> "$WORK/stderr"
RC=$?
expect "s2: without GITHUB_OUTPUT it still moves the tags, and passes" \
    '[[ $RC == 0 && "$(wc -l < "$DOCKER_LOG" | tr -d " ")" == 1 ]]' "rc=$RC $(cat "$WORK/stdout" "$WORK/stderr")"
run refs/heads/main "$SHA" "$DIGEST" "$IMG" "$WANT_REPO" TMPDIR="$WORK/no-such-dir"
expect "s3: a command failing before the rule (mktemp here) ends in a warning, moved=false, rc 0" \
    '[[ $RC == 0 && $MOVED == false && $GHN == 0 && $DKN == 0 && $ANN == "::warning::move-branch-tags stopped (rc 1): latest and the branch tag were not moved" ]]' "$(eval "$DETAIL")"

# ============================================================ action.yml's wiring
echo "== action.yml runs what this harness runs"
step='.runs.steps[0]'
expect "one step, a bash run step named move" \
    '[[ "$(yq ".runs.steps | length" "$ACTION")" == 1 && "$(yq "$step.shell" "$ACTION")" == bash && "$(yq "$step.id" "$ACTION")" == move ]]' "$(yq ".runs.steps" "$ACTION")"
# shellcheck disable=SC2016,SC2034  # literal GitHub expressions and command line, as action.yml spells them; read inside expect's eval
WANT_RUN='bash --noprofile --norc -eo pipefail "$GITHUB_ACTION_PATH/move.sh"'
expect "the command line is this harness's" \
    '[[ "$(yq "$step.run" "$ACTION")" == "$WANT_RUN" ]]' "$(yq "$step.run" "$ACTION")"
# shellcheck disable=SC2016,SC2034
WANT_ENV='{"IMAGE":"${{ inputs.image }}","DIGEST":"${{ inputs.digest }}","RUN_SHA":"${{ inputs.sha }}","TAG_REF":"${{ inputs.ref }}","REPO":"${{ github.repository }}","GH_TOKEN":"${{ inputs.github-token }}"}'
expect "the env it binds is exactly the names this harness sets" \
    '[[ "$(yq -o=json -I0 "$step.env" "$ACTION")" == "$WANT_ENV" ]]' "$(yq -o=json -I0 "$step.env" "$ACTION")"
# shellcheck disable=SC2016
expect "image, digest and sha are required; ref and github-token default to the run's" \
    '[[ "$(yq ".inputs.image.required, .inputs.digest.required, .inputs.sha.required" "$ACTION" | paste -sd,)" == true,true,true && "$(yq ".inputs.ref.default" "$ACTION")" == "\${{ github.ref }}" && "$(yq ".inputs.github-token.default" "$ACTION")" == "\${{ github.token }}" && "$(yq ".inputs | keys | sort | join(\",\")" "$ACTION")" == "digest,github-token,image,ref,sha" ]]' "$(yq ".inputs" "$ACTION")"
# shellcheck disable=SC2016
expect "the moved output is the step's" \
    '[[ "$(yq ".outputs.moved.value" "$ACTION")" == "\${{ steps.move.outputs.moved }}" ]]' "$(yq ".outputs" "$ACTION")"

echo
echo "move-branch-tags: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
