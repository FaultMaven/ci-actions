#!/bin/bash
# Records SERVICE_NAME's image sha-<first 7 of RUN_SHA>, built from RUN_SHA, on
# faultmaven-enterprise-infra's image-queue branch. Run inside a checkout of
# that branch.
#
# The queue only moves forward. An entry is replaced only when RUN_SHA
# contains the queued commit; the same or an older commit is skipped; a
# diverged commit, an entry no commit can be read from, or a missing queue
# file fails the step; an unanswered compare is retried and never written, but
# one GitHub refuses (403 for a token without contents: read, or 404) fails
# at once with its cause; a push rejected by a race (another writer moved image-queue before or during
# the push) re-reads origin's entry and decides again; any other push failure
# fails, "not as a race". Every refusal of the queue's state ends "GHCR holds
# <tag> but the queue does not name it." (an invalid input exits before that).
#
# action.yml runs this as `bash --noprofile --norc -eo pipefail update.sh`,
# the form GitHub gives a `run:` step under `shell: bash`, so `-e` is on from
# the first line.
# tests/test-update-image-queue.sh runs it the same way.
#
# Environment, bound by action.yml: SERVICE_NAME, RUN_SHA, REPO, GH_TOKEN,
# TRIGGERED_BY, WORKFLOW_NAME, GIT_AUTHOR_*/GIT_COMMITTER_*,
# GITHUB_STEP_SUMMARY. The tag is always sha-<first 7 of RUN_SHA>: the rule
# orders an entry by its commit, and refuses one whose tag names another.

# The inputs become a path, a commit message and annotations, so each is
# checked before anything is read or written, and none is echoed back raw.
if ! [[ ${SERVICE_NAME:-} =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
  echo "::error::the service input is not a queue file name (a-z, 0-9 and -, at most 63 characters)"
  exit 1
fi
if ! [[ ${RUN_SHA:-} =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::the sha input is not a full 40-character lower-case commit sha"
  exit 1
fi

QUEUE_FILE="available-images/staging/${SERVICE_NAME}.yaml"
TAG="sha-${RUN_SHA:0:7}"
COMMIT_MSG="chore(queue): update ${SERVICE_NAME} image to ${TAG}

Built from: ${REPO}@${RUN_SHA}
Triggered by: @${TRIGGERED_BY}
Workflow: ${WORKFLOW_NAME}"
GHCR="GHCR holds ${TAG} but the queue does not name it."
HEX='^[0-9a-fA-F]{7,40}$'
SHA_TAG='^sha-([0-9a-fA-F]{7,40})$'
RACE='^ ! \[rejected\] .*\((fetch first|non-fast-forward)\)'
RACE_LOCK='^ ! \[remote rejected\] .*\((incorrect old value provided|cannot lock ref[^)]*|failed to update ref)\)'
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

# Output helpers, shared with move-branch-tags: ../lib/annotate.sh (#8). A
# script that cannot load them still says what the run leaves behind.
# shellcheck source=SCRIPTDIR/../lib/annotate.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/annotate.sh" || {
  echo "::error::update-image-queue cannot load ../lib/annotate.sh. ${GHCR}"
  exit 1
}
# The line of a failed push that says why, trimmed: the first " ! "
# status line, else the first "remote: " line with text after the
# prefix, else the first "fatal: " or "error: " line, else the first
# non-blank line.
push_err() { # file
  local line
  line="$(awk '/^ ! / { print; exit }' "$1")"
  [ -n "$line" ] || line="$(awk '/^remote: *[^ \t\r]/ { print; exit }' "$1")"
  [ -n "$line" ] || line="$(awk '/^(fatal|error): / { print; exit }' "$1")"
  [ -n "$line" ] || line="$(first_err "$1")"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

# Sets DECISION (write, skip, refuse or retry), REASON and DETAIL from
# the queue entry as it stands, and Q to the commit it names.
decide() {
  local rc status sha tag err
  DECISION=""
  REASON=""
  DETAIL=""
  Q=""
  # select(. != null), not // "": yq's // also replaces false, which
  # would read a boolean entry as unseeded.
  if ! sha="$(yq '.commit_sha | select(. != null)' "$QUEUE_FILE" 2>"$ERR")" ||
     ! tag="$(yq '.tag | select(. != null)' "$QUEUE_FILE" 2>"$ERR")"; then
    DECISION="retry"
    REASON="could not read ${QUEUE_FILE}: $(first_err "$ERR")"
    return 0
  fi
  DETAIL="${QUEUE_FILE} has tag '${tag}' and commit_sha '${sha}'"
  if [ -z "$sha" ] && [ -z "$tag" ]; then
    DECISION="write"   # unseeded: nothing to order against
    return 0
  fi
  if [ -n "$sha" ]; then
    if ! [[ $sha =~ $HEX ]]; then
      DECISION="refuse"
      REASON="the queued commit_sha is not a commit sha"
      return 0
    fi
    # They agree when either hex is a case-insensitive prefix of the other.
    if [ -n "$tag" ] && { ! [[ $tag =~ $SHA_TAG ]] ||
         [[ ${sha,,} != "${BASH_REMATCH[1],,}"* && ${BASH_REMATCH[1],,} != "${sha,,}"* ]]; }; then
      DECISION="refuse"
      REASON="the queued tag and commit_sha name different commits"
      return 0
    fi
    Q="$sha"
  elif [[ $tag =~ $SHA_TAG ]]; then
    Q="${BASH_REMATCH[1]}"
  else
    DECISION="refuse"
    REASON="the queue entry names no commit this rule can order"
    return 0
  fi
  if [ "$Q" = "$RUN_SHA" ]; then
    DECISION="skip"
    REASON="the queue already names this commit"
    return 0
  fi
  # gh's rc is read before its answer: a 404 prints its JSON body on
  # stdout. per_page=1: only .status is read, not the commit list.
  rc=0
  status="$(gh api "repos/${REPO}/compare/${Q}...${RUN_SHA}?per_page=1" --jq .status 2>"$ERR")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Two refusals are not transient, so they are not retried (#5). A token
    # without `contents: read` gets 403 "Resource not accessible by
    # integration" (observed in a private repository); a commit the
    # repository does not hold, or a repository the token cannot see, gets
    # 404. Any other failure, a 403 rate limit included, is retried.
    err="$(first_err "$ERR")"
    case "$err" in
      *"Resource not accessible by integration"*"(HTTP 403)")
        DECISION="refuse"
        REASON="github-token cannot read ${REPO}'s commits (the compare ${Q}...${RUN_SHA} answered '${err}'): the calling job needs permissions: contents: read"
        DETAIL=""
        ;;
      *"(HTTP 404)")
        DECISION="refuse"
        REASON="the compare ${Q}...${RUN_SHA} answered '${err}': one of them is not a commit of ${REPO} (a rewritten history?), or github-token cannot see ${REPO}"
        ;;
      *)
        DECISION="retry"
        REASON="the compare ${Q}...${RUN_SHA} failed: ${err}"
        ;;
    esac
    return 0
  fi
  case "$status" in
    ahead)     DECISION="write" ;;
    identical) DECISION="skip";   REASON="the queued ${Q} is this commit" ;;
    behind)    DECISION="skip";   REASON="this run's commit is older than the queued ${Q}" ;;
    diverged)  DECISION="refuse"; REASON="neither commit contains the other"
               DETAIL="${QUEUE_FILE} names ${Q} and this run is ${RUN_SHA}" ;;
    *)         DECISION="retry";  REASON="the compare ${Q}...${RUN_SHA} answered '${status}'" ;;
  esac
}

