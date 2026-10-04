#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
configs_only=false
check_only=false
for arg in "$@"; do
  case "$arg" in
    --configs-only) configs_only=true ;;
    --check) check_only=true ;;
    --help|-h)
      cat <<'HELP'
Usage: bash install.command [--configs-only] [--check]

  --configs-only  Use installed dependencies; update configs and native helpers.
  --check         Compile and validate only; no dependency install or activation.
  --help          Show this help without changing anything.

A full install adds missing Homebrew dependencies and configures Shottr/Thaw.
Read README.md and docs/installation.md before activating on a new Mac.
HELP
      exit 0 ;;
    *) echo "Unknown option: $arg. Use --help." >&2; exit 2 ;;
  esac
done
if "$check_only"; then
  exec /bin/bash ./bin/hangar install --kit "$PWD" --check
fi
if "$configs_only"; then
  exec /bin/bash ./bin/hangar install --kit "$PWD"
fi
if ! command -v brew >/dev/null; then
  echo 'Install Homebrew from https://brew.sh, then run this again.' >&2
  exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
if ! python3 -c 'import tomllib' 2>/dev/null; then brew install python; fi
for cask in hammerspoon nikitabobko/tap/aerospace shottr thaw; do
  brew list --cask "${cask##*/}" >/dev/null 2>&1 || brew install --cask "$cask"
done
exec /bin/bash ./bin/hangar install --kit "$PWD" --extras
