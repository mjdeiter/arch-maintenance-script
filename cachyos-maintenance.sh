#!/bin/bash
# archOS / CachyOS System Cleanup and Update Script - ENTERPRISE EDITION
# Version: 4.0.1
#
# Optimizations & Fixes:
#   - Added command-line argument support
#   - Fixed arithmetic errors from whitespace in update counters
#   - Hardened numeric coercion for all counters
#   - AUR-aware update counting AND execution (paru/yay, non-interactive)
#   - Wayland / cron identical behavior (TTY-independent)
#   - Clean Btrfs pre/post snapshot hooks with pruning
#   - Defensive defaults, strict error handling, cron-safe output
#   - Optional file logging (--log-file)
#   - Docker Compose stack detection and graceful shutdown before reboot
#   - Kernel mismatch / reboot detection
#   - Optional interactive reboot prompt (--interactive)
#
# No interactive prompts by default. Safe for cron/systemd timers.
# Use --interactive to enable reboot prompts and Docker shutdown.

set -euo pipefail
shopt -s nullglob

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

#######################################
# CONSTANTS & CONFIGURATION
#######################################
readonly SCRIPT_NAME="archOS Cleanup"
readonly SCRIPT_VERSION="4.0.1"

readonly DATA_DIR="/var/lib/archos-cleanup"
readonly SNAPSHOT_DIR="${DATA_DIR}/snapshots"

readonly SYSTEM_LOG_DIR="/var/log"
readonly VAR_TMP_DIR="/var/tmp"

readonly MAX_SNAPSHOTS=10
readonly LOG_RETENTION_DAYS=7
readonly CACHE_VERSIONS=3

ENABLE_BACKUPS=true
LOG_LEVEL="INFO"
DRY_RUN=false
SKIP_UPDATE=false
INTERACTIVE=false
LOG_FILE=""
AUR_USER=""

declare -A STATS=(
  [packages_before]=0
  [packages_after]=0
  [packages_removed]=0
  [updates_repo]=0
  [updates_aur]=0
  [error_count]=0
)

#######################################
# HELP & USAGE
#######################################
show_help() {
  cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Usage: $(basename "$0") [OPTIONS]

OPTIONS:
  -h, --help              Show this help message
  -v, --verbose           Enable verbose (DEBUG) logging
  -d, --dry-run           Perform dry run (no actual changes)
  -s, --skip-update       Skip system updates
  -n, --no-backups        Disable Btrfs snapshots
  -i, --interactive       Enable interactive mode (reboot prompt + Docker shutdown)
  -l, --log-file <path>   Also write log output to a file
  -V, --version           Show version information

EXAMPLES:
  $(basename "$0") --verbose                        # Run with debug output
  $(basename "$0") --dry-run                        # Preview what would be done
  $(basename "$0") -v -d                            # Verbose dry run
  $(basename "$0") --skip-update                    # Only clean, don't update
  $(basename "$0") --interactive                    # Prompt for reboot if needed
  $(basename "$0") -i -l /var/log/maintenance.log   # Interactive + log file

NOTE: Must be run as root (sudo).
      --interactive enables the reboot prompt and Docker Compose shutdown.
      Without it, reboot recommendations are logged but no action is taken.
EOF
  exit 0
}

show_version() {
  echo "$SCRIPT_NAME v$SCRIPT_VERSION"
  exit 0
}

#######################################
# ARGUMENT PARSING
#######################################
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help
        ;;
      -v|--verbose)
        LOG_LEVEL="DEBUG"
        ;;
      -d|--dry-run)
        DRY_RUN=true
        ;;
      -s|--skip-update)
        SKIP_UPDATE=true
        ;;
      -n|--no-backups)
        ENABLE_BACKUPS=false
        ;;
      -i|--interactive)
        INTERACTIVE=true
        ;;
      -l|--log-file)
        [[ $# -gt 1 ]] || { echo "Error: --log-file requires a path argument"; exit 1; }
        LOG_FILE="$2"
        shift
        ;;
      -V|--version)
        show_version
        ;;
      *)
        echo "Error: Unknown option '$1'"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
    shift
  done
}

