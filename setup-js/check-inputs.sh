#!/bin/bash
# Refuses an input setup-js cannot honour, before anything is set up.
# Environment, bound by action.yml: WANT_PNPM, WANT_INSTALL.
for name in WANT_PNPM WANT_INSTALL; do
  case "${!name:-}" in
    true | false) ;;
    *)
      echo "::error::setup-js: ${name#WANT_} must be 'true' or 'false'"
      exit 1
      ;;
  esac
done
if [ "$WANT_INSTALL" = true ] && [ "$WANT_PNPM" = false ]; then
  echo "::error::setup-js: install: true needs pnpm: true"
  exit 1
fi
