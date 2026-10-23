#!/bin/bash
# Drives update-image-queue/update.sh against a local bare remote, the way
# action.yml runs it.
#
# WHAT IS DRIVEN, each row on a fresh sandbox:
#   - a local bare "infra" remote holding `main` (one unrelated file) and an
#     orphan `image-queue` seed with svc-a's and svc-b's queue files;
#   - the step's clone of `image-queue`, made before any race lands;
#   - a local "service repo" with X -> Y on main and Z on a side branch off X.
#   | # | queue / race                                  | run | expect                                  |
#   | 1 | empty seed                                    | Y   | writes; one new commit on image-queue   |
#   | 2 | queued X                                      | Y   | writes                                  |
#   | 3 | queued Y                                      | X   | rc 0, ::notice::, unchanged             |
#   | 4 | queued Y                                      | Y   | rc 0, unchanged, no compare             |
#   | 5 | queued Z                                      | Y   | rc 1, ::error:: naming both, unchanged  |
#   | 6 | queued unknown sha                            | Y   | rc 1 at once, Not Found named           |
#   | 7 | clone at the seed, then Y lands               | X   | rejected -> recompute -> skip           |
#   | 8 | clone at the seed, then X lands               | Y   | rejected -> recompute -> write (ff)     |
#   | 9 | clone at the seed, then svc-b's file lands    | Y   | rejected -> recompute -> write, both ok |
#   |10 | every row                                     |     | the remote's main is unchanged          |
# then the entries the rule refuses (r1-r6), races and odd entries (101-111),
# failure messages (F6, F7, F9-F12), the inputs action.yml passes (v1-v6), and
# action.yml's own wiring: the checkout, the working directory, the command
# line and the env names this harness binds.
# Every refusal of the queue's state ends "GHCR holds <tag> but the queue does
# not name it."
#
# The script runs as `bash --noprofile --norc -eo pipefail update.sh`, the
# form GitHub gives a `run:` step and the command action.yml runs, so `-e` is
# on from its first line. A harness that ran `bash update.sh` would test a
# different program; the wiring check below holds the two command lines equal.
# Commit dates are fixed (GIT_*_DATE, a `date` stub), so a run writes the same
# commits every time.
#
# SAFETY: nothing here reaches GitHub. `gh` is a stub that answers
# `gh api repos/<repo>/compare/A...B?per_page=1 --jq .status` from the local service
# repo with `git merge-base --is-ancestor` both ways (an unknown sha gives the
# 404 shape: the JSON body on stdout, the message on stderr, rc 1; GH_DENY
# gives GitHub's 403 for a token without `contents: read`, a rate limit's 403,
# or a 502); `sleep`
# and `date` are stubs; every git remote is a local path, and git reads no
# user or system config. The run refuses to start unless `command -v`
# resolves gh, sleep and date to the stubs.
#
# Run: tests/test-update-image-queue.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ACTION_DIR="$REPO_ROOT/update-image-queue"
ACTION="$ACTION_DIR/action.yml"
SCRIPT="$ACTION_DIR/update.sh"
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

command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah v4) is required"; exit 1; }
# The action installs mikefarah yq v4 (install-yq.sh); CI installs the same.
[[ "$(yq --version 2>&1)" == *mikefarah* ]] || { echo "yq must be mikefarah yq v4, as install-yq.sh installs: $(yq --version 2>&1)"; exit 1; }

# ------------------------------------------------------------------ git, hermetic
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# action.yml's env: values for the commit identity, plus fixed dates.
export GIT_AUTHOR_NAME='faultmaven-infra-queue-bot[bot]' GIT_AUTHOR_EMAIL='faultmaven-infra-queue-bot[bot]@users.noreply.github.com'
export GIT_COMMITTER_NAME='faultmaven-infra-queue-bot[bot]' GIT_COMMITTER_EMAIL='faultmaven-infra-queue-bot[bot]@users.noreply.github.com'
export GIT_AUTHOR_DATE='1760745600 +0000' GIT_COMMITTER_DATE='1760745600 +0000'
NOW_FIXED=2026-10-18T00:00:00Z

# ------------------------------------------------------------------ stubs
BIN="$WORK/bin"; mkdir -p "$BIN"
GH_LOG="$WORK/gh.log"; SLEEP_LOG="$WORK/sleep.log"; : > "$GH_LOG"; : > "$SLEEP_LOG"
SVC="$WORK/service-repo"
cat > "$BIN/gh" <<'GHSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$#" -eq 4 ] && [ "$1" = api ] && [ "$3" = --jq ] && [ "$4" = .status ] \
    || { echo "stub gh: only 'gh api repos/<repo>/compare/A...B?per_page=1 --jq .status' is stubbed: $*" >&2; exit 2; }
case "$2" in
    "repos/$WANT_REPO/compare/"*...*"?per_page=1") ;;
    *) echo "stub gh: unexpected path: $2" >&2; exit 2 ;;