#######################################
# LOGGING
#######################################
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
log() {
  local level="$1"; shift
  [[ ${LOG_LEVELS[$level]} -lt ${LOG_LEVELS[$LOG_LEVEL]} ]] && return
  local msg
  msg="$(date '+%F %T') [$level] $*"
  echo "$msg" >&2
  if [[ -n "$LOG_FILE" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}
debug(){ log DEBUG "$*"; }
info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
error(){ ((STATS[error_count]++)); log ERROR "$*"; }

#######################################
# SAFETY
#######################################
check_root() {
  [[ $EUID -eq 0 ]] || { echo "Must be run as root"; exit 1; }
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    AUR_USER="$SUDO_USER"
  else
    warn "SUDO_USER not set or is root — AUR updates will be skipped"
  fi
}

with_pacman_lock() {
  local lock="/var/lib/pacman/.cleanup.lock"
  debug "Acquiring pacman lock: $lock"
  exec {fd}>>"$lock"
  flock -w 300 "$fd"
  "$@"
  local rc=$?
  debug "Released pacman lock"
  exec {fd}>&-
  return $rc
}

#######################################
# UPDATE COUNTING (SANITIZED)
#######################################
check_pacman_lock() {
  if [[ -f /var/lib/pacman/db.lck ]]; then
    warn "Pacman database is locked by another process"
    return 1
  fi
  return 0
}

count_repo_updates() {
  debug "Counting repository updates..."
  check_pacman_lock || { echo 0; return; }

  local count output rc
  output=$(timeout 60 pacman -Qu 2>&1)
  rc=$?

  if [[ $rc -eq 124 ]]; then
    warn "Update check timed out after 60 seconds"
    echo 0
    return
  fi

  count=$(echo "$output" | grep -v "^::" | grep -v "^$" | wc -l | tr -d '[:space:]')
  [[ -z "$count" || "$count" == "0" ]] && count=0

  debug "Found $count repository updates (exit code: $rc)"
  echo "$count"
}

count_aur_updates() {
  debug "Counting AUR updates..."
  local count=0

  if command -v paru >/dev/null 2>&1; then
    count=$(timeout 30 sudo -u "$AUR_USER" paru -Qua 2>/dev/null | wc -l | tr -d '[:space:]') || count=0
  elif command -v yay >/dev/null 2>&1; then
    count=$(timeout 30 sudo -u "$AUR_USER" yay -Qua 2>/dev/null | wc -l | tr -d '[:space:]') || count=0
  fi

  echo "$count"
}

#######################################
# BTRFS SNAPSHOTS
#######################################
is_btrfs_root() {
  findmnt -n -o FSTYPE / | grep -qx btrfs
}

snapshot_prune() {
  debug "Pruning old snapshots (keeping $MAX_SNAPSHOTS)"
  local candidates
  mapfile -t candidates < <(ls -1d "${SNAPSHOT_DIR}"/pre-* 2>/dev/null | sort -r | tail -n +$((MAX_SNAPSHOTS + 1)))
  for path in "${candidates[@]}"; do
    if btrfs subvolume show "$path" &>/dev/null; then
      debug "Deleting old snapshot: $path"
      btrfs subvolume delete "$path"
    else
      warn "Non-subvolume entry found, removing: $path"
      rm -rf "$path"
    fi
  done
}

snapshot_pre() {
  $ENABLE_BACKUPS || return
  is_btrfs_root || { debug "Not on Btrfs, skipping snapshot"; return; }
  mkdir -p "$SNAPSHOT_DIR"
  local snap="${SNAPSHOT_DIR}/pre-$(date +%F_%H-%M-%S)"
  info "Creating pre-update snapshot: $snap"
  $DRY_RUN && { info "[DRY RUN] Would create: $snap"; return; }
  btrfs subvolume snapshot -r / "$snap"
  snapshot_prune
}

snapshot_post() {
  $ENABLE_BACKUPS || return
  is_btrfs_root || { debug "Not on Btrfs, skipping snapshot"; return; }
  local snap="${SNAPSHOT_DIR}/post-$(date +%F_%H-%M-%S)"
  info "Creating post-update snapshot: $snap"
  $DRY_RUN && { info "[DRY RUN] Would create: $snap"; return; }
  btrfs subvolume snapshot -r / "$snap"
}

#######################################
# DOCKER COMPOSE
#######################################
detect_compose_stacks() {
  debug "Detecting Docker Compose stacks..."
  if ! command -v docker >/dev/null 2>&1; then
    debug "Docker not installed, skipping"
    return
  fi

  docker ps -aq 2>/dev/null | while read -r container; do
    docker inspect "$container" 2>/dev/null \
      | grep -i "com.docker.compose.project.working_dir" \
      | awk -F'"' '{print $4}'
  done | sort -u
}

stop_compose_stacks() {
  local stacks
  stacks=$(detect_compose_stacks)

  if [[ -z "$stacks" ]]; then
    info "No Docker Compose stacks detected"
    return
  fi

  info "Stopping Docker Compose stacks before reboot..."
  while read -r dir; do
    local compose_file=""
    if [[ -f "$dir/docker-compose.yml" ]]; then
      compose_file="$dir/docker-compose.yml"
    elif [[ -f "$dir/compose.yml" ]]; then
      compose_file="$dir/compose.yml"
    fi

    if [[ -n "$compose_file" ]]; then
      info "Stopping stack in: $dir"
      if ! $DRY_RUN; then
        (cd "$dir" && docker compose down) || warn "Failed to stop stack in $dir"
      else
        info "[DRY RUN] Would stop stack in: $dir"
      fi
    else
      debug "No compose file found in $dir, skipping"
    fi
  done <<< "$stacks"
}

#######################################
# REBOOT DETECTION
#######################################
check_reboot_needed() {
  local current_kernel installed_kernel reboot_needed=0

  current_kernel=$(uname -r)

  # Try known CachyOS/Arch kernel packages in priority order
  local kernel_pkg=""
  for pkg in linux-cachyos linux-cachyos-lts linux linux-lts linux-zen linux-hardened; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      kernel_pkg="$pkg"
      break
    fi
  done

  if [[ -z "$kernel_pkg" ]]; then
    debug "Could not detect installed kernel package; skipping reboot check"
    echo 0
    return
  fi

  # Extract version (e.g. 6.12.4.cachyos-1 -> 6.12.4.cachyos)
  installed_kernel=$(pacman -Q "$kernel_pkg" 2>/dev/null | awk '{print $2}' | cut -d- -f1)

  debug "Running kernel: $current_kernel | Installed ($kernel_pkg): $installed_kernel"

  # Compare the installed version prefix against the running kernel string
  if [[ "$current_kernel" != *"$installed_kernel"* ]]; then
    reboot_needed=1
    debug "Kernel mismatch detected — reboot recommended"
  fi

  echo "$reboot_needed"
}

handle_reboot() {
  local reboot_needed
  reboot_needed=$(check_reboot_needed)

  if [[ "$reboot_needed" -eq 1 ]]; then
    if $INTERACTIVE; then
      warn "Kernel update detected — a reboot is recommended"
      read -rp "Reboot now? (Docker Compose stacks will be stopped first) (y/N): " choice
      if [[ "$choice" =~ ^[Yy]$ ]]; then
        stop_compose_stacks
        info "Rebooting system..."
        $DRY_RUN && { info "[DRY RUN] Would reboot now"; return; }
        reboot
      else
        info "Reboot skipped by user"
      fi
    else
      warn "Kernel update detected — reboot recommended (run with --interactive to be prompted)"
    fi
  else
    info "No reboot required"
  fi
}

#######################################
# CORE FUNCTIONS
#######################################
sync_databases() {
  debug "Syncing package databases..."
  if ! $DRY_RUN; then
    timeout 60 pacman -Sy --noconfirm 2>/dev/null || {
      warn "Failed to sync package databases"
      return 1
    }
  fi
  return 0
}

update_repo_packages() {
  if (( STATS[updates_repo] > 0 )); then
    info "Updating ${STATS[updates_repo]} repo package(s)..."
    with_pacman_lock pacman -Su --noconfirm
  else
    info "No repo updates to apply"
  fi
}

update_aur_packages() {
  if (( STATS[updates_aur] == 0 )); then
    info "No AUR updates to apply"
    return
  fi

  info "Updating ${STATS[updates_aur]} AUR package(s)..."

  # -Sua = AUR-only update (don't redo repo packages we already updated)
  if command -v paru >/dev/null 2>&1; then
    sudo -u "$AUR_USER" paru -Sua --noconfirm || warn "paru AUR update encountered errors"
  elif command -v yay >/dev/null 2>&1; then
    sudo -u "$AUR_USER" yay -Sua --noconfirm || warn "yay AUR update encountered errors"
  else
    debug "No AUR helper found; skipping AUR updates"
  fi
}

update_system() {
  if $SKIP_UPDATE; then
    info "Skipping system updates (--skip-update)"
    return
  fi

  sync_databases || {
    warn "Skipping update check due to sync failure"
    return
  }

  debug "Checking for system updates..."
  STATS[updates_repo]=$(count_repo_updates)
  STATS[updates_aur]=$(count_aur_updates)

  # Defensive numeric coercion
  STATS[updates_repo]=$((STATS[updates_repo] + 0))
  STATS[updates_aur]=$((STATS[updates_aur] + 0))

  info "Repo updates available: ${STATS[updates_repo]}"
  info "AUR updates available:  ${STATS[updates_aur]}"

  if $DRY_RUN; then
    info "[DRY RUN] Would update ${STATS[updates_repo]} repo + ${STATS[updates_aur]} AUR packages"
    return
  fi

  snapshot_pre
  update_repo_packages
  update_aur_packages
  snapshot_post
}

clean_cache() {
  info "Cleaning package cache (keeping $CACHE_VERSIONS versions)..."
  $DRY_RUN && { info "[DRY RUN] Would run: paccache -r -k$CACHE_VERSIONS"; return; }
  with_pacman_lock paccache -r -k"$CACHE_VERSIONS" || true
}

remove_orphans() {
  debug "Checking for orphaned packages..."
  local orphans
  orphans=$(pacman -Qtdq 2>/dev/null || true)
  if [[ -z "$orphans" ]]; then
    debug "No orphaned packages found"
    return
  fi
  local count
  count=$(echo "$orphans" | wc -l)
  info "Found $count orphaned package(s)"
  $DRY_RUN && { info "[DRY RUN] Would remove: $(echo "$orphans" | tr '\n' ' ')"; return; }
  # shellcheck disable=SC2086
  with_pacman_lock pacman -Rns --noconfirm $orphans
}

clean_logs() {
  info "Cleaning old log files (older than $LOG_RETENTION_DAYS days)..."
  $DRY_RUN && { info "[DRY RUN] Would clean logs older than $LOG_RETENTION_DAYS days"; return; }
  find "$SYSTEM_LOG_DIR" -type f -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  journalctl --vacuum-time="${LOG_RETENTION_DAYS}d" 2>/dev/null || true
}

clean_user_cache() {
  info "Cleaning user cache directories..."
  $DRY_RUN && { info "[DRY RUN] Would clean temporary files"; return; }
  systemd-tmpfiles --clean || true
  find "$VAR_TMP_DIR" -type f -mtime +7 -delete 2>/dev/null || true
}

#######################################
# EXECUTION
#######################################
main() {
  parse_args "$@"

  # Initialize log file if specified
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" || { echo "Cannot write to log file: $LOG_FILE"; exit 1; }
    info "Logging to file: $LOG_FILE"
  fi

  check_root

  info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
  $DRY_RUN    && warn "DRY RUN MODE — No changes will be made"
  $INTERACTIVE && info "Interactive mode enabled"
  $ENABLE_BACKUPS || warn "Backups disabled"
  debug "Log level: $LOG_LEVEL"

  STATS[packages_before]=$(pacman -Q | wc -l | tr -d '[:space:]')
  debug "Current package count: ${STATS[packages_before]}"

  update_system
  clean_cache
  remove_orphans
  clean_logs
  clean_user_cache

  STATS[packages_after]=$(pacman -Q | wc -l | tr -d '[:space:]')
  STATS[packages_removed]=$((STATS[packages_before] - STATS[packages_after]))

  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Summary:"
  info "  Repo updates applied:   ${STATS[updates_repo]}"
  info "  AUR updates applied:    ${STATS[updates_aur]}"
  info "  Packages removed:       ${STATS[packages_removed]}"
  info "  Errors encountered:     ${STATS[error_count]}"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Cleanup complete"

  # Reboot check always runs; prompt only in interactive mode
  handle_reboot
}

main "$@"
