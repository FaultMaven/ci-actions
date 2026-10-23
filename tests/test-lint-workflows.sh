#!/bin/bash
# lint-workflows: a download that fails its checksum never runs; a verified
# one runs once for its version and once over the workflows, with shellcheck at
# -S warning, and its exit status is the step's. Plus action.yml's wiring. The
# real run (actionlint over this repository's workflows) is CI's own Lint job,
# which calls ./lint-workflows.
#
# SAFETY: `curl` is a stub and `tar` a logging pass-through; nothing is
# downloaded, and the only actionlint that runs is this file's stand-in.
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

REAL_TAR="$(command -v tar)"
mkdir -p "$WORK/bin" "$WORK/fake" "$WORK/repo"
BIN="$WORK/bin"
# The stand-in actionlint logs where it ran, its arguments and SHELLCHECK_OPTS,
# answers -version, and otherwise exits FAKE_RC (1: it found problems).
cat > "$WORK/fake/actionlint" <<'FAKE'
#!/bin/bash
printf '%s|%s|%s\n' "$PWD" "$*" "${SHELLCHECK_OPTS-unset}" >> "$WORK/actionlint.log"
[ "$*" = -version ] && { echo 1.7.7; exit 0; }
exit "${FAKE_RC:-1}"
FAKE
chmod +x "$WORK/fake/actionlint"
"$REAL_TAR" -czf "$WORK/fake.tar.gz" -C "$WORK/fake" actionlint
FAKE_SHA256="$(sha256sum "$WORK/fake.tar.gz" | cut -d' ' -f1)"
# curl writes FAKE_TGZ, or, without one, a file that is not actionlint; tar
# logs that it ran, then extracts for real.
cat > "$BIN/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK/curl.log"
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then
        if [ -n "${FAKE_TGZ:-}" ]; then cp "$FAKE_TGZ" "$2"; else printf 'not actionlint\n' > "$2"; fi
    fi
    shift
done
CURL
cat > "$BIN/tar" <<TAR
#!/bin/bash
printf '%s\n' "\$*" >> "\$WORK/tar.log"
exec "$REAL_TAR" "\$@"
TAR
chmod +x "$BIN/curl" "$BIN/tar"
for c in curl tar; do
    [ "$(PATH="$BIN:$PATH" command -v "$c")" = "$BIN/$c" ] || { echo "REFUSING TO RUN: $c is not the stub"; exit 1; }
done

lint() { # ACTIONLINT_SHA256, then extra environment assignments
    local sha="$1"; shift
    : > "$WORK/curl.log"; : > "$WORK/tar.log"; : > "$WORK/actionlint.log"
    OUT="$(cd "$WORK/repo" && env PATH="$BIN:$PATH" WORK="$WORK" RUNNER_TEMP="$WORK" ACTIONLINT_VERSION=1.7.7 \
        ACTIONLINT_SHA256="$sha" SHELLCHECK_OPTS='-S warning' "$@" \
        bash --noprofile --norc -eo pipefail "$SCRIPT" 2>&1)"; RC=$?
}
# shellcheck disable=SC2034  # read inside expect's eval
URL="https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz"
# shellcheck disable=SC2034  # read inside expect's eval
WANT_RUNS="$WORK/repo|-version|-S warning
$WORK/repo|-color|-S warning"

echo "== a download that fails its checksum"
lint "$(yq '.runs.steps[0].env.ACTIONLINT_SHA256' "$ACTION")"
expect "it fails, after one download of the pinned release, and never extracts or runs it" \
    '[[ "$RC" -ne 0 && "$(cat "$WORK/curl.log")" == *"$URL"* && "$(grep -c . "$WORK/curl.log")" == 1 && ! -s "$WORK/tar.log" && ! -s "$WORK/actionlint.log" ]] && grep -q "FAILED" <<< "$OUT"' "rc=$RC out=$OUT tar=$(cat "$WORK/tar.log")"

echo "== a verified download"
lint "$FAKE_SHA256" FAKE_TGZ="$WORK/fake.tar.gz" FAKE_RC=1
expect "actionlint's findings fail the step, after one -version and one -color run over the repository, both with -S warning" \
    '[[ "$RC" -ne 0 && "$(cat "$WORK/actionlint.log")" == "$WANT_RUNS" && "$(grep -c . "$WORK/tar.log")" == 1 ]]' "rc=$RC out=$OUT runs=$(cat "$WORK/actionlint.log")"
lint "$FAKE_SHA256" FAKE_TGZ="$WORK/fake.tar.gz" FAKE_RC=0
expect "a clean actionlint passes the step, after the same two runs" \
    '[[ "$RC" -eq 0 && "$(cat "$WORK/actionlint.log")" == "$WANT_RUNS" ]]' "rc=$RC out=$OUT runs=$(cat "$WORK/actionlint.log")"

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
