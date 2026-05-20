# Changelog

All notable changes to cachyos-maintenance.sh are documented here.

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
