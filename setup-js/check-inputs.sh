#!/bin/bash
# Refuses an input setup-js cannot honour, before anything is set up.
# Environment, bound by action.yml: WANT_PNPM, WANT_INSTALL.
for input in pnpm install; do
  var="WANT_${input^^}"
  case "${!var:-}" in
    true | false) ;;
    *)
      echo "::error::setup-js: ${input} must be 'true' or 'false', not '${!var:-}'"
      exit 1
      ;;
  esac
done
if [ "$WANT_INSTALL" = true ] && [ "$WANT_PNPM" = false ]; then
  echo "::error::setup-js: install: true needs pnpm: true"
  exit 1
fi
