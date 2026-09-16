# Changelog

All notable changes to cachyos-maintenance.sh are documented here.

---

## [4.2.17] — merge origin with 5 weeks of local work; Python/pip compat check

Origin (`main`) and this box's local copy of the script had diverged
independently since `v4.0.1` — this release reconciles both branches, keeping
every fix from each, and adds two new pieces of tonight's incident response.

### Added
- `check_pydantic_compat()`: after a system Python version bump silently broke
  `pydantic`/`pydantic-core` for `elitebook-exec` and `llm-memory`, and a
  separate `cachetools` gap crash-looped `letta-mcp-http`, neither was caught
  until the services were already down. This check tries importing each known
  service's compiled-extension modules under the current `python3` and warns
  before they crash-loop, instead of after.
- `check_port_conflicts()` now tails the last `journalctl` error line (or last
  log line if nothing logged at `err` level) for any flagged crash-looping
  unit, so a flagged service comes with an actual pointer instead of requiring
  a manual `journalctl` dig every time.

### Merged in from local (previously undocumented in this file)
- `check_alexa_media_patch()`: verifies the `alexa_media` `update_last_called()`
  no-op patch is still present on the Home Assistant host; reapplies it and
  flags an HA core restart if a HACS update overwrote it.
- `check_btrfs_health()`: warns on high Btrfs metadata usage and flags
  orphaned-looking rollback/backup subvolume trees left behind by past
  incidents.
- `check_coral_dkms()`: rebuilds the `gasket`/`apex` DKMS modules against the
  actually-installed kernel (not just the running one) after a kernel bump, so
  `/dev/apex_0` and Frigate detection survive a reboot without manual
  intervention. The `IgnorePkg` hold on `linux-cachyos` (worked around kernel
  7.1.1 briefly breaking this driver) was removed 2026-08-30 now that the fix
  lives in `gasket-dkms-git` itself.
- `check_root()`: `AUR_USER` detection from `SUDO_USER` moved ahead of the
  dry-run early-return, and a fallback to `$USER`/`$LOGNAME` added for
  non-sudo invocations (e.g. a bare `--dry-run`), so AUR update counts are no
  longer silently zero depending on how the script was invoked.
- `update_repo_packages()`: added `STATS[repo_applied]`, tracked separately
  from the pre-run available count, so the summary and rolling log report
  what actually installed rather than what was merely available — previously
  a failed pacman transaction (e.g. an untrusted-key abort) still reported the
  available count as "applied".
- `scan_broken_links()`: added `/usr/lib/syslinux/`, `/usr/lib/systemd/`,
  `/opt/zen-browser-bin/`, and `/usr/lib/floorp/` to `SENTRY_IGNORE_PATHS`
  (all resolve their shared libs via internal/`$ORIGIN`-relative loading, not
  `ld.so`'s default search path); added a `SCAN_EXCLUDE_PATHS` prefilter for
  `/usr/share/kicad/` so its tens of thousands of non-ELF asset files never
  reach the `file -L` pass.
- `main()`: every step is now individually guarded with `||` so a non-fatal
  failure in one step can't silently abort every step after it under `set -e`.
- Reduced `MAX_SNAPSHOTS` from 10 to 3 — snapper already covers durable
  rollback history; the script's own subvolumes only need to catch "did the
  last run itself break something."

---

## [4.2.2] — library sentry hardening

### Fixed
- `Library Sentry`: `ldconfig` now runs with `sudo` (falling back to unprivileged) so the
  cache is always current when the sentry runs, including during pacman hook invocations
- Added `SENTRY_IGNORE` array to filter known cross-name symlink false positives;
  `libvapoursynth-script.so.0` (a symlink → `libvsscript.so`) suppressed by default

### Added
- Installed `jasper` (JPEG-2000 codec) — fixes GraphicsMagick `jp2.so` missing `libjasper.so.7`
- Installed `qt6-canvaspainter` — fixes PySide6 `QtCanvasPainter` missing `libQt6CanvasPainter.so.6`

---

## [4.2.1] — dry-run hardening

### Fixed
- `check_bios_update()` now returns immediately with an info message in dry-run mode —
  previously `fwupdmgr get-updates` would hang indefinitely without root
- `snapshot_pre()` no longer runs `mkdir -p $SNAPSHOT_DIR` before the DRY_RUN guard
- All dry-run paths now reach the summary block and exit cleanly (exit 0)

---

## [4.2.0] — current

### Added
- `--dry-run` mode no longer requires root — `check_root()` returns early with a warning when `DRY_RUN=true`
- Dry-run auto-log redirected to `$HOME/.local/log/cachyos-maintenance/` instead of `/var/log/archos-cleanup/` so previewing the script never needs elevated privileges
- HP BIOS update staging via HP FTP catalog
- Docker Compose graceful shutdown before system operations
- Kernel mismatch detection
- Snapper-aware dry-run mode
- Keyring self-repair
- AUR dep-conflict detection with logging

### Fixed
- `bash -n` is no longer recommended for dry-run usage (it only checks syntax; use `--dry-run` instead)
- Auto-log creation no longer hard-exits on permission denied during dry-run

---

## [4.1.3]

### Added
- Logging improvements and verbosity controls

---

## [4.1.1]

### Fixed
- AUR root error handling
- Snapshot prune logic

---

## [4.0.1]

### Added
- Docker/reboot feature merge
- Initial public release

---

## [4.2.4] — fwupdmgr hang fix

### Fixed
- check_bios_update(): fwupdmgr get-updates now runs under timeout 30 to prevent
  the BIOS check from hanging indefinitely when LVFS metadata refresh stalls on the network.
  Previously a slow or unresponsive LVFS connection would block the entire script with no
  timeout, causing the maintenance run to silently stall after logging the current BIOS version.

---

## [4.2.5] — Library Sentry Wine false positive suppression

### Added
- SENTRY_IGNORE_PATHS array to scan_broken_links(): path-prefix-based exclusion for ELF
  files that use non-standard or internal linking not resolvable by ldd at scan time.
- /usr/lib/wine/ added as the first ignored path: all Wine x86_64-unix .so files reference
  ntdll.so and win32u.so as Wine-internal pseudo-DLLs that do not exist as real shared
  objects on the host. This was causing 150+ false-positive errors on every scan run.
