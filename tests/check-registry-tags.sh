#!/bin/bash
# Used by ci.yml's move-branch-tags (registry) job, after each call of the
# action: the moved output is $1, the reason output is $2 (so a commit that is
# not the tip is shown to have reached the tip rule, not to have failed some
# other way), and IMAGE's latest and main tags both name the digest $3. A
# tag's digest is the sha256 of its raw manifest.
# Environment: IMAGE, MOVED, REASON.
set -euo pipefail
want_moved="$1" want_reason="$2" want_digest="$3"
if [ "$MOVED" != "$want_moved" ] || [ "$REASON" != "$want_reason" ]; then
  echo "::error::moved=${MOVED} reason=${REASON}, not moved=${want_moved} reason=${want_reason}"
  exit 1
fi
for tag in latest main; do
  got="sha256:$(docker buildx imagetools inspect --raw "${IMAGE}:${tag}" | sha256sum | cut -d' ' -f1)"
  if [ "$got" != "$want_digest" ]; then
    echo "::error::${IMAGE}:${tag} is ${got}, not ${want_digest}"
    exit 1
  fi
  echo "${IMAGE}:${tag} is ${want_digest}"
done