esac
range="${2#"repos/$WANT_REPO/compare/"}"; range="${range%"?per_page=1"}"
base="${range%%...*}"; head="${range#*...}"
b="$(git -C "$SVC" rev-parse -q --verify "${base}^{commit}" 2>/dev/null)" || b=""
h="$(git -C "$SVC" rev-parse -q --verify "${head}^{commit}" 2>/dev/null)" || h=""
case "${GH_DENY:-}" in
    permission)
        printf '%s' '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest/commits/commits#compare-two-commits","status":"403"}'
        echo "gh: Resource not accessible by integration (HTTP 403)" >&2
        exit 1 ;;
    ratelimit)
        printf '%s' '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","status":"403"}'
        echo "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)" >&2
        exit 1 ;;
    unavailable)
        printf '%s' '{"message":"Server Error","status":"502"}'
        echo "gh: Server Error (HTTP 502)" >&2
        exit 1 ;;
esac
if [ -n "${GH_TRANSPORT_FAIL:-}" ]; then
    printf '%s\n' "error connecting to api.github.com" "check your internet connection or https://githubstatus.com" >&2
    exit 1
fi
if [ -z "$base" ] || [ -z "$b" ] || [ -z "$h" ]; then
    printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/commits/commits#compare-two-commits","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
fi
if [ "$b" = "$h" ]; then echo identical
elif git -C "$SVC" merge-base --is-ancestor "$b" "$h"; then echo ahead
elif git -C "$SVC" merge-base --is-ancestor "$h" "$b"; then echo behind
else echo diverged
fi
GHSTUB
cat > "$BIN/sleep" <<'SLEEPSTUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SLEEP_LOG"
SLEEPSTUB
cat > "$BIN/date" <<'DATESTUB'
#!/bin/sh
[ "$*" = "-u +%Y-%m-%dT%H:%M:%SZ" ] || { echo "stub date: unexpected arguments: $*" >&2; exit 2; }
printf '%s\n' "$NOW_FIXED"
DATESTUB
chmod +x "$BIN/gh" "$BIN/sleep" "$BIN/date"
export PATH="$BIN:$PATH" GH_LOG SLEEP_LOG SVC NOW_FIXED GH_TOKEN=stub-token-not-a-credential WANT_REPO=FaultMaven/svc-a
unset GITHUB_TOKEN
for c in gh sleep date; do
    if [ "$(command -v "$c")" != "$BIN/$c" ]; then
        echo "REFUSING TO RUN: '$c' resolves to '$(command -v "$c")', not the stub $BIN/$c"
        exit 1
    fi
done
echo "gh, sleep and date resolve to the stubs in $BIN"

# ------------------------------------------------------------------ the service repo: X -> Y on main, Z off X
git init -q -b main "$SVC"
svc_commit() { printf '%s\n' "$1" > "$SVC/f"; git -C "$SVC" add f; git -C "$SVC" commit -qm "$1"; git -C "$SVC" rev-parse HEAD; }
svc_commit base >/dev/null
X="$(svc_commit x)"; Y="$(svc_commit y)"
git -C "$SVC" switch -q -c side "$X"; Z="$(svc_commit z)"; git -C "$SVC" switch -q main
UNKNOWN=0123456789abcdef0123456789abcdef01234567

