# Privacy and practical limits

Window discovery and UI state stay local. The picker/overview use app icons, titles, and local process pipes; they do not record screenshots or send telemetry. Installing dependencies uses Homebrew and its upstream hosts.

Doctor JSON includes a hostname, local paths, display names/UUIDs, and process information. Backups contain the previous configuration and touched preference values. Keep these local or review and redact them before sharing. Release packaging uses an explicit list of source and documentation files; it excludes backups, logs, screenshots, local profiles, and historical machine reports.

Linked pairs are Hangar associations, not a complete native layout tree. Pairs made outside Hangar may need to be explicitly re-paired. Native Ghostty tabs can retain separate AeroSpace IDs; hidden tabs are filtered when they can be identified, but pairs do not transparently follow arbitrary tab switches. No closed application or session is recreated.

Pair/swap/move operations revalidate exact IDs, PIDs, and workspace membership. They are not atomic OS transactions. On a failure, the code attempts bounded recovery and reports partial layouts; split proportions and arbitrary tree structure cannot always be recovered. Swapping uses default pair proportions.

Secure Input can block Hammerspoon-owned shortcuts. OS permissions and shortcut conflicts require checks on the target Mac. Physical monitor unplug/replug, keyboard timing, and live GUI interactions cannot be proven by isolated tests or native self-tests.

The experimental native hotkey router remains source-only for historical development context. It is not installed or packaged, and activation refuses an installed/running experimental router. AeroSpace owns workspace keys; Hammerspoon owns picker and snap keys.
