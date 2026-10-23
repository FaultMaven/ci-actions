#!/bin/bash
# lint-workflows: a download that fails its checksum never runs, and
# action.yml's wiring. The real run (actionlint over this repository's
# workflows) is CI's own Lint job, which calls ./lint-workflows.
#
# SAFETY: `curl` and `tar` are stubs; nothing is downloaded.
#
# Run: tests/test-lint-workflows.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ACTION="$REPO_ROOT/lint-workflows/action.yml"
SCRIPT="$REPO_ROOT/lint-workflows/lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          /'; }
expect() { # label, condition-text (evaluated), detail
    if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi
}
command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah v4) is required"; exit 1; }

BIN="$WORK/bin"; mkdir -p "$BIN"
# curl writes a tarball that is not actionlint's; tar logs that it ran.
cat > "$BIN/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK/curl.log"
while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf 'not actionlint\n' > "$2"; }; shift; done
CURL
cat > "$BIN/tar" <<'TAR'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK/tar.log"
TAR
chmod +x "$BIN/curl" "$BIN/tar"
for c in curl tar; do
    [ "$(PATH="$BIN:$PATH" command -v "$c")" = "$BIN/$c" ] || { echo "REFUSING TO RUN: $c is not the stub"; exit 1; }
done

echo "== a download that fails its checksum"
: > "$WORK/curl.log"; : > "$WORK/tar.log"
OUT="$(cd "$WORK" && env PATH="$BIN:$PATH" WORK="$WORK" RUNNER_TEMP="$WORK" ACTIONLINT_VERSION=1.7.7 \
    ACTIONLINT_SHA256="$(yq '.runs.steps[0].env.ACTIONLINT_SHA256' "$ACTION")" SHELLCHECK_OPTS='-S warning' \
    bash --noprofile --norc -eo pipefail "$SCRIPT" 2>&1)"; RC=$?
expect "it fails, after one download of the pinned release, and never extracts or runs it" \
    '[[ "$RC" -ne 0 && "$(grep -c . "$WORK/curl.log")" == 1 && ! -s "$WORK/tar.log" ]] && grep -qF "https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz" "$WORK/curl.log" && grep -q "FAILED" <<< "$OUT"' "rc=$RC out=$OUT tar=$(cat "$WORK/tar.log")"

echo "== action.yml"
# shellcheck disable=SC2016,SC2034  # the literal command line; read inside expect's eval
WANT_RUN='bash --noprofile --norc -eo pipefail "$GITHUB_ACTION_PATH/lint.sh"'
expect "one shell: bash step running lint.sh in GitHub's -eo pipefail form" \
    '[[ "$(yq ".runs.steps | length" "$ACTION")" == 1 && "$(yq ".runs.steps[0].shell" "$ACTION")" == bash && "$(yq ".runs.steps[0].run" "$ACTION")" == "$WANT_RUN" ]]' "$(yq ".runs" "$ACTION")"
expect "it pins actionlint 1.7.7 with a 64-hex checksum and shellcheck at -S warning" \
    '[[ "$(yq ".runs.steps[0].env.ACTIONLINT_VERSION" "$ACTION")" == 1.7.7 && "$(yq ".runs.steps[0].env.ACTIONLINT_SHA256" "$ACTION")" =~ ^[0-9a-f]{64}$ && "$(yq ".runs.steps[0].env.SHELLCHECK_OPTS" "$ACTION")" == "-S warning" ]]' "$(yq ".runs.steps[0].env" "$ACTION")"

echo ""
echo "lint-workflows: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