# ------------------------------------------------------------------ a row's sandbox
qfile() { # dir, service, commit ('' = an empty, unseeded entry)
    local c="$3" t="" u=""
    [ -n "$c" ] && { t="sha-${c:0:7}"; u=2026-10-01T00:00:00Z; }
    printf 'image: ghcr.io/faultmaven/%s\nservice: %s\ntag: "%s"\nupdated_at: "%s"\ncommit_sha: "%s"\n' "$2" "$2" "$t" "$u" "$c" \
        > "$1/available-images/staging/$2.yaml"
}
# Sets SB and the pristine refs. race: none | svc-b | rm-svc-a | <a commit svc-a's entry moves to>
# entry: svc-a's file as raw YAML in place of the seeded one, or MISSING for
# no file at all.
mkrow() { # name, svc-a's seeded commit ('' = empty), race, [entry]
    SB="$WORK/row-$1"
    local src="$SB/src"
    mkdir -p "$SB"
    git init -q --bare "$SB/remote.git"
    git init -q -b main "$src"
    printf 'unrelated\n' > "$src/README.md"
    git -C "$src" add README.md; git -C "$src" commit -qm main
    git -C "$src" push -q "$SB/remote.git" main 2>/dev/null
    git -C "$src" switch -q --orphan image-queue
    mkdir -p "$src/available-images/staging"
    qfile "$src" svc-a "$2"; qfile "$src" svc-b ""
    case "${4-}" in
        "") ;;
        MISSING) rm "$src/available-images/staging/svc-a.yaml" ;;
        *) printf '%s\n' "$4" > "$src/available-images/staging/svc-a.yaml" ;;
    esac
    git -C "$src" add -A available-images; git -C "$src" commit -qm seed
    git -C "$src" push -q "$SB/remote.git" image-queue 2>/dev/null
    SEED="$(git -C "$SB/remote.git" rev-parse image-queue)"
    git clone -q -b image-queue "$SB/remote.git" "$SB/infra" 2>/dev/null
    # Another run lands after this checkout.
    case "$3" in
        none) ;;
        svc-b) qfile "$src" svc-b "$X"; git -C "$src" commit -qam "svc-b lands"; git -C "$src" push -q "$SB/remote.git" image-queue 2>/dev/null ;;
        rm-svc-a) git -C "$src" rm -q available-images/staging/svc-a.yaml; git -C "$src" commit -qm "svc-a removed"; git -C "$src" push -q "$SB/remote.git" image-queue 2>/dev/null ;;
        *)     qfile "$src" svc-a "$3"; git -C "$src" commit -qam "svc-a lands"; git -C "$src" push -q "$SB/remote.git" image-queue 2>/dev/null ;;
    esac
    SB_REMOTE_TIP="$(git -C "$SB/remote.git" rev-parse image-queue)"
    SB_REMOTE_MAIN="$(git -C "$SB/remote.git" rev-parse main)"
}
# Runs the script for this run's commit, as action.yml does. Sets OUT, RC, SUM,
# CALLS, SLEEPS, TIP, MAIN_NOW, A_TAG/A_COMMIT/A_UPDATED (svc-a's entry on
# origin) and B_COMMIT. Extra NAME=value arguments override the inputs.
runrow() { # run commit, [NAME=value]...
    local run="$1"; shift
    : > "$GH_LOG"; : > "$SLEEP_LOG"; : > "$SB/summary"
    OUT="$(cd "$SB/infra" && env SERVICE_NAME=svc-a RUN_SHA="$run" REPO=FaultMaven/svc-a \
        TRIGGERED_BY=tester WORKFLOW_NAME="Publish Docker" GITHUB_STEP_SUMMARY="$SB/summary" "$@" \
        bash --noprofile --norc -eo pipefail "$SCRIPT" 2>&1)"; RC=$?
    SUM="$(cat "$SB/summary")"; CALLS="$(cat "$GH_LOG")"
    # shellcheck disable=SC2034  # SLEEPS is read inside expect's eval
    SLEEPS="$(grep -c . "$SLEEP_LOG" || true)"
    # shellcheck disable=SC2034  # SLEEP_ARGS is read inside expect's eval
    SLEEP_ARGS="$(tr '\n' ' ' < "$SLEEP_LOG")"
    TIP="$(git -C "$SB/remote.git" rev-parse image-queue)"
    MAIN_NOW="$(git -C "$SB/remote.git" rev-parse main)"
    A_TAG="$(git -C "$SB/remote.git" show image-queue:available-images/staging/svc-a.yaml 2>/dev/null | yq '.tag')"
    A_COMMIT="$(git -C "$SB/remote.git" show image-queue:available-images/staging/svc-a.yaml 2>/dev/null | yq '.commit_sha')"
    A_UPDATED="$(git -C "$SB/remote.git" show image-queue:available-images/staging/svc-a.yaml 2>/dev/null | yq '.updated_at')"
    B_COMMIT="$(git -C "$SB/remote.git" show image-queue:available-images/staging/svc-b.yaml | yq '.commit_sha')"
}
ctx() { printf 'rc=%s\nout:\n%s\nsummary:\n%s\ngh calls:\n%s\nimage-queue: %s (pristine %s, seed %s)\nsvc-a: tag=%s commit=%s updated=%s; svc-b commit=%s' \
    "$RC" "$OUT" "$SUM" "$CALLS" "$TIP" "$SB_REMOTE_TIP" "$SEED" "$A_TAG" "$A_COMMIT" "$A_UPDATED" "$B_COMMIT"; }
call() { printf 'api repos/FaultMaven/svc-a/compare/%s...%s?per_page=1 --jq .status' "$1" "$2"; }
# Every row: the exit code, and main is unchanged.
common() { # label, want-rc
    if [[ "$RC" -eq "$2" ]]; then ok "$1: exits $2"; else bad "$1: exits $2" "$(ctx)"; fi
    if [[ "$MAIN_NOW" == "$SB_REMOTE_MAIN" ]]; then ok "$1: row 10, the remote's main is unchanged"
    else bad "$1: row 10, the remote's main is unchanged" "main: $SB_REMOTE_MAIN -> $MAIN_NOW"; fi
}
# shellcheck disable=SC2034  # read inside expect's eval
GHCR_Y="GHCR holds sha-${Y:0:7} but the queue does not name it."
# shellcheck disable=SC2034  # read inside expect's eval
WROTE_Y='[[ "$A_TAG" == "sha-${Y:0:7}" && "$A_COMMIT" == "$Y" && "$A_UPDATED" == "$NOW_FIXED" ]] && grep -qxF "✓ Updated image queue: sha-${Y:0:7}" <<< "$OUT"'

# ============================================================ rows
echo "== 1. an empty seed, run Y: writes"
mkrow 1 "" none; runrow "$Y"; common "row 1" 0
expect "row 1: tag, updated_at and commit_sha are Y's" "$WROTE_Y" "$(ctx)"
expect "row 1: exactly one new commit on image-queue, on top of the seed; no compare (the queue named no commit)" \
    '[[ "$(git -C "$SB/remote.git" rev-parse image-queue^)" == "$SEED" && -z "$CALLS" ]]' "$(ctx)"
