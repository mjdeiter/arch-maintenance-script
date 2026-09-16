# cachyos-maintenance.sh

A comprehensive system maintenance script for CachyOS (Arch-based) systems. Handles package updates, AUR sync, Btrfs snapshots, Docker cleanup, log rotation, HP BIOS staging, and more — with full dry-run preview support.

## Features

- **Package management** — repo + AUR updates (paru/yay), dep-conflict detection, keyring self-repair
- **Btrfs snapshots** — pre-update snapshots via snapper, old snapshot pruning
- **Btrfs health check** — warns on high metadata usage, flags orphaned-looking rollback/backup subvolume trees
- **Coral TPU / DKMS** — rebuilds `gasket`/`apex` DKMS modules against the actually-installed kernel after a kernel bump, so `/dev/apex_0` survives a reboot without manual intervention
- **Python/pip compatibility check** — catches a system Python version bump silently breaking `--user`-installed packages with compiled C extensions before they crash-loop a service
- **Crash-loop / port-conflict detection** — flags services with high restart counts, tails the last journalctl error line for each so no manual log dig is needed
- **Docker** — graceful Compose shutdown before updates, container/image cleanup
- **HP BIOS staging** — automatic detection and staging of BIOS updates via HP FTP catalog
- **Remote Home Assistant check** — verifies a custom-component patch on the HA host is still applied, reapplies it if a HACS update overwrote it
- **Log management** — auto-log every run, configurable retention, log rotation
- **Dry-run mode** — full preview of what would be done, no root required, logs to `~/.local/log/`
- **Kernel mismatch detection** — warns if running kernel differs from installed
- **Interactive mode** — prompts before each major step
- **Resilient execution** — every maintenance step is individually guarded, so a failure in one step doesn't abort the rest of the run

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
- `dkms` + `gasket-dkms-git` for Coral TPU module rebuilds (optional)

## Logs

- **Live runs** — `/var/log/archos-cleanup/YYYY-MM-DD_HH-MM-SS_live.log`
- **Dry runs** — `~/.local/log/cachyos-maintenance/YYYY-MM-DD_HH-MM-SS_dry-run.log`

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
