#!/bin/bash
# Refuses an input setup-js cannot honour, before anything is set up.
# Environment, bound by action.yml: WANT_PNPM, WANT_INSTALL.

# Output helpers: ../lib/annotate.sh (#8). An input is printed into an
# annotation, so it is escaped there.
# shellcheck source=SCRIPTDIR/../lib/annotate.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/annotate.sh" || {
  echo "::error::setup-js cannot load ../lib/annotate.sh"
  exit 1
}
for input in pnpm install; do
  var="WANT_${input^^}"
  case "${!var:-}" in
    true | false) ;;
    *)
      annotate error "setup-js: ${input} must be 'true' or 'false', not '${!var:-}'"
      exit 1
      ;;
  esac
done
if [ "$WANT_INSTALL" = true ] && [ "$WANT_PNPM" = false ]; then
  echo "::error::setup-js: install: true needs pnpm: true"
  exit 1
fi