expect "row 1: the commit message names the service, the tag, the run's commit, the actor and the workflow (all bound through env:)" \
    '[[ "$(git -C "$SB/remote.git" log -1 --format=%B image-queue)" == "chore(queue): update svc-a image to sha-${Y:0:7}"$'"'"'\n\n'"'"'"Built from: FaultMaven/svc-a@$Y"$'"'"'\n'"'"'"Triggered by: @tester"$'"'"'\n'"'"'"Workflow: Publish Docker"* ]]' \
    "$(git -C "$SB/remote.git" log -1 --format=%B image-queue)"

echo "== 2. queued X, run Y: writes"
mkrow 2 "$X" none; runrow "$Y"; common "row 2" 0
expect "row 2: Y replaces X, after one compare X...Y" \
    "$WROTE_Y"' && [[ "$(git -C "$SB/remote.git" rev-parse image-queue^)" == "$SEED" && "$CALLS" == "$(call "$X" "$Y")" ]]' "$(ctx)"

echo "== 3. queued Y, run X: an older build never replaces a newer entry"
mkrow 3 "$Y" none; runrow "$X"; common "row 3" 0
expect "row 3: ::notice:: that this run's commit is older and the queue keeps Y; image-queue unchanged" \
    'grep -qxF "::notice::this run'"'"'s commit is older than the queued $Y; the queue keeps $Y in available-images/staging/svc-a.yaml" <<< "$OUT" && [[ "$TIP" == "$SB_REMOTE_TIP" && "$A_COMMIT" == "$Y" && "$CALLS" == "$(call "$Y" "$X")" && "$SUM" == "## Image queue"* && "$SUM" == *"is unchanged: this run'"'"'s commit is older than the queued $Y. It keeps \`$Y\`; this run is \`$X\`."* ]] && ! grep -q "Updated image queue" <<< "$OUT"' "$(ctx)"

echo "== 4. queued Y, run Y: nothing to do"
mkrow 4 "$Y" none; runrow "$Y"; common "row 4" 0
expect "row 4: ::notice:: that the queue already names this commit; unchanged; no compare" \
    'grep -qxF "::notice::the queue already names this commit; the queue keeps $Y in available-images/staging/svc-a.yaml" <<< "$OUT" && [[ "$TIP" == "$SB_REMOTE_TIP" && -z "$CALLS" ]]' "$(ctx)"

echo "== 5. queued Z (diverged), run Y: refused"
mkrow 5 "$Z" none; runrow "$Y"; common "row 5" 1
expect "row 5: ::error:: naming both commits and the file; image-queue unchanged" \
    'grep -qxF "::error::neither commit contains the other: available-images/staging/svc-a.yaml names $Z and this run is $Y. The queue is left as it is. $GHCR_Y" <<< "$OUT" && [[ "$TIP" == "$SB_REMOTE_TIP" && "$A_COMMIT" == "$Z" ]]' "$(ctx)"

echo "== 6. queued an unknown sha, run Y: refused at once, never written"
mkrow 6 "$UNKNOWN" none; runrow "$Y"; common "row 6" 1
expect "row 6: one compare, no sleep, then ::error:: naming the 404 and both causes, with the entry; image-queue unchanged" \
    '[[ "$(grep -c . <<< "$CALLS")" == 1 && "$SLEEPS" == 0 && "$TIP" == "$SB_REMOTE_TIP" && "$A_COMMIT" == "$UNKNOWN" ]] && grep -qxF "::error::the compare $UNKNOWN...$Y answered '"'"'Not Found (HTTP 404)'"'"': one of them is not a commit of FaultMaven/svc-a (a rewritten history?), or github-token cannot see FaultMaven/svc-a: available-images/staging/svc-a.yaml has tag '"'"'sha-${UNKNOWN:0:7}'"'"' and commit_sha '"'"'$UNKNOWN'"'"'. The queue is left as it is. $GHCR_Y" <<< "$OUT" && [[ "$OUT" != *"documentation_url"* && "$OUT" != *"after 3 attempts"* ]]' "$(ctx)"

echo "== 7. clone at the seed, Y lands, run X: rejected, recomputed, skipped"
mkrow 7 "" "$Y"; runrow "$X"; common "row 7" 0
expect "row 7: the push is rejected, the recompute reads Y and skips; image-queue stays Y" \
    'grep -qF "push rejected; recomputing against origin/image-queue (attempt 1/3)" <<< "$OUT" && grep -qxF "::notice::this run'"'"'s commit is older than the queued $Y; the queue keeps $Y in available-images/staging/svc-a.yaml" <<< "$OUT" && [[ "$TIP" == "$SB_REMOTE_TIP" && "$A_COMMIT" == "$Y" && "$CALLS" == "$(call "$Y" "$X")" ]]' "$(ctx)"

