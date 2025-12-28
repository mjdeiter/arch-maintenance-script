# archOS System Cleanup and Update Script

**Version:** 3.2.1  
**Release Type:** Patch 
**Platform:** Arch Linux / CachyOS  
**Privileges:** Root required (sudo)

Enterprise-grade system cleanup and update automation with strict safety guarantees,
serialized package operations, cron compatibility, and reproducible behavior.

---

## Key Guarantees

- No pacman / yay lock races
- No unsafe parallel package operations
- Cron-safe output (no TTY assumptions)
- Snapshot self-exclusion
- Whitelist-aware deletion
- Deterministic, machine-parseable logs

---

## Features

- System updates via pacman (serialized)
- Package cache pruning (paccache)
- Orphan package removal
- System log cleanup (logrotate + journald)
- Safe `/var/tmp` cleanup
- Optional JSON / CSV reporting
- Optional cleanup history tracking
- Cron job installation

---

## Installation

```bash
git clone <repo>
cd archos-cleanup
chmod +x archos-cleanup.sh
sudo ./archos-cleanup.sh
