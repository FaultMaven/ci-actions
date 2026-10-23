#!/bin/bash
# Downloads actionlint ACTIONLINT_VERSION, verifies it against ACTIONLINT_SHA256,
# and runs it over the workflows of the repository in the current directory.
# A checksum mismatch stops before anything runs. linux/amd64 only.
# Environment, bound by action.yml: ACTIONLINT_VERSION, ACTIONLINT_SHA256,
# SHELLCHECK_OPTS.
set -euo pipefail
dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/actionlint.XXXXXX")"
tgz="$dir/actionlint.tar.gz"
curl -fsSL -o "$tgz" "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
echo "${ACTIONLINT_SHA256}  ${tgz}" | sha256sum -c -
tar -xzf "$tgz" -C "$dir" actionlint
"$dir/actionlint" -version
"$dir/actionlint" -color