echo "== 8. clone at the seed, X lands, run Y: rejected, recomputed, written over X"
mkrow 8 "" "$X"; runrow "$Y"; common "row 8" 0
expect "row 8: the push is rejected, the recompute reads X and writes Y as a fast-forward of X's commit" \
    'grep -qF "push rejected; recomputing against origin/image-queue (attempt 1/3)" <<< "$OUT" && '"$WROTE_Y"' && [[ "$(git -C "$SB/remote.git" rev-parse image-queue^)" == "$SB_REMOTE_TIP" && "$CALLS" == "$(call "$X" "$Y")" ]]' "$(ctx)"

echo "== 9. clone at the seed, another service's file lands, run Y: rejected, recomputed, written"
mkrow 9 "" svc-b; runrow "$Y"; common "row 9" 0
expect "row 9: the push is rejected, the recompute writes Y on top of svc-b's commit, and svc-b's entry is kept" \
    'grep -qF "push rejected; recomputing against origin/image-queue (attempt 1/3)" <<< "$OUT" && '"$WROTE_Y"' && [[ "$(git -C "$SB/remote.git" rev-parse image-queue^)" == "$SB_REMOTE_TIP" && "$B_COMMIT" == "$X" && -z "$CALLS" ]]' "$(ctx)"

# ============================================================ entries the rule refuses
# A refused entry writes nothing and makes no compare: a person fixes it on
# image-queue. Each row checks the refuse line exactly, the GHCR sentence,
# no compare, no sleep, and image-queue unchanged.
refused() { # label, want error line
    # shellcheck disable=SC2034  # WANT_ERR is read inside expect's eval
    WANT_ERR="$2"
    expect "$1: refused with exactly '$2'; no compare, no sleep; image-queue unchanged" \
        '[[ "$(grep -c "^::error::" <<< "$OUT")" == 1 && -z "$CALLS" && "$SLEEPS" == 0 && "$TIP" == "$SB_REMOTE_TIP" ]] && grep -qxF -- "$WANT_ERR" <<< "$OUT"' "$(ctx)"
}
echo "== r1. an entry with tag v9.9.9 and an empty commit_sha: refused"
mkrow r1 "" none 'image: ghcr.io/faultmaven/svc-a
tag: "v9.9.9"
commit_sha: ""'
runrow "$Y"; common "r1" 1
refused "r1" "::error::the queue entry names no commit this rule can order: available-images/staging/svc-a.yaml has tag 'v9.9.9' and commit_sha ''. The queue is left as it is. $GHCR_Y"

echo "== r2. commit_sha: main: refused"
mkrow r2 "" none "image: ghcr.io/faultmaven/svc-a
tag: \"sha-${X:0:7}\"
commit_sha: main"
runrow "$Y"; common "r2" 1
refused "r2" "::error::the queued commit_sha is not a commit sha: available-images/staging/svc-a.yaml has tag 'sha-${X:0:7}' and commit_sha 'main'. The queue is left as it is. $GHCR_Y"

echo "== r3. a two-line commit_sha: refused, no line of it printed raw"
mkrow r3 "" none "image: ghcr.io/faultmaven/svc-a
tag: \"sha-${X:0:7}\"
commit_sha: |
  ${X}
  ::warning::injected"
runrow "$Y"; common "r3" 1
refused "r3" "::error::the queued commit_sha is not a commit sha: available-images/staging/svc-a.yaml has tag 'sha-${X:0:7}' and commit_sha '${X} ::warning::injected'. The queue is left as it is. $GHCR_Y"
expect "r3: no output line starts with the commit_sha's second line (it is flattened onto the error line)" \
    '! grep -q "^::warning::injected" <<< "$OUT" && ! grep -qx "$X" <<< "$OUT"' "$(ctx)"

echo "== r4. a tag and commit_sha naming different commits: refused"
mkrow r4 "" none "image: ghcr.io/faultmaven/svc-a
tag: \"sha-${X:0:7}\"
commit_sha: \"${Y}\""
runrow "$Y"; common "r4" 1
refused "r4" "::error::the queued tag and commit_sha name different commits: available-images/staging/svc-a.yaml has tag 'sha-${X:0:7}' and commit_sha '${Y}'. The queue is left as it is. $GHCR_Y"

echo "== r5. no queue file: refused at once"
mkrow r5 "" none MISSING; runrow "$Y"; common "r5" 1
refused "r5" "::error::Queue file not found: available-images/staging/svc-a.yaml on image-queue - register the service first. $GHCR_Y"

echo "== r6. a pre-receive denial on the remote: refused once, not as a race"
mkrow r6 "" none
printf '#!/bin/sh\necho "denied by policy" >&2\nexit 1\n' > "$SB/remote.git/hooks/pre-receive"; chmod +x "$SB/remote.git/hooks/pre-receive"
runrow "$Y"; common "r6" 1
# shellcheck disable=SC2034  # read inside expect's eval
DENIED="::error::the push to image-queue failed, not as a race: ! [remote rejected] image-queue -> image-queue (pre-receive hook declined). $GHCR_Y"
expect "r6: one push, refused with 'not as a race' and git's ' ! ' status line, trimmed; no recompute, no sleep; image-queue unchanged" \
    'grep -qxF "$DENIED" <<< "$OUT" && ! grep -q "recomputing" <<< "$OUT" && [[ "$SLEEPS" == 0 && "$TIP" == "$SB_REMOTE_TIP" ]]' "$(ctx)"

