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
# compare-and-set on a tag, so nothing closes that gap entirely.
#
# It never fails the step. The tags are informational, since deploys pin sha-
# tags through the image queue, and a red publish invites a re-run, which
# pushes the queued sha- tag again under a new digest. Every outcome exits 0
# and writes moved=true|false to GITHUB_OUTPUT. When nothing moved, an
# annotation says why: ::notice:: when that is the rule working (the branch
# has moved on, the ref is not a branch), ::warning:: when something failed
# (the tip lookup, the registry), ::error:: when an input is invalid.
#
# action.yml runs this as `bash --noprofile --norc -eo pipefail move.sh`, the
# form GitHub gives a `run:` step under `shell: bash`, so `-e` is on from the
# first line. tests/test-move-branch-tags.sh runs it the same way.
#
# Environment, bound by action.yml: IMAGE, DIGEST, RUN_SHA, TAG_REF, REPO,
# GH_TOKEN, GITHUB_OUTPUT.

moved=false

# Every value printed into a :: command goes through flat(): CR, LF and tab
# become spaces, so no value can start a line of its own.
flat() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}
annotate() {
  printf '::%s::%s\n' "$1" "$(flat "$2")"
}

# Every exit ends here, the planned ones and any other: the outcome is
# recorded, and the step passes.
finish() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    annotate warning "move-branch-tags stopped (rc ${rc}): latest and the branch tag were not moved"
  fi
  [ -n "${ERR:-}" ] && rm -f "$ERR"
  printf 'moved=%s\n' "$moved" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true
  exit 0
}
trap finish EXIT

ERR="$(mktemp)"
# The first non-blank stderr line of gh, without its "gh: " prefix: gh's later
# lines are hints, not the error.
first_err() {
  awk 'NF { sub(/^gh: /, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$ERR"
}
# The last non-blank stderr line of imagetools, which prints its progress
# before its error.
last_err() {
  awk 'NF { sub(/[ \t\r]+$/, ""); l = $0 } END { print l }' "$ERR"
}
UNMOVED="latest and the branch tag were not moved"

# The inputs become an API path, image references and annotations, so each is
# checked before anything is called, and none is echoed back raw.
if ! [[ ${RUN_SHA:-} =~ ^[0-9a-f]{40}$ ]]; then
  annotate error "the sha input is not a full 40-character lower-case commit sha: ${UNMOVED}"
  exit 0
fi
if ! [[ ${DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]]; then
  annotate error "the digest input is not a pushed image's digest (sha256:<64 hex>): ${UNMOVED}"
  exit 0
fi
# metadata-action writes the image name lowercased. A registry host is
# case-insensitive and a repository path must be lowercase, so a caller may
# pass github.repository_owner as it is.
IMAGE="${IMAGE:-}"
IMAGE="${IMAGE,,}"
if ! [[ $IMAGE =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)+$ ]]; then
  annotate error "the image input is not an image repository such as ghcr.io/owner/name (no tag, no digest): ${UNMOVED}"
  exit 0
fi
if ! [[ ${REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  annotate error "the repository is not owner/name: ${UNMOVED}"
  exit 0
fi

case "${TAG_REF:-}" in
  refs/heads/?*) BRANCH="${TAG_REF#refs/heads/}" ;;
  *)
    annotate notice "${TAG_REF:-the empty ref} is not a branch, so no branch tag or latest follows it"
    exit 0
    ;;
esac
# The branch name goes into an API path and a tag. Git allows characters that
# neither takes, and no FaultMaven branch uses them.
if ! [[ $BRANCH =~ ^[A-Za-z0-9._/-]+$ ]]; then
  annotate warning "the branch name has characters outside A-Z a-z 0-9 . _ / -: ${UNMOVED}"
  exit 0
fi
# The branch tag, named as metadata-action's type=ref,event=branch names it.
TAG="$(sed -E 's/[^a-zA-Z0-9._-]+/-/g' <<< "$BRANCH")"
LATEST=false
[ "$TAG_REF" = refs/heads/main ] && LATEST=true

# gh's rc is read before its answer: a 404 prints its JSON body on stdout.
if ! TIP="$(gh api "repos/${REPO}/git/ref/heads/${BRANCH}" --jq .object.sha 2>"$ERR")"; then
  annotate warning "could not read ${BRANCH}'s tip: $(first_err): ${UNMOVED}"
  exit 0
fi
if [ "$TIP" != "$RUN_SHA" ]; then
  annotate notice "${BRANCH} is at ${TIP:-nothing}, not ${RUN_SHA}: ${UNMOVED}"
  exit 0
fi

args=(--tag "${IMAGE}:${TAG}")
[ "$LATEST" = true ] && args+=(--tag "${IMAGE}:latest")
# Without --prefer-index=false, a single-manifest source (a build with no
# attestation) is wrapped in a new index under a new digest.
if ! docker buildx imagetools create --prefer-index=false "${args[@]}" "${IMAGE}@${DIGEST}" 2>"$ERR"; then
  cat "$ERR" >&2
  annotate warning "could not move the tags: $(last_err): ${UNMOVED}"
  exit 0
fi
cat "$ERR" >&2
moved=true
if [ "$LATEST" = true ]; then
  echo "Moved ${IMAGE}:${TAG} and ${IMAGE}:latest to ${DIGEST}: ${RUN_SHA} is ${BRANCH}'s tip."
else
  echo "Moved ${IMAGE}:${TAG} to ${DIGEST}: ${RUN_SHA} is ${BRANCH}'s tip."
fi