for attempt in 1 2 3; do
  if [ "$attempt" -gt 1 ] && ! { git fetch -q origin image-queue && git reset -q --hard FETCH_HEAD; }; then
    REASON="could not re-read origin/image-queue"
    annotate warning "${REASON} (attempt ${attempt}/3)"
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * 2)); fi
    continue
  fi
  # Not transient, so not retried.
  if [ ! -f "$QUEUE_FILE" ]; then
    annotate error "Queue file not found: ${QUEUE_FILE} on image-queue - register the service first. ${GHCR}"
    exit 1
  fi
  decide
  case "$DECISION" in
    skip)
      annotate notice "${REASON}; the queue keeps ${Q} in ${QUEUE_FILE}"
      {
        echo "## Image queue"
        echo ""
        printf '%s\n' "$(flat "\`${QUEUE_FILE}\` is unchanged: ${REASON}. It keeps \`${Q}\`; this run is \`${RUN_SHA}\`.")"
      } >> "$GITHUB_STEP_SUMMARY"
      exit 0
      ;;
    refuse)
      annotate error "${REASON}${DETAIL:+: ${DETAIL}}. The queue is left as it is. ${GHCR}"
      exit 1
      ;;
    retry)
      annotate warning "${REASON} (attempt ${attempt}/3)"
      if [ "$attempt" -lt 3 ]; then sleep $((attempt * 2)); fi
      ;;
    write)
      echo "Updating ${QUEUE_FILE} to ${TAG}"
      if ! { yq -i ".tag = \"${TAG}\"" "$QUEUE_FILE" &&
             yq -i ".updated_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$QUEUE_FILE" &&
             yq -i ".commit_sha = \"${RUN_SHA}\"" "$QUEUE_FILE" &&
             git add "$QUEUE_FILE" &&
             git commit -q -m "$COMMIT_MSG"; }; then
        annotate error "could not write ${QUEUE_FILE} in the checkout. ${GHCR}"
        exit 1
      fi
      rc=0
      git push origin image-queue 2>"$ERR" || rc=$?
      log_tool_output "git push" "$ERR"
      if [ "$rc" -eq 0 ]; then
        echo "✓ Updated image queue: ${TAG}"
        {
          echo "## Image queue updated"
          echo ""
          printf '%s\n' "$(flat "- Tag: \`${TAG}\`")"
          printf '%s\n' "$(flat "- File: \`${QUEUE_FILE}\`")"
          echo ""
          echo "This records that the image exists. It does **not** deploy it:"
          echo "deployment is enterprise-infra's \`promote-images.yaml\`"
          echo "(manual dispatch), then merging the PR it opens."
        } >> "$GITHUB_STEP_SUMMARY"
        exit 0
      fi
      if ! grep -Eq -e "$RACE" -e "$RACE_LOCK" "$ERR"; then
        annotate error "the push to image-queue failed, not as a race: $(push_err "$ERR"). ${GHCR}"
        exit 1
      fi
      REASON="the push to image-queue was rejected"
      annotate warning "push rejected; recomputing against origin/image-queue (attempt ${attempt}/3)"
      ;;
  esac
done
annotate error "could not update the queue after 3 attempts: ${REASON}. ${GHCR}"
exit 1