# ============================================================ races and odd entries
echo "== 101. a lock-level race: another writer moves image-queue during the push"
# The pre-receive hook moves image-queue, outside the quarantine, to C (svc-b
# lands on the seed) when it still points at the seed, then accepts, as a
# writer winning the ref lock would. receive-pack's update then fails on the
# old value. On the recompute the ref is C, so the hook does nothing.
mkrow 101 "" none
qfile "$SB/src" svc-b "$X"; git -C "$SB/src" commit -qam "svc-b lands"
git -C "$SB/src" push -q "$SB/remote.git" HEAD:refs/heads/lock-race 2>/dev/null
LOCK_C="$(git -C "$SB/src" rev-parse HEAD)"
printf '#!/bin/sh
if [ "$(git rev-parse refs/heads/image-queue)" = "%s" ]; then
  env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git update-ref refs/heads/image-queue %s
fi
exit 0
' \
    "$SEED" "$LOCK_C" > "$SB/remote.git/hooks/pre-receive"
chmod +x "$SB/remote.git/hooks/pre-receive"
runrow "$Y"; common "101" 0
expect "101: git reports the lock race (remote rejected: incorrect old value, or cannot lock ref), the step recomputes, and Y lands on top of C with svc-b kept" \
    'grep -qE "^ ! \[remote rejected\] image-queue -> image-queue \((incorrect old value provided|cannot lock ref|failed to update ref)" <<< "$OUT" && grep -qF "push rejected; recomputing against origin/image-queue (attempt 1/3)" <<< "$OUT" && ! grep -q "not as a race" <<< "$OUT" && '"$WROTE_Y"' && [[ "$(git -C "$SB/remote.git" rev-parse image-queue^)" == "$LOCK_C" && "$B_COMMIT" == "$X" ]]' "$(ctx)"

echo "== 103. tag: false, commit_sha: false: refused, never unseeded"
mkrow 103 "" none 'image: ghcr.io/faultmaven/svc-a
tag: false
commit_sha: false'
runrow "$Y"; common "103" 1
refused "103" "::error::the queued commit_sha is not a commit sha: available-images/staging/svc-a.yaml has tag 'false' and commit_sha 'false'. The queue is left as it is. $GHCR_Y"

echo "== 107. a 7-hex commit_sha and an 8-hex tag of the same commit: they agree"
mkrow 107 "" none "image: ghcr.io/faultmaven/svc-a
tag: \"sha-${X:0:8}\"
commit_sha: \"${X:0:7}\""
runrow "$Y"; common "107" 0
expect "107: the entry is ordered (compare ${X:0:7}...Y) and Y written" \
    "$WROTE_Y"' && [[ "$CALLS" == "$(call "${X:0:7}" "$Y")" ]]' "$(ctx)"

echo "== 111. a blank remote: line before the hook's reason"
mkrow 111 "" none
printf '#!/bin/sh
echo >&2
echo "denied by policy" >&2
exit 1
' > "$SB/remote.git/hooks/pre-receive"; chmod +x "$SB/remote.git/hooks/pre-receive"
runrow "$Y"; common "111" 1
expect "111: the reason is the trimmed ' ! ' status line, after a single space, never the blank remote: line" \
    'grep -qxF "$DENIED" <<< "$OUT" && ! grep -q "race:  " <<< "$OUT" && ! grep -qE "race: remote:[[:space:]]*\. " <<< "$OUT" && [[ "$TIP" == "$SB_REMOTE_TIP" ]]' "$(ctx)"

# ============================================================ failure messages and races
echo "== F6. gh's two-line connection failure: the reason is its first line"
mkrow f6 "$X" none; export GH_TRANSPORT_FAIL=1; runrow "$Y"; unset GH_TRANSPORT_FAIL; common "F6" 1
expect "F6: three attempts, then ::error:: with gh's first line (the error), never its hint; image-queue unchanged" \
    'grep -qxF "::error::could not update the queue after 3 attempts: the compare $X...$Y failed: error connecting to api.github.com. $GHCR_Y" <<< "$OUT" && ! grep -q "githubstatus" <<< "$OUT" && [[ "$(grep -c . <<< "$CALLS")" == 3 && "$TIP" == "$SB_REMOTE_TIP" ]]' "$(ctx)"

echo "== F7. a racing writer removes the queue file between attempts"
mkrow f7 "" rm-svc-a; runrow "$Y"; common "F7" 1
expect "F7: attempt 1's push is rejected as a race; attempt 2's missing-file check refuses at once, with no sleep; image-queue stays as the racing writer left it" \
    'grep -qF "push rejected; recomputing against origin/image-queue (attempt 1/3)" <<< "$OUT" && grep -qxF "::error::Queue file not found: available-images/staging/svc-a.yaml on image-queue - register the service first. $GHCR_Y" <<< "$OUT" && [[ "$(grep -c "^::error::" <<< "$OUT")" == 1 && "$SLEEPS" == 0 && "$TIP" == "$SB_REMOTE_TIP" ]]' "$(ctx)"

