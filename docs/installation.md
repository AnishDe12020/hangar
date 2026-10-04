# Installation and updates

Keep the complete extracted folder together. From Terminal inside it:

```sh
bash install.command --help
bash install.command --check     # dependencies must already be installed
bash install.command            # install missing dependencies and activate
```

Homebrew is installed separately from its official website. Apple's Command Line Tools provide Swift; Python must be 3.11 or newer. AeroSpace comes from `nikitabobko/tap/aerospace`. LeanMac also uses Hammerspoon, Shottr, and Thaw.

`--check` compiles and ad-hoc signs three native helpers, runs their available self-tests, and validates Lua and TOML without writing installation state, replacing configuration, or installing dependencies. AeroSpace's semantic validation needs its active configuration path and runs during guarded activation. A successful staging check is not proof that OS permissions or live shortcuts work.

`--configs-only` activates configs and helpers using the installed dependencies. It skips Shottr/Thaw preference changes and their login agents. Use it for updates when you want to keep those app preferences.

## Files and settings

Installation replaces LeanMac's modules under `~/.hammerspoon`, compiles helpers under `~/.hammerspoon/bin`, and installs `~/.aerospace.toml`. It adds `leanmac = require("leanmac")` to `~/.hammerspoon/init.lua` while preserving other text. Custom shortcuts can still conflict; review existing Hammerspoon modules before installing.

The CLI is copied into `~/.local/bin/leanmac` with its Python module in `~/.local/lib/leanmac`. Add `~/.local/bin` to your shell's PATH, or use the complete path shown in the README. LeanMac does not edit shell startup files.

Backups and the local profile selector live under `~/Library/Application Support/LeanMac`. The installer backs up a second XDG AeroSpace config and removes that duplicate during activation so there is one active config. Symlinks are recorded for rollback.

A full install additionally seeds Shottr/Thaw preferences, changes the macOS area-screenshot shortcut to avoid Shottr's shortcut, and adds per-user Shottr/Thaw login agents. AeroSpace and Hammerspoon are configured to start at login. Existing app licenses, accounts, browser data, mouse settings, and unrelated applications are not migrated by the kit.

## First-run permissions

Grant Accessibility to AeroSpace and Hammerspoon before expecting switching, snapping, or pairing to work. Thaw needs Accessibility and screen recording; Shottr needs screen recording. Follow macOS prompts and restart apps if requested. These permissions are per-Mac and cannot be imported from a backup or profile.

If activation fails on a fresh Mac, it restores the configuration snapshot. Grant permissions to the installed apps, then run the installer again. Read the reported backup path if recovery itself fails.

## Updates outside iCloud

Extract a new release or update your clone, inspect changes, then run its `install.command`. `leanmac install --kit /path/to/LeanMac --check` accepts an explicit source kit. The CLI can also reuse the previous transaction's source location while that folder exists; it never requires a particular cloud account or iCloud path. Keep the new folder through validation and rollback.

Dotfiles managers should delegate to this installer. Do not separately symlink or template AeroSpace/Hammerspoon files: that creates conflicting ownership and weakens rollback. Shell configuration and terminal/editor settings can remain owned by dotfiles.
