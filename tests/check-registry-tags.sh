#!/bin/bash
# Used by ci.yml's move-branch-tags (registry) job, after each call of the
# action: the moved output is $1, and IMAGE's latest and main tags both name
# the digest $2. A tag's digest is the sha256 of its raw manifest.
# Environment: IMAGE, MOVED.
set -euo pipefail
want_moved="$1" want_digest="$2"
if [ "$MOVED" != "$want_moved" ]; then
  echo "::error::moved is '${MOVED}', not ${want_moved}"
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
