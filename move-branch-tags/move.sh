#!/bin/bash
# Points IMAGE's branch tag, and `latest` for main, at IMAGE@DIGEST, but only
# while RUN_SHA is still the tip of TAG_REF's branch
# (FaultMaven/faultmaven#2347). Run it after the image is pushed, in the job
# that is logged in to the registry, with docker buildx on PATH.
#
# Read at job start, the tip goes stale while the image builds: a newer
# commit's publish can move the tags in that time, and this build's push then
# moves them back to an older commit. Read here, immediately before the move,
# only the seconds this script takes are left. A registry offers no
# compare-and-set on a tag, so nothing closes that gap entirely. The rule is
# the tip's: while the tip never publishes (its CI failed or was skipped), the
# tags stay on the last tip that did.
#
# Moving never fails the step. The tags are informational, since deploys pin
# sha- tags through the image queue, and a red publish invites a re-run, which
# pushes the queued sha- tag again under a new digest. A failed lookup or push
# is retried (three attempts, each re-reading the tip, each bounded by a
# timeout), then left with a warning. Only an invalid input fails the step: it
# is a wiring error, which no re-run fixes, and passing would leave the tags
# frozen without a sign.
#
# Every outcome writes moved=true|false and reason=<why> to GITHUB_OUTPUT:
#   moved          the tags now name DIGEST
#   not-tip        the branch has moved on (::notice::)
#   not-branch     TAG_REF is not a branch (::notice::)
#   branch-name    the branch name makes no tag, or git would refuse it (::warning::)
#   lookup-failed  the tip could not be read (::warning::)
#   push-failed    imagetools failed; one of the tags may have moved (::warning::)
#   invalid        an input is invalid (::error::, the step fails)
#   stopped        a command failed unexpectedly (::warning::)
#
# action.yml runs this as `bash --noprofile --norc -eo pipefail move.sh`, the
# form GitHub gives a `run:` step under `shell: bash`, so `-e` is on from the
# first line. tests/test-move-branch-tags.sh runs it the same way.
#
# Environment, bound by action.yml: IMAGE, DIGEST, RUN_SHA, TAG_REF, REPO,
# GH_TOKEN, GITHUB_OUTPUT. LOOKUP_TIMEOUT and PUSH_TIMEOUT (seconds; 30 and
# 120) are set only by the tests.

moved=false
reason=""
invalid=false
UNMOVED="latest and the branch tag were not moved"

# Every exit ends here, the planned ones and any other. -e is off inside, so
# a failure here (a closed stdout, an unwritable output file) cannot turn the
# step red or skip the outputs. It is installed before the library is loaded,
# and does not need it.
finish() {
  local rc=$?
  set +e
  # Its own messages are fixed text and a number: nothing to escape, if the
  # library never loaded.
  declare -F annotate >/dev/null || annotate() { printf '::%s::%s\n' "$1" "$2"; }
  if [ "$invalid" = true ]; then
    rc=1
  elif [ "$rc" -ne 0 ]; then
    if [ "$moved" = true ]; then
      annotate warning "move-branch-tags stopped (rc ${rc}) after it moved the tags"
    else
      reason=stopped
      annotate warning "move-branch-tags stopped (rc ${rc}): ${UNMOVED}"
    fi
    rc=0
  fi
  [ -n "${ERR:-}" ] && rm -f "$ERR"
  printf 'moved=%s\nreason=%s\n' "$moved" "${reason:-stopped}" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null
  exit "$rc"
}
trap finish EXIT

# Output helpers, shared with update-image-queue: ../lib/annotate.sh (#8).
# shellcheck source=SCRIPTDIR/../lib/annotate.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/annotate.sh" || {
  reason=stopped
  printf '::warning::%s\n' "move-branch-tags cannot load ../lib/annotate.sh: ${UNMOVED}"
  exit 0
}

ERR="$(mktemp)"
refuse() {
  invalid=true
  reason=invalid
  annotate error "$1: ${UNMOVED}"
  exit 1
}

# The inputs become an API path, image references and annotations, so each is
# checked before anything is called, and none is echoed back raw.
[[ ${RUN_SHA:-} =~ ^[0-9a-f]{40}$ ]] \
  || refuse "the sha input is not a full 40-character lower-case commit sha"
