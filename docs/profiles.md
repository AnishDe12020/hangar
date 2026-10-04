# Configuration that stays with you

Hangar reads `${XDG_CONFIG_HOME:-$HOME/.config}/hangar`. A normal install/update and `hangar config apply` use these same source files; neither edits them. Git or a dotfiles repository can share them across Macs. The active AeroSpace/Hammerspoon copies stay local until an explicit apply.

| File | Purpose |
| --- | --- |
| `settings.toml` | Shared profile, application launchers, and supported shortcuts |
| `settings.local.toml` | Optional host overrides; exclude from Git/cloud sync |
| `aerospace.toml` | Optional complete profile for routing, workspace names, monitor roles, gaps and AeroSpace bindings |

## Start and edit

```sh
hangar config init
hangar config show --json
```

Before the CLI is installed, use `bash /path/to/Hangar/bin/hangar` in place of `hangar`. `init` refuses to overwrite existing settings and never activates anything. It creates Terminal/Safari/Finder defaults. With no settings files, legacy Ghostty/Brave/Finder defaults remain unchanged. The profile selector under `~/Library/Application Support/LeanMac/aerospace-profile` remains the fallback until you explicitly set `profile`.

A small shared configuration:

```toml
schema = 1
profile = "numbered-study"

[apps]
terminal = "Terminal"
browser = "Safari"
finder = "Finder"

[hotkeys]
overview = "ctrl-alt-o"
picker_search = "ctrl-alt-cmd-w"
```

An optional `settings.local.toml` can contain just:

```toml
[apps]
browser = "Firefox"
```

Host values override shared values one key at a time. Unknown keys, invalid types/chords, duplicate shortcuts, and conflicts with any AeroSpace binding mode fail validation. Launchers are application names, not shell commands. Hangar does not install those chosen apps. `config show --json` reports effective desired values and their source paths; it is not proof that they have been activated.

## Validate and apply

```sh
hangar config check --kit /path/to/Hangar
hangar config apply --kit /path/to/Hangar
hangar doctor
```

`check` parses TOML, checks schema/profile and shortcut ownership, and syntax-checks generated Lua when Hammerspoon is installed. It does not compile helpers, install dependencies, reload apps, or create installation state. For full native staging, use `hangar install --kit /path/to/Hangar --check`.

`apply` uses the same recoverable configuration transaction as `bash install.command --configs-only`. It compiles native helpers and activates copied files without changing Shottr/Thaw preferences. Omit `--kit` while the adjacent or previously installed kit remains available. A missing source fails with an error. Broken input symlinks fail rather than silently reverting to defaults.

Rollback restores active files, including the compiled settings snapshot. It leaves shared source settings and host overlays untouched; revert a source edit separately if it should not return on the next apply.

## Profiles, routes and displays

| Profile | Workspaces | Display preferences |
| --- | --- | --- |
| `default` | W Work, B Browser, S Social, M Media | W/B main; S/M secondary, falling back to main |
| `numbered-study` | 1 Work, 2 Study, 3 Social, 4 Misc | 1/2 main; 3/4 secondary, falling back to main |

The default profile tiles windows. The numbered profile uses vertical accordion views with explicit horizontal pairs; Option+/ shows a group side by side and Option+Shift+/ returns it to the one-window view. Both templates preserve Option+1–4 and Option+Shift+1–4 workspace navigation.

For routing or display changes, start from the complete selected profile:

```sh
cp /path/to/Hangar/config/aerospace-numbered-study.toml ~/.config/hangar/aerospace.toml
```

If the destination already exists, edit or back it up instead of overwriting it. Use your configured XDG directory when it differs from `~/.config`. To preserve your current personal rules, copy that original profile instead. The full override wins over the kit profile; Hangar does not attempt a fragile line-by-line TOML merge. It persists independently of release folders. Existing kit-local profiles still work through the legacy selector, but a persistent override avoids copying them into each new release.

