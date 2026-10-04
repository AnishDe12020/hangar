# Development and release checks

From a repository checkout (developer tools/tests are not included in the install archive), use Python 3.11+ on macOS with Hammerspoon installed. Its bundled Lua interpreter runs the mocked contracts without launching the app. Native checks also require Apple's Command Line Tools.

```sh
python3 tools/check.py             # Lua contracts, Python tests, shell syntax
python3 tools/check.py --native    # also compile/sign staged native helpers
python3 tools/package_release.py   # source-only candidate ZIP and SHA-256 checksum
```

The check runner redirects installation paths to a temporary directory. It never activates AeroSpace, opens the live picker, calls the user's Hammerspoon IPC, or changes live windows. Transaction tests inject fake services and compilation results; the separate native staging step compiles the real Swift sources and runs their non-GUI self-tests.

The package allowlist includes only the installation entrypoints, active runtime sources, public profiles, and user documentation. `MANIFEST.json` hashes every included source file. Source timestamps, ZIP permissions, and ordering are normalized for repeatable archives. Personal profiles named `aerospace-local*.toml` and experimental helpers are omitted. The archive remains a candidate until release review and target-Mac checks are complete.

The macOS CI workflow runs the same isolated checks and packaging. It has read-only repository permissions and does not publish releases. CI configuration being present does not mean a hosted run has occurred.

## Manual testing is separate

`tests/native_pair_smoke.py` and `tests/native_picker_latency.py` create fixture windows and mutate live AeroSpace workspace state. `tests/native_picker_smoke.py` opens an AppKit fixture panel. They are intentionally excluded from the default runner, CI, and install archive. Arrange explicit permission for a GUI testing session before running them; inspect their arguments and cleanup behavior first.

Before promoting a release, test fresh-Mac permissions and activation/rollback, physical Option+Tab release, user mouse mappings, native tab behavior, and display unplug/replug on the supported configurations. The candidate has not been physically tested on another Mac. The imported 2026.09.17.2 baseline was compared with the canonical kit: all 34 comparable imported source files matched, and all 16 checked installed text counterparts matched canonical sources. One remote test source (`tests/test_transaction.py`) could not be read; its remote equality remains unverified. The candidate deliberately differs through the documented distribution, consent, and Hangar rename changes.

## Distribution ownership

Hangar owns AeroSpace and its Hammerspoon modules. A dotfiles project should link users to this installer and keep terminal/editor configuration separate. Avoid applying two templates to `~/.aerospace.toml` or `~/.hammerspoon/init.lua`.

The source is MIT licensed; include LICENSE in every source distribution. Keep machine histories, source comparison reports, diagnostic output, window titles, and backup manifests outside the Git history. Public docs should describe reproducible behavior rather than an individual's machine state.