echo "== F9. an upper-case tag hex beside a lower-case commit_sha: they agree"
mkrow f9 "" none "image: ghcr.io/faultmaven/svc-a
tag: \"sha-$(tr 'a-f' 'A-F' <<< "$X")\"
commit_sha: \"${X}\""
runrow "$Y"; common "F9" 0
expect "F9: the entry is ordered (compare X...Y) and Y written" \
    "$WROTE_Y"' && [[ "$CALLS" == "$(call "$X" "$Y")" ]]' "$(ctx)"

# ============================================================ the inputs action.yml passes
# An input that fails its check stops the script before any read or write:
# no compare, no push, image-queue unchanged, and the value is not echoed.
rejected() { # label, want error line
    # shellcheck disable=SC2034  # WANT_ERR is read inside expect's eval
    WANT_ERR="$2"
    expect "$1: refused with exactly '$2' before any read; no compare; image-queue unchanged" \
        '[[ "$OUT" == "$WANT_ERR" && -z "$CALLS" && "$TIP" == "$SB_REMOTE_TIP" ]]' "$(ctx)"
}

echo "== F10. a token without contents: read: GitHub's 403, refused at once"
mkrow f10 "$X" none; export GH_DENY=permission; runrow "$Y"; unset GH_DENY; common "F10" 1
expect "F10: one compare, no sleep, then ::error:: naming the token, gh's first line and permissions: contents: read; image-queue unchanged" \
    '[[ "$(grep -c . <<< "$CALLS")" == 1 && "$SLEEPS" == 0 && "$TIP" == "$SB_REMOTE_TIP" ]] && grep -qxF "::error::github-token cannot read FaultMaven/svc-a'"'"'s commits (the compare $X...$Y answered '"'"'Resource not accessible by integration (HTTP 403)'"'"'): the calling job needs permissions: contents: read. The queue is left as it is. $GHCR_Y" <<< "$OUT" && [[ "$OUT" != *"documentation_url"* ]]' "$(ctx)"

echo "== F11. a 403 rate limit is transient: retried like any other failure"
mkrow f11 "$X" none; export GH_DENY=ratelimit; runrow "$Y"; unset GH_DENY; common "F11" 1
expect "F11: three compares, sleeps 2s and 4s, then ::error:: after 3 attempts with the rate limit's line; image-queue unchanged" \
    '[[ "$(grep -c . <<< "$CALLS")" == 3 && "$SLEEPS" == 2 && "$SLEEP_ARGS" == "2 4 " && "$TIP" == "$SB_REMOTE_TIP" ]] && grep -qxF "::error::could not update the queue after 3 attempts: the compare $X...$Y failed: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403). $GHCR_Y" <<< "$OUT"' "$(ctx)"
echo "== F12. a 5xx is transient: retried, never refused"
mkrow f12 "$X" none; export GH_DENY=unavailable; runrow "$Y"; unset GH_DENY; common "F12" 1
expect "F12: three compares, sleeps 2s and 4s, then ::error:: after 3 attempts with the 502's line; image-queue unchanged" \
    '[[ "$(grep -c . <<< "$CALLS")" == 3 && "$SLEEPS" == 2 && "$SLEEP_ARGS" == "2 4 " && "$TIP" == "$SB_REMOTE_TIP" ]] && grep -qxF "::error::could not update the queue after 3 attempts: the compare $X...$Y failed: Server Error (HTTP 502). $GHCR_Y" <<< "$OUT"' "$(ctx)"

echo "== v1. a service name that is not a queue file name: refused"
mkrow v1 "" none; runrow "$Y" SERVICE_NAME="../svc-a"; common "v1" 1
rejected "v1" "::error::the service input is not a queue file name (a-z, 0-9 and -, at most 63 characters)"
echo "== v2. a short sha: refused"
mkrow v2 "" none; runrow "${Y:0:7}"; common "v2" 1
rejected "v2" "::error::the sha input is not a full 40-character lower-case commit sha"
echo "== v3. a service name with a path after a valid prefix: refused (the check is anchored)"
mkrow v3 "" none; runrow "$Y" SERVICE_NAME="svc-a/../x"; common "v3" 1
rejected "v3" "::error::the service input is not a queue file name (a-z, 0-9 and -, at most 63 characters)"
echo "== v4. a service name with a second line: refused, never echoed"
mkrow v4 "" none; runrow "$Y" SERVICE_NAME=$'svc-a\n::warning::x'; common "v4" 1
rejected "v4" "::error::the service input is not a queue file name (a-z, 0-9 and -, at most 63 characters)"
echo "== v5. a sha with text after its 40 hex: refused (the check is anchored)"
mkrow v5 "" none; runrow "${Y}/../x"; common "v5" 1
rejected "v5" "::error::the sha input is not a full 40-character lower-case commit sha"
echo "== v6. a sha with text before its 40 hex: refused (the check is anchored at both ends)"
mkrow v6 "" none; runrow "../${Y}"; common "v6" 1
rejected "v6" "::error::the sha input is not a full 40-character lower-case commit sha"