Edit `on-window-detected` for app routes, `[workspace-to-monitor-force-assignment]` for displays, and `[gaps]` for spacing. Prefer `main` and `['secondary', 'main']` roles for shared settings. Title matching is best-effort because apps can change titles after the new-window event. Move a missed window explicitly with Option+Shift+number.

Keep the template's required workspace/MX navigation keys (Option+1–4, Option+Shift+1–4, F18/F19), helper-window rules, and no conflicting Option+Tab binding. AeroSpace performs full semantic validation during activation; a lightweight check does not claim to validate every upstream command.

## Shelf appearance

Choose **Compact** or **Glass** in Ground Control, or set `shelf_style = "compact"` (default) / `"glass"` at the top of `settings.toml`, before any tables. A local override can choose a different style for each Mac. Save & Apply activates the preference; both styles respect Reduce Transparency.

## Supported shortcut settings

`[hotkeys]` accepts these semantic action names:

- Launchers/utilities: `terminal`, `browser`, `finder`, `menu_bar`, `menu_search`, `reload`, `management_toggle`.
- Windows: `picker_search`, `snap_left`, `snap_right`, `snap_up`, `snap_down`, `pair`, `separate`, `layout_menu`, `overview`.
- Other controls: `palette`, `gather`, `mx_picker`, `shelf`, `settings`.

Chords use `ctrl`, `alt`, `cmd`, `shift`, then one key: letters/digits, `return`, `tab`, `space`, `escape`, arrows, `slash`, `comma`, `period`, `backtick`, `minus`, `equal`, or `f1`–`f20`. Modifier order does not matter. `hangar config show` lists every effective chord.

Option+Tab and Option+Shift+Tab remain fixed because both native picker and modifier-release handling own that interaction. Set `[modules]` with `shelf = false` to disable Apron and its drag observer. Other feature disabling, arbitrary Lua hooks, native panel geometry, and custom dependency installation paths are not exposed as settings. AeroSpace/Hammerspoon are discovered in the supported Homebrew/Applications locations. Stable LeanMac storage/bundle identifiers remain compatibility internals.

The layout menu invokes semantic AeroSpace commands directly, so remapping its corresponding AeroSpace keys does not break menu actions. Pair/separate/snap/overview hints use configured keys; the overview no longer displays a fixed shortcut.

## Dotfiles and another Mac

Store `settings.toml` and optionally `aerospace.toml` in your dotfiles checkout and link/copy them into the input directory. Keep `settings.local.toml` local. The companion dotfiles bootstrap offers optional `--hangar-config` for those inputs; it does not activate windows or own generated runtime files.

Review and commit shared edits, update the checkout on another Mac, then run `config check` and `config apply` there. Git updates desired inputs; it does not reload the desktop automatically. Do not sync active helper binaries, rollback journals, OS permissions, licenses, or live window-pair state. Host overrides can affect effective shortcuts, so validate on each Mac.

## AI-assisted configuration

The release includes `skills/hangar-config`. Copy that folder into your agent's skill directory (for Codex, `$CODEX_HOME/skills`, normally `~/.codex/skills`), following the agent's normal skill installation flow. The kit does not install a live skill automatically.

Ask the agent to use `hangar-config`, for example: “Change the shared terminal to Ghostty, keep Safari on this Mac, and show me the validated diff.” The skill locates real source files, follows dotfiles symlinks, preserves host overrides, uses `show`/`check`, and applies only when activation is within the request. It avoids editing generated runtime files.

## Native Desktops and mouse buttons

Native macOS Desktops remain separate from AeroSpace workspaces. Hangar neither changes their ordering nor moves their windows at startup. Palette **Gather windows** and its configured hotkey both ask first; gathering moves windows to each display's active Desktop and does not delete Desktops.

Logi Options+ is configured separately. Its button can emit the configured `mx_picker` chord (F17 by default); workspace gestures use F18/F19. Hangar does not copy device IDs or import mouse settings.
