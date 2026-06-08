# Changelog

All notable changes to cachyos-maintenance.sh are documented here.

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