echo "== s1. a write records the tag and the file in the step summary"
mkrow s1 "" none; runrow "$Y"; common "s1" 0
expect "s1: the summary says the queue was updated, with the tag and the file, and that it does not deploy" \
    '[[ "$SUM" == "## Image queue updated"* && "$SUM" == *"- Tag: \`sha-${Y:0:7}\`"* && "$SUM" == *"- File: \`available-images/staging/svc-a.yaml\`"* && "$SUM" == *"does **not** deploy"* ]]' "$(ctx)"

# ============================================================ action.yml's wiring
echo "== action.yml runs what this harness runs"
co="$(yq -o=json '.runs.steps[] | select(.uses // "" | test("^actions/checkout@")) | .with' "$ACTION")"
expect "the only checkout is FaultMaven/faultmaven-enterprise-infra at ref image-queue, never main, with the input token and path" \
    '[[ "$(yq -n "$co | .repository")" == FaultMaven/faultmaven-enterprise-infra && "$(yq -n "$co | .ref")" == image-queue && "$(yq -n "$co | .token")" == "\${{ inputs.token }}" && "$(yq -n "$co | .path")" == "\${{ inputs.path }}" && "$(yq "[.runs.steps[] | select(.uses // \"\" | test(\"^actions/checkout@\"))] | length" "$ACTION")" == 1 ]]' "$co"
upd='.runs.steps[] | select(.name == "Update and push the queue file")'
expect "the update step runs in the checkout's path" \
    '[[ "$(yq "$upd | .[\"working-directory\"]" "$ACTION")" == "\${{ inputs.path }}" ]]' "$(yq "$upd" "$ACTION")"
# shellcheck disable=SC2016,SC2034  # literal GitHub expressions and command line, as action.yml spells them; read inside expect's eval
WANT_RUN='bash --noprofile --norc -eo pipefail "$GITHUB_ACTION_PATH/update.sh"'
expect "the update step's command line is the one this harness runs (GitHub's -eo pipefail form)" \
    '[[ "$(yq "$upd | .run" "$ACTION")" == "$WANT_RUN" ]]' "$(yq "$upd | .run" "$ACTION")"
# The whole env map, names and values: the run's commit is the input sha (never
# github.sha, which a workflow_run sets to main's tip), the compare reads this
# repository with github-token (the App token cannot), and the identity is the
# one this harness exports.
# shellcheck disable=SC2016,SC2034  # literal GitHub expressions; read inside expect's eval
WANT_ENV='{"SERVICE_NAME":"${{ inputs.service }}","RUN_SHA":"${{ inputs.sha }}","REPO":"${{ github.repository }}","GH_TOKEN":"${{ inputs.github-token }}","TRIGGERED_BY":"${{ github.actor }}","WORKFLOW_NAME":"${{ github.workflow }}","GIT_AUTHOR_NAME":"faultmaven-infra-queue-bot[bot]","GIT_AUTHOR_EMAIL":"faultmaven-infra-queue-bot[bot]@users.noreply.github.com","GIT_COMMITTER_NAME":"faultmaven-infra-queue-bot[bot]","GIT_COMMITTER_EMAIL":"faultmaven-infra-queue-bot[bot]@users.noreply.github.com"}'
expect "the update step binds exactly this env map, names and values" \
    '[[ "$(yq -o=json -I0 "$upd | .env" "$ACTION")" == "$WANT_ENV" ]]' "$(yq -o=json -I0 "$upd | .env" "$ACTION")"
expect "the commit identity action.yml binds is the one this harness exports" \
    '[[ "$(yq "$upd | .env.GIT_AUTHOR_NAME" "$ACTION")" == "$GIT_AUTHOR_NAME" && "$(yq "$upd | .env.GIT_COMMITTER_EMAIL" "$ACTION")" == "$GIT_COMMITTER_EMAIL" ]]' "$(yq "$upd | .env" "$ACTION")"
# The push relies on the checkout's persisted credentials, so its with: keys
# are exactly these four (no persist-credentials: false).
expect "the checkout's with: keys are exactly repository, ref, token and path" \
    '[[ "$(yq -n "$co | keys | sort | join(\",\")")" == "path,ref,repository,token" ]]' "$co"
# GitHub refuses to load a composite action whose run step has no shell, and
# actionlint does not lint action metadata.
expect "every run step of the action declares shell: bash" \
    '[[ "$(yq "[.runs.steps[] | select(has(\"run\")) | select(.shell != \"bash\")] | length" "$ACTION")" == 0 && "$(yq "[.runs.steps[] | select(has(\"run\"))] | length" "$ACTION")" == 2 ]]' "$(yq ".runs.steps" "$ACTION")"
expect "yq is installed by install-yq.sh, in the same form, before the update" \
    '[[ "$(yq ".runs.steps[1].run" "$ACTION")" == "bash --noprofile --norc -eo pipefail \"\$GITHUB_ACTION_PATH/install-yq.sh\"" && "$(yq ".runs.steps[2].name" "$ACTION")" == "Update and push the queue file" ]]' "$(yq ".runs.steps" "$ACTION")"

echo ""
echo "update-image-queue: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
