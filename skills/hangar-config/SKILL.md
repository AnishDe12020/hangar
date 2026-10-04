---
name: hangar-config
description: Configure Hangar macOS workspaces, application routing, launchers and shortcuts, including settings managed in a dotfiles repository. Use for Hangar configuration and cross-Mac preference sync; not general shell setup or app installation.
---

# Configure Hangar

Edit the user's configuration inputs, then validate them through Hangar. Do not
edit installed Hammerspoon modules or `~/.aerospace.toml`: installation replaces
those generated copies. Existing LeanMac state/helper names are intentional
compatibility identifiers; do not rename them.

## Find the source

Run `hangar config show --json` (or `/path/to/Hangar/bin/hangar` before installation).
It reports effective settings and source paths. Add `--kit /path/to/Hangar` if the
previous source folder moved. Inputs normally live under
`${XDG_CONFIG_HOME:-$HOME/.config}/hangar`:

- `settings.toml`: shared profile, application launchers and supported hotkeys.
- `settings.local.toml`: per-Mac overrides; keep it out of Git/cloud sync.
- `aerospace.toml`: optional complete AeroSpace profile for custom workspace
  routing, gaps and monitor roles. It overrides the kit's selected profile.

Resolve input symlinks before editing. If they point into a dotfiles checkout,
edit that source, inspect its Git status and preserve unrelated changes. When no
inputs exist, `hangar config init` creates editable defaults without activation
or overwriting existing settings. Existing legacy profiles stay available.

## Make the requested change

The settings schema is TOML, with `schema = 1`, an optional `profile`, `[apps]`
(`terminal`, `browser`, `finder`) and `[hotkeys]`. Get the current supported action
names and values from `config show --json`; unknown keys fail validation. Chords
use strings such as `ctrl-alt-cmd-return`, `alt-shift-p` or `f17`. Option+Tab and
Option+Shift+Tab are reserved for the hold/release picker. Do not change their
modifiers by patching Lua or Swift. Avoid collisions with AeroSpace bindings.

For a complete custom AeroSpace profile, preserve the existing user's profile or
copy the selected kit template first, then change only the requested rules. Keep
the template's required workspace/mouse navigation bindings and helper-window
rules. Prefer `main` and `['secondary', 'main']` monitor roles over display UUIDs
for shared configurations. Confirm application bundle IDs locally when adding
routes; do not infer them from display names. The kit's `docs/profiles.md` explains
supported behavior; use current AeroSpace documentation for unfamiliar syntax.

Use shared settings for preferences intended for every Mac and the local overlay
for host-only differences. Never place tokens, signing keys, Accessibility grants,
backup journals, compiled helpers or live window-pair state in shared inputs.

## Validate and apply

Run `hangar config check --kit /path/to/Hangar`. This checks configuration without
activating it. `hangar install --kit /path/to/Hangar --check` additionally compiles
and stages native helpers. Inspect the effective configuration and diff after
editing; validation is not proof of physical keyboard, pointer or display behavior.

When activation is within the user's request, run
`hangar config apply --kit /path/to/Hangar`, then `hangar doctor`. Otherwise leave
the validated edit ready to apply. An edit-only request does not imply permission
to reload the desktop. Use existing authorization rather than asking repeatedly.
If activation fails, report the actual error and transaction recovery result;
do not bypass validation or fall back to overwriting active files directly.

For another Mac, review/merge the shared Git changes there, validate and apply on
that Mac. Git updates source inputs; Hangar has no background sync or remote
activation. Dotfiles rollback restores its links; `hangar rollback` restores
active Hangar copies, not the source Git commit. Revert source changes separately
if they should not reappear on the next apply. Respect the user's existing
authorization for committing, pushing or messaging another machine/chat.
