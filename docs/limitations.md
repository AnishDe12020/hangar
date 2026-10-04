# Privacy and practical limits

Window discovery and UI state stay local. The picker/overview use app icons, titles, and local process pipes; they do not record screenshots or send telemetry. Installing dependencies uses Homebrew and its upstream hosts. Optional utilities have their own privacy policies and permission prompts.

Doctor JSON includes a hostname, local paths, display names/UUIDs, and process information. Backups contain the previous configuration and touched preference values. Keep these local or review and redact them before sharing. Release packaging uses an explicit list of source and documentation files; it excludes backups, logs, screenshots, local profiles, and historical machine reports.

Linked pairs are Hangar associations, not a complete native layout tree. Pairs made outside Hangar may need to be explicitly re-paired. Native Ghostty tabs can retain separate AeroSpace IDs; hidden tabs are filtered when they can be identified, but pairs do not transparently follow arbitrary tab switches. No closed application or session is recreated.

Pair/swap/move operations revalidate exact IDs, PIDs, and workspace membership. They are not atomic OS transactions. On a failure, the code attempts bounded recovery and reports partial layouts; split proportions and arbitrary tree structure cannot always be recovered. Swapping uses default pair proportions.

Secure Input can block Hammerspoon-owned shortcuts. OS permissions and shortcut conflicts require checks on the target Mac. Physical monitor unplug/replug, keyboard timing, and live GUI interactions cannot be proven by isolated tests or native self-tests.

The experimental native hotkey router remains source-only for historical development context. It is not installed or packaged, and activation refuses an installed/running experimental router. AeroSpace owns workspace keys; Hammerspoon owns picker and snap keys.

Apron stores file references locally. Pasted content and promised attachments are saved under `~/Library/Application Support/LeanMac/Apron/Imports`; removing a shelf entry preserves these imported files as well as original files. This storage is separate from shared configuration and is not synchronized by Hangar.

Apron Quick Tools require a new destination. They accept up to 128 MB of input/output, images up to 100 megapixels (40 megapixels for original-size output), and at most 20 PDFs with 300 total pages. Images are decoded by ImageIO and PDFs by PDFKit. Animated/multi-image files and encrypted/locked PDFs are refused. Image copies are re-rendered in sRGB without source EXIF/GPS metadata; this can change color appearance and is not lossless archival editing. JPEG uses a white background for transparency. PDF merge/extraction copies pages, not document-level signatures, forms, bookmarks or attachments; use a dedicated PDF editor when those features matter.

Focus timers and reminders require Hammerspoon for notification delivery. Permissions and Focus settings can suppress banners. Hangar records completion before sending a notification, avoiding duplicate delivery after reload at the cost of a possible missed notification if the process crashes between those steps. Their private state is separate from installation backups. See [Sessions](sessions.md).

Apron ZIP exports are portable file-data archives: resource forks and extended attributes are omitted. They accept up to 100 selected files/folders, 4096 entries, 32 directory levels and 128 MB of input/output, with a 60-second preparation limit and a separate 60-second compression limit. Symlinks and special files are rejected; duplicate top-level names are numbered. Originals remain in place.
