#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ "${1:-}" = '--configs-only' ]; then
  shift
  exec /bin/bash ./bin/leanmac install --kit "$PWD" "$@"
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
exec /bin/bash ./bin/leanmac install --kit "$PWD" --extras "$@"