[[ ${DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] \
  || refuse "the digest input is not a pushed image's digest (sha256:<64 hex>)"
# metadata-action writes the image name lowercased. A registry host is
# case-insensitive and a repository path must be lowercase, so a caller may
# pass github.repository_owner as it is.
IMAGE="${IMAGE:-}"
IMAGE="${IMAGE,,}"
[[ $IMAGE =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)+$ ]] \
  || refuse "the image input is not an image repository such as ghcr.io/owner/name (no tag, no digest)"
[[ ${REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || refuse "the repository is not owner/name"
LOOKUP_TIMEOUT="${LOOKUP_TIMEOUT:-30}"
PUSH_TIMEOUT="${PUSH_TIMEOUT:-120}"

case "${TAG_REF:-}" in
  refs/heads/?*) BRANCH="${TAG_REF#refs/heads/}" ;;
  *)
    reason=not-branch
    annotate notice "${TAG_REF:-the empty ref} is not a branch, so no branch tag or latest follows it"
    exit 0
    ;;
esac
# The branch name goes into an API path, so a segment git refuses (empty, or
# starting with `.`, as `..` does) is refused here too: with one, the path
# could leave heads/.
if [[ /$BRANCH/ == *//* || /$BRANCH == */.* ]]; then
  reason=branch-name
  annotate warning "the branch name has an empty segment or one starting with a dot, which git does not allow: ${UNMOVED}"
  exit 0
fi
# Each segment percent-encoded, keeping only what RFC 3986 leaves as it is
# (A-Z a-z 0-9 - . _ ~) and the slashes between segments, so any name git
# allows is looked up as written: fix+retry is heads/fix%2Bretry. LC_ALL=C
# makes each byte one character, so a non-ASCII letter goes as its UTF-8.
encode_branch() {
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~/-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}
BRANCH_PATH="$(encode_branch "$BRANCH")"
# The branch tag, named as metadata-action's type=ref,event=branch names it:
# each run of characters outside a-z A-Z 0-9 . _ - becomes one -, so feat/x
# is :feat-x and fix+retry is :fix-retry. A non-ASCII letter becomes - too,
# in any locale: bash's globasciiranges, on by default since bash 5.0, matches
# a range such as a-z by code point.
shopt -s extglob
TAG="${BRANCH//+([^a-zA-Z0-9._-])/-}"
# What metadata-action would hand on and the registry refuse: a tag starts
# with a letter, a digit or _, and has at most 128 characters.
why=""
if [[ $TAG == [.-]* ]]; then
  why="it starts with ${TAG:0:1}"
elif [ "${#TAG}" -gt 128 ]; then
  why="it has ${#TAG} characters, and a tag has at most 128"
fi
if [ -n "$why" ]; then
  reason=branch-name
  annotate warning "the branch name makes no tag: ${why}: ${UNMOVED}"
  exit 0
fi
args=(--tag "${IMAGE}:${TAG}")
LATEST=false
if [ "$TAG_REF" = refs/heads/main ]; then
  LATEST=true
  args+=(--tag "${IMAGE}:latest")
fi

# Up to three attempts. Each re-reads the tip, so a retry never moves the
# tags to a commit that has stopped being the tip.
attempt=1
while :; do
  rc=0
  # gh's rc is read before its answer: a 404 prints its JSON body on stdout.
  TIP="$(timeout "$LOOKUP_TIMEOUT" gh api "repos/${REPO}/git/ref/heads/${BRANCH_PATH}" --jq .object.sha 2>"$ERR")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    why="$(first_err "$ERR")"
    [ "$rc" -eq 124 ] && why="timed out after ${LOOKUP_TIMEOUT}s"
    if [ "$attempt" -lt 3 ]; then
      echo "Reading ${BRANCH}'s tip failed (attempt ${attempt}/3): $(flat "$why")" >&2
      sleep $((attempt * 2))
      attempt=$((attempt + 1))
      continue
    fi
    reason=lookup-failed
    annotate warning "could not read ${BRANCH}'s tip after 3 attempts: ${why}: ${UNMOVED}"
    exit 0
  fi
  if [ "$TIP" != "$RUN_SHA" ]; then
    reason=not-tip
    annotate notice "${BRANCH} is at ${TIP:-nothing}, not ${RUN_SHA}: ${UNMOVED}"
    exit 0
  fi

  # Without --prefer-index=false, a single-manifest source (a build with no
  # attestation) is wrapped in a new index under a new digest.
  rc=0
  timeout "$PUSH_TIMEOUT" docker buildx imagetools create --prefer-index=false "${args[@]}" "${IMAGE}@${DIGEST}" 2>"$ERR" || rc=$?
  log_tool_output imagetools "$ERR" || true
  if [ "$rc" -eq 0 ]; then
    moved=true
    reason=moved
    break
  fi
  why="$(last_err "$ERR")"
  [ "$rc" -eq 124 ] && why="timed out after ${PUSH_TIMEOUT}s"
  if [ "$attempt" -lt 3 ]; then
    echo "Moving the tags failed (attempt ${attempt}/3): $(flat "$why")" >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
    continue
  fi
  reason=push-failed
  annotate warning "could not move the tags after 3 attempts: ${why}: imagetools pushes one tag at a time, so one may already name ${DIGEST}"
  exit 0
done

if [ "$LATEST" = true ]; then
  echo "Moved ${IMAGE}:${TAG} and ${IMAGE}:latest to ${DIGEST}: ${RUN_SHA} is ${BRANCH}'s tip."
else
  echo "Moved ${IMAGE}:${TAG} to ${DIGEST}: ${RUN_SHA} is ${BRANCH}'s tip."
fi
