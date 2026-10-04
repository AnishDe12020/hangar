# Profiles and customization

| Profile | Workspaces | Display preferences |
| --- | --- | --- |
| `default` | W Work, B Browser, S Social, M Media | W/B main; S/M secondary, falling back to main |
| `numbered-study` | 1 Work, 2 Study, 3 Social, 4 Misc | 1/2 main; 3/4 secondary, falling back to main |

The default profile tiles windows. The numbered profile uses vertical accordion views with explicit horizontal pairs. In either profile, Option+1–4 selects an activity and Option+Shift+1–4 moves a window there.

To select a profile on this Mac:

```sh
mkdir -p "$HOME/Library/Application Support/LeanMac"
printf '%s\n' numbered-study > "$HOME/Library/Application Support/LeanMac/aerospace-profile"
bash install.command --configs-only --check
bash install.command --configs-only
```

Use `default` in the selector to return to W/B/S/M. An unknown profile fails rather than silently changing your layout. Profile selection persists locally; the installer copies the selected file to `~/.aerospace.toml`.

## App routing

The default separates coding/terminal apps, browsers, chat, and media. The numbered template routes coding and general browsing to Work, Obsidian and recognized study/lecture/assignment titles to Study, chat to Social, and media/utilities to Misc. Title matching is best-effort: some apps change their titles after the new-window event. Option+Shift+2 reliably moves a missed Study window.

Inspect `config/aerospace*.toml` before activation. The shipped numbered template uses generic study keywords and display roles. Existing personal title rules and monitor brand preferences should stay in a local profile rather than a public release.

To preserve an existing personal profile, copy its original file to `config/aerospace-local.toml` in your extracted kit and set the local selector to `local`. That file is ignored by Git and omitted from release archives. Keep a separate private backup and copy it into a replacement kit when updating; a missing local profile stops installation.

The public template does not change an already-running Mac. Activating it is an intentional migration; use your local profile if you want your exact existing routing and monitor choices.

## Native Desktops

AeroSpace workspaces hide inactive windows within macOS Spaces. Native macOS Desktops remain a separate layer. Hangar neither changes the Dock's automatic Space ordering nor moves Desktop windows at startup.

If extra native Desktops are confusing your window workflow, open the palette and choose **Gather windows from extra macOS Desktops**, or press **Control+Option+Command+S**. Both ask before moving windows onto each display's current Desktop. Cancel leaves them alone. Gathering does not delete Desktops; remove unwanted empty Desktops manually in Mission Control.

## Mouse buttons

Logi Options+ is optional and configured separately. Map the picker button to F17, workspace gestures to F18/F19, and your preferred button to Mission Control. Hangar consumes those function keys but does not copy device IDs or import mouse settings. Existing mappings on a configured Mac remain yours.
