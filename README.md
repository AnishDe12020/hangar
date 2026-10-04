# Hangar

A keyboard-first Mac workspace, with a native window picker, split pairs, an overview, and a searchable command palette. AeroSpace manages windows; Hammerspoon connects the shortcuts. Shottr and Thaw add screenshots and a second menu bar.

Hangar is a source kit. Install it from an extracted release folder or a clone anywhere on your Mac. Your active configuration is copied locally, so moving the download or going offline does not interrupt your window manager.

## Start here

You need macOS, [Homebrew](https://brew.sh), and Apple's Command Line Tools (`xcode-select --install`). The installer uses Python 3.11+ and compiles its native Swift helpers on your Mac. Helpers are ad-hoc signed locally; this is not a notarized application download.

Install the [2026.10.04.3 preview](https://github.com/AnishDe12020/hangar/releases/tag/v2026.10.04.3) with one command (no GitHub CLI or Hangar Homebrew formula needed):

```sh
(set -eu; d="$(mktemp -d "${TMPDIR:-/tmp}/hangar.XXXXXX")"; cd "$d"; r="https://github.com/AnishDe12020/hangar/releases/download/v2026.10.04.3"; a="Hangar-2026.10.04.3-candidate.zip"; curl -fL "$r/$a" -o "$a"; curl -fL "$r/$a.sha256" -o "$a.sha256"; shasum -a 256 -c "$a.sha256"; ditto -x -k "$a" .; bash Hangar-2026.10.04.3-candidate/install.command)
```

This downloads the versioned source archive, verifies its checksum, and runs the installer. Homebrew is still used for dependencies. Read [what installation changes](docs/installation.md) first; after installation, complete the permissions and setup steps below. The downloaded kit stays in the temporary folder; active configuration and rollback backups live separately.

For a manual install, start at step 1. If you used the command above, continue at step 3:

1. Extract the complete Hangar release folder. Read [what installation changes](docs/installation.md) and choose your workspace profile.
2. In Terminal, enter that folder and run `bash install.command`. It installs missing dependencies, validates a staging copy, backs up existing configuration, and activates Hangar. It may take several minutes on first setup.
3. In **System Settings → Privacy & Security → Accessibility**, enable AeroSpace, Hammerspoon, and Thaw. Enable **Screen & System Audio Recording** for Shottr and Thaw. The picker and overview do not capture your screen. If first-run checks fail before permissions are granted, grant them and run the installer again.
4. In Thaw → Displays, enable **Use Thaw Bar** for the display you use. Existing per-display settings may take priority over the defaults.
5. Run `~/.local/bin/hangar doctor`. Add `~/.local/bin` to your shell's PATH to use `hangar` directly. Open the command palette with **Control + Option + Command + /**.

Already have all dependencies? Use `bash install.command --configs-only`. To compile and validate without activation, use `bash install.command --check`; it does not install dependencies or replace active configuration.

## Make it yours

```sh
hangar config init                 # create portable defaults; does not activate
hangar config show --json          # effective settings and source paths
# Edit ~/.config/hangar/settings.toml, then:
hangar config check               # validate without changing the desktop
hangar config apply --kit /path/to/Hangar
```

Choose launchers and supported shortcuts in `settings.toml`. Keep full app routing, workspace names, display roles and gaps in an optional `aerospace.toml` beside it. These inputs survive kit updates. A `settings.local.toml` overlay keeps host-only choices separate. [Configuration guide](docs/profiles.md)

Git can share the source folder across Macs; each Mac validates and applies deliberately. Dotfiles manages the links, Hangar manages active copies and rollback. The bundled [hangar-config agent skill](skills/hangar-config/SKILL.md) can make these edits from a request such as “use Safari on this Mac and open the overview with Control+Option+O.” [Install the skill](docs/profiles.md#ai-assisted-configuration)

## Learn five default shortcuts

| Shortcut | Action |
| --- | --- |
| Hold **Option**, tap **Tab** | Cycle through windows and linked pairs; release Option to switch |
| **Option + 1–4** | Switch activity; add Shift to send the current window there |
| **Option + P** | Choose another window in the same workspace and make a split pair |
| **Option + O** | Open the workspace overview to focus, move, or pair windows |
| **Control + Option + Command + /** | Search commands, shortcuts, and diagnostics |

For a picker that stays open while you type, press **Control + Option + Command + W**. Enter opens a result; Escape cancels. A linked pair is one result, even when the search matches only one member.

[Full shortcut reference](docs/shortcuts.md) · [Profiles and customization](docs/profiles.md) · [Troubleshooting and rollback](docs/troubleshooting.md)

## Pick your layout

The default profile has four workspaces: **W**ork, **B**rowser, **S**ocial, and **M**edia. Work and Browser use the main display; Social and Media prefer a secondary display and fall back to main.

The `numbered-study` profile has **1 Work, 2 Study, 3 Social, 4 Misc**. Windows are shown one at a time, with explicit split pairs inside each activity. **Option + /** shows the current group side by side; **Option + Shift + /** returns it to the one-window view. See [profiles](docs/profiles.md) for selection and routing.

AeroSpace workspaces and macOS native Desktops are different systems. Hangar leaves native Desktops alone until you explicitly confirm **Gather windows**. Gathering moves windows onto the active Desktop on each display; it does not delete Desktops. [Read about native Desktops](docs/profiles.md#native-desktops-and-mouse-buttons).

## Recover confidently

Installation saves the files and preferences it changes. Failed activation attempts restore the snapshot and report any recovery errors. `hangar backups` lists transactions; `hangar rollback` restores the last successful installation after saving the current state. Homebrew-installed applications and OS permissions are outside this rollback.

The picker and overview use local native panels and process pipes. They do not upload window titles or take thumbnails. Diagnostic JSON contains local paths, display identifiers, and process details—review it before sharing. [Privacy and limitations](docs/limitations.md)

## Development and release status

This repository is a distribution candidate. [Development checks](docs/development.md) cover isolated Lua contracts, installer transactions, native compilation, and release contents. Live keyboard behavior, OS permissions, and physical display changes require an explicitly arranged manual test.

Licensed under [MIT](LICENSE), copyright © 2026 Anish De. The repository name is `hangar`. Existing LeanMac users can follow the [compatible upgrade path](docs/installation.md#upgrading-from-leanmac).
