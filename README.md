# cachyos-maintenance.sh

A comprehensive system maintenance script for CachyOS (Arch-based) systems. Handles package updates, AUR sync, Btrfs snapshots, Docker cleanup, log rotation, HP BIOS staging, and more — with full dry-run preview support.

## Features

- **Package management** — repo + AUR updates (paru/yay), dep-conflict detection, keyring self-repair
- **Btrfs snapshots** — pre-update snapshots via snapper, old snapshot pruning
- **Docker** — graceful Compose shutdown before updates, container/image cleanup
- **HP BIOS staging** — automatic detection and staging of BIOS updates via HP FTP catalog
- **Log management** — auto-log every run, configurable retention, log rotation
- **Dry-run mode** — full preview of what would be done, no root required, logs to `~/.local/log/`
- **Kernel mismatch detection** — warns if running kernel differs from installed
- **Interactive mode** — prompts before each major step

## Usage

```bash
# Dry run — preview everything, no changes, no root needed
./cachyos-maintenance.sh --dry-run

# Normal run (requires root)
sudo ./cachyos-maintenance.sh

# Verbose dry run
sudo ./cachyos-maintenance.sh -v --dry-run

# Interactive run with custom log
sudo ./cachyos-maintenance.sh -i -l /var/log/maintenance.log
```

## Options

| Flag | Description |
|------|-------------|
| `-d`, `--dry-run` | Preview mode — no changes made, no root required |
| `-v`, `--verbose` | Enable debug logging |
| `-i`, `--interactive` | Prompt before each major step |
| `-l FILE`, `--log-file FILE` | Also log to a custom file path |
| `-h`, `--help` | Show help |

## Requirements

- CachyOS / Arch Linux
- `paru` or `yay` for AUR updates
- `snapper` for Btrfs snapshot support (optional)
- `docker` / `docker compose` for container cleanup (optional)

## Logs

- **Live runs** — `/var/log/archos-cleanup/YYYY-MM-DD_HH-MM-SS_live.log`
- **Dry runs** — `~/.local/log/cachyos-maintenance/YYYY-MM-DD_HH-MM-SS_dry-run.log`

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
