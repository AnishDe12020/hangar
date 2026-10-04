# Optional utilities

Ground Control's Quick Install catalog keeps companion apps optional. List choices with `hangar utilities list` (or add `--json`). Install one with `hangar utilities install shottr`. A successful install does not launch the app: open it yourself to choose shortcuts, permissions and login behavior.

| App | Why it belongs | Compatibility | License and distribution |
| --- | --- | --- | --- |
| [Tinycast](https://tinycast.dev/) | Native launcher, clipboard history, snippets and Raycast-compatible extensions; Hangar does not duplicate these features. | macOS 26+; Apple silicon build or Intel-compatible universal build. | AGPL-3.0; official publisher Homebrew tap; explicit trust/quarantine approval required. |
| [Shottr](https://shottr.cc/) | Screenshot annotation, OCR, scrolling capture and pixel measurements beyond Hangar's desktop controls. | Apple silicon and Intel. Publisher supports macOS 10.15+; current Homebrew Quick Install requires 12+. | Proprietary; free use with reminders, paid license required for commercial use. Core Homebrew cask. |
| [Thaw](https://github.com/thaw-app/Thaw) | Menu bar organization, including overflow on notched displays. | macOS 26+; Apple silicon and Intel. | GPL-3.0; signed and notarized; core Homebrew cask. |
| [LocalSend](https://localsend.org/) | Local file and text transfers to other computers and phones, especially Android, Windows and Linux. | macOS 11+; Apple silicon and Intel. | Apache-2.0; core Homebrew cask. |
| [IINA](https://iina.io/) | Broad video/audio format support and playback controls through mpv. | Apple silicon: macOS 12+; Intel: macOS 11+. | GPL-3.0; stable core Homebrew cask, which also links the `iina` command. |
| [Stats](https://github.com/exelban/stats) | Optional CPU, memory, disk and network monitoring in the menu bar. | macOS 12+; Apple silicon and Intel. | MIT; core Homebrew cask. Periodic monitoring costs CPU and energy while running. |

Catalog metadata was reviewed on October 4, 2026. Homebrew resolves the current stable release when you install; its current requirements and upstream availability remain authoritative. Hangar does not pin versions, purchase licenses, enable extensions, copy credentials, import launcher backups, grant macOS permissions, change app preferences, or install Homebrew automatically.

## Tinycast approval

Tinycast is self-signed and lacks Apple notarization. Its publisher's Homebrew casks remove `com.apple.quarantine` from `Tinycast.app` after installation and during future cask upgrades. The official setup also trusts the publisher's entire Homebrew tap. These are persistent trust decisions: tap trust remains if the subsequent download or install fails.

Quick Install explains these effects and requires explicit approval before running either step. The CLI defaults to a `consent_required` result. After reviewing the publisher and understanding the effects, an explicit CLI approval is:

```sh
hangar utilities install tinycast --allow-unnotarized
```

The approved path uses `brew trust --tap abue-ammar/tinycast`, then the fully qualified stable cask for your architecture. An older Homebrew without `trust` stops with an actionable error; Hangar does not bypass that failure. The [official installation instructions](https://tinycast.dev/docs/install/) include direct downloads and more detail. Hangar itself never invokes `xattr`, disables Gatekeeper globally, or launches Tinycast.

Tinycast's [extension compatibility documentation](https://tinycast.dev/docs/extensions/compatibility/) describes the supported Raycast API surface. Compatibility varies, so existing extensions should be checked individually. Enable extensions and choose Tinycast's launcher shortcut in its own settings. Keep that shortcut distinct from Hangar's global shortcuts.

## Preservation and failures

Discovery reads app bundle identifiers in `/Applications` and `~/Applications`, including renamed apps at the top level. An existing recognized app is reported as installed and is not upgraded, reinstalled or launched. Existing names that cannot be identified are blocked rather than replaced. Apps in other folders, nested subfolders or a custom Homebrew application directory may not be detected; verify those manually before installing.

Install commands are restricted to the catalog IDs and fixed cask names. They run as argument arrays without a shell. Homebrew environment overrides are removed for the installer, including inherited cask options; automatic updates, installation upgrades and cleanup are disabled. Normal quarantine is explicitly enabled for core casks. Tinycast's approved upstream postflight still removes its app quarantine as described above.

Only one Hangar utility installer runs at a time. Output is streamed to Ground Control or CLI stderr; JSON results stay on stdout. An install must exit successfully and produce a matching app bundle before Hangar reports success. A timeout stops the installer process group after 15 minutes; interrupted or failed Homebrew operations can leave downloaded files or partial installation state. Review the output and Homebrew state before retrying. Hangar does not delete those files or automatically undo tap trust.

## App-by-app scope

- **Tinycast: include.** Reuse its launcher, clipboard, snippets, notes and extension runtime. Its opt-in permissions and extension behavior belong to the app.
- **Shottr: include.** Keep specialized capture and annotation in the established app. Hangar's shelf can hold the resulting files.
- **Thaw: include.** Reuse its menu bar manager instead of introducing another process to hide menu items.
- **LocalSend: include when needed.** Useful for transfers outside Apple's AirDrop ecosystem. Both devices need the app and local network access. Hangar does not send files, accept transfers, change firewall rules or enable launch at login.
- **IINA: include when needed.** Useful when QuickTime does not cover your formats or controls. Install the stable release; unsigned nightlies are outside this catalog. Hangar does not change default file associations or install player plugins.
- **Stats: include when needed.** Choose it only for continuous monitoring; Activity Monitor already handles occasional inspection. Disable unused modules to reduce ongoing CPU/energy use, especially Sensors and Bluetooth. Upstream fan control is unmaintained. Hangar neither configures a privileged helper nor enables fan control, remote monitoring or login launch.
- **[Maccy](https://maccy.app/): omit from this catalog.** It is a focused clipboard manager, but duplicates the selected Tinycast clipboard workflow. Existing Maccy installations are untouched.
- **[Rectangle](https://rectangleapp.com/): omit from this catalog.** Its window snapping overlaps Hangar's existing window controls and Tinycast's window actions. Running extra global shortcuts is unnecessary for this setup.
- **Other launchers and shelf apps: no additional install.** The selected launcher is Tinycast; Apron provides Hangar's requested file shelf. Companion choices stay narrow instead of installing multiple tools for the same job.

LocalSend, IINA and Stats use core Homebrew casks without install steps that remove quarantine or establish third-party tap trust. Normal macOS app checks remain in place. The catalog requires an individual install action for every app; none is installed by default.

## Evidence and development

The catalog's `sources` fields link directly to publisher documentation and maintained distribution definitions. Primary references: [Tinycast source and license](https://github.com/abue-ammar/tinycast), [ARM cask](https://github.com/abue-ammar/homebrew-tinycast/blob/main/Casks/tinycast.rb), [universal cask](https://github.com/abue-ammar/homebrew-tinycast/blob/main/Casks/tinycast-universal.rb), [Shottr pricing](https://shottr.cc/purchase.html), [Shottr cask requirements](https://formulae.brew.sh/cask/shottr), [Thaw source and license](https://github.com/thaw-app/Thaw), [Thaw cask requirements](https://formulae.brew.sh/cask/thaw), [LocalSend source and compatibility](https://github.com/localsend/localsend), [LocalSend cask](https://formulae.brew.sh/cask/localsend), [IINA downloads and architecture requirements](https://iina.io/download/), [IINA cask metadata](https://formulae.brew.sh/api/cask/iina.json), [Stats requirements and resource usage](https://github.com/exelban/stats), and [Stats cask](https://formulae.brew.sh/cask/stats).

The standalone development entrypoint is `python3 tools/hangar_catalog.py list --json` or `python3 tools/hangar_catalog.py install ID --json`. `catalog_status()` returns JSON-serializable entries; `install_utility(id, emit=None, *, allow_unnotarized=False)` returns an `ok`, `status` and `message` result. `emit` receives plain-text progress. `Catalog` accepts explicit discovery paths and a process runner for isolated integration checks. Tests use temporary app bundles and a fake installer; the real streaming process tests execute only small Python fixtures. They do not install optional apps on the developer's Mac.
