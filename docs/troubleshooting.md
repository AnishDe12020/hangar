# Troubleshooting and rollback

Start with `~/.local/bin/hangar doctor`. It reports services, permissions, loaded shortcuts, display mapping, native helpers, and Secure Input without restarting apps or moving windows. Exit codes are 0 healthy, 1 warnings, and 2 failed checks. `--json` is useful locally; redact identifying details before sharing it.

| Symptom | Check or next action |
| --- | --- |
| `hangar: command not found` | Use `~/.local/bin/hangar`; add `~/.local/bin` to PATH |
| Picker says a window is unavailable | Run doctor; check whether AeroSpace responds, then reopen the picker to refresh |
| AeroSpace is running but its CLI cannot connect | Its control socket can be unavailable; save your work and arrange a deliberate restart, then check workspace assignments |
| Option shortcuts fail | Check Accessibility and Secure Input; leave password entry normally and inspect the reported owner rather than disabling security features |
| Install fails at compilation | Install Apple's Command Line Tools; rerun `bash install.command --check` |
| Install fails after activation | Read the transaction result and backup path; grant missing OS permissions and retry |
| Study window appears in Work | Titles can change after detection; use Option+Shift+2 |
| Desktop windows seem missing | Inspect native Desktops and workspace/display mappings; gathering is an explicit, confirmed action |

A warning about extra native Desktops is advisory. Doctor does not consolidate them. Secure Input PIDs may be stale or attributed to loginwindow; they do not prove which app caused a lock.

## Restore an installation

```sh
~/.local/bin/hangar backups
~/.local/bin/hangar rollback
# Or choose a named transaction from the list:
~/.local/bin/hangar rollback BACKUP_NAME
```

Rollback saves current files and touched preferences before restoring the selected snapshot. If the old snapshot predates the CLI, run `bash bin/hangar rollback BACKUP_NAME` from an extracted kit. A backup marked `rollback-failed` needs attention; do not repeatedly install over it. The failure report identifies what could not be restored.

Rollback covers managed configuration, native helper files, and the preferences/login-agent state captured by that transaction. It does not uninstall Homebrew dependencies, revoke OS permissions, recreate closed windows, or restore an arbitrary AeroSpace layout tree. Back up custom profiles separately.
