# Installation and updates

Keep the complete extracted folder together. From Terminal inside it:

```sh
bash install.command --help
bash install.command --check     # dependencies must already be installed
bash install.command            # install missing dependencies and activate
```

Homebrew is installed separately from its official website. Apple's Command Line Tools provide Swift; Python must be 3.11 or newer. AeroSpace comes from `nikitabobko/tap/aerospace`. Hangar also uses Hammerspoon, Shottr, and Thaw.

`--check` compiles and ad-hoc signs three native helpers, runs their available self-tests, and validates Lua and TOML without writing installation state, replacing configuration, or installing dependencies. AeroSpace's semantic validation needs its active configuration path and runs during guarded activation. A successful staging check is not proof that OS permissions or live shortcuts work.

`--configs-only` activates configs and helpers using the installed dependencies. It skips Shottr/Thaw preference changes and their login agents. Use it for updates when you want to keep those app preferences.

## Files and settings

Installation replaces Hangar's modules under `~/.hammerspoon`, compiles helpers under `~/.hammerspoon/bin`, and installs `~/.aerospace.toml`. It adds `leanmac = require("leanmac")` to `~/.hammerspoon/init.lua` while preserving other text. Custom shortcuts can still conflict; review existing Hammerspoon modules before installing.

The primary CLI is copied into `~/.local/bin/hangar`; `~/.local/bin/leanmac` remains a compatibility alias using the same Python module in `~/.local/lib/leanmac`. Add `~/.local/bin` to your shell's PATH, or use the complete path shown in the README. Hangar does not edit shell startup files.

Backups and the local profile selector live under `~/Library/Application Support/LeanMac`. The installer backs up a second XDG AeroSpace config and removes that duplicate during activation so there is one active config. Symlinks are recorded for rollback.

A full install additionally seeds Shottr/Thaw preferences, changes the macOS area-screenshot shortcut to avoid Shottr's shortcut, and adds per-user Shottr/Thaw login agents. AeroSpace and Hammerspoon are configured to start at login. Existing app licenses, accounts, browser data, mouse settings, and unrelated applications are not migrated by the kit.

## First-run permissions

Grant Accessibility to AeroSpace and Hammerspoon before expecting switching, snapping, or pairing to work. Thaw needs Accessibility and screen recording; Shottr needs screen recording. Follow macOS prompts and restart apps if requested. These permissions are per-Mac and cannot be imported from a backup or profile.

If activation fails on a fresh Mac, it restores the configuration snapshot. Grant permissions to the installed apps, then run the installer again. Read the reported backup path if recovery itself fails.

## Updates outside iCloud

Extract a new release or update your clone, inspect changes, then run its `install.command`. `hangar install --kit /path/to/Hangar --check` accepts an explicit source kit. The CLI can also reuse the previous transaction's source location while that folder exists; it never requires a particular cloud account or iCloud path. Keep the new folder through validation and rollback.

Dotfiles managers should delegate to this installer. Do not separately symlink or template AeroSpace/Hammerspoon files: that creates conflicting ownership and weakens rollback. Shell configuration and terminal/editor settings can remain owned by dotfiles.


## Upgrading from LeanMac

Hangar is the new product and repository name. Existing installations upgrade in place:

1. Keep your current kit and backups. If you use custom routing, copy your original profile to `~/.config/hangar/aerospace.toml` as described in [profiles](profiles.md).
2. From the extracted Hangar kit, run `bash install.command --check` and then `bash install.command --configs-only` to update configuration/helpers without changing Shottr/Thaw preferences.
3. Use `hangar doctor` and `hangar backups`. Your existing profile selector and transactional backups remain available. Without settings files, Ghostty/Brave launcher defaults are retained; `config init` deliberately switches defaults to Terminal/Safari. Existing `leanmac` commands also work.

**One stable storage namespace:** both new and upgraded installs use `~/Library/Application Support/LeanMac`. Hangar intentionally retains the internal `leanmac` Lua global/module names, linked-pair settings, helper file/bundle identifiers, launch-agent identifiers, and `.local/lib/leanmac` location. These are compatibility identifiers, not a second installation. Do not rename or delete them manually, and do not create a separate Hangar state folder.

Each upgrade backs up the old CLI/core along with managed configuration, including whether `hangar` existed. Rolling back that upgrade restores the prior LeanMac files and removes the newly added `hangar` command if it was absent before. Use the restored `leanmac` command, or `bash bin/hangar rollback BACKUP_NAME` from the retained kit. Older historical backups remain accepted; when they restore an older CLI/core, any surviving `hangar` alias uses that older core. A snapshot that predates the CLI may require the retained kit for subsequent commands.

No backup files are copied or rewritten just for the name change. Existing Hammerspoon initialization is detected, so upgrading does not add a duplicate `require("leanmac")` line.

Configuration apply and normal kit updates read the same persistent input directory. They compile settings into `~/.hammerspoon/hangar-settings.lua` alongside the active configuration. Source TOML and host overrides are never overwritten by installation or rollback. Rolling back restores active copies; revert the source Git change separately before applying again.
