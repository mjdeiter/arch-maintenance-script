#!/bin/bash
# archOS / CachyOS System Cleanup and Update Script - ENTERPRISE EDITION
# Version: 4.2.17
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
#   - Broken shared library scan with timed interactive prompt (--skip-broken-links)
#
# v4.2.17 additions:
# - check_pydantic_compat(): after tonight's incident where a system Python
#   version bump silently broke pydantic/pydantic-core for elitebook-exec and
#   llm-memory, and a separate cachetools/py-key-value-aio[memory] gap
#   crash-looped letta-mcp-http, neither was caught until the services were
#   already down. This check tries importing each known service's
#   compiled-extension modules under the current python3 and warns before
#   they crash-loop, instead of after.
# - check_port_conflicts(): now tails the last journalctl error line (or last
#   log line if none at err level) for any flagged crash-looping unit, so a
#   flagged service comes with an actual pointer instead of requiring a
#   manual journalctl dig every time.
#
# v4.2.16 fix:
# - check_root(): AUR_USER fallback only covered the sudo-invocation path
#   (SUDO_USER). A bare `--dry-run` with no sudo at all left AUR_USER empty
#   even though a real non-root user was running it. Added a fallback to
#   $USER/$LOGNAME when not root and SUDO_USER is unset, so AUR checks work
#   on this single-user machine regardless of invocation style. Does not
#   apply when actually running as root (e.g. root cron) with no SUDO_USER.
#
# v4.2.15 fix:
# - check_root(): AUR_USER detection from SUDO_USER was only reached after
#   the dry-run early-return, so --dry-run could never report AUR updates
#   even when invoked via sudo. Moved SUDO_USER detection ahead of the
#   dry-run check.
# - sync_databases(): pacman -Sy requires root to write the synced DB
#   files. When the script was invoked without sudo (including plain
#   --dry-run runs), the sync failed silently (stderr suppressed) and the
#   entire update check was skipped with no indication why. Now falls back
#   to non-interactive `sudo -n` when EUID != 0.
#
# v4.2.14 fix:
# - Reduced MAX_SNAPSHOTS from 10 to 3 (pre/post rollback subvols under
#   SNAPSHOT_DIR). These are a second, separate set of full read-only Btrfs
#   subvolumes layered on top of snapper's own pre/post snapshots of the
#   same pacman transactions -- snapper already covers durable rollback
#   history (NUMBER_LIMIT=15, correctly pruning). The script's own subvols
#   only need to cover "did the last run itself break something," not deep
#   history, and every extra one adds to Btrfs metadata-tree overhead.
#   Found while investigating metadata usage sitting at 90.64% (same
#   signature as the July 11 nested-subvolume incident, though this time
#   snapper cleanup was completing successfully -- just generic churn from
#   accumulated snapshot count). Existing excess subvols pruned manually
#   same day, followed by a metadata-targeted balance.
#
# v4.2.13 fix:
# - scan_broken_links(): excluded /usr/share/kicad/ from the pacman-Ql file
#   list BEFORE the `file -L` pass, via a new SCAN_EXCLUDE_PATHS prefilter.
#   KiCad's footprint/symbol libraries add tens of thousands of small
#   non-ELF files that were previously run through `file -L` anyway before
#   being dropped by the ELF filter. Note: this is a different mechanism
#   from SENTRY_IGNORE_PATHS below, which only skips ldd checks on files
#   already confirmed to be ELF -- that array can't speed up this step
#   because the expensive part (file -L on every pacman-owned file) already
#   ran before it's consulted.
#
# v4.2.12 fix:
# - scan_broken_links(): added /opt/zen-browser-bin/ and /usr/lib/floorp/ to
#   SENTRY_IGNORE_PATHS. Both are Gecko-based browsers whose bundled libs
#   (libgkcodecs.so, libmozavutil.so, libmozsqlite3.so, libmozgtk.so,
#   libmozsandbox.so, libmozwayland.so, liblgpllibs.so) resolve at runtime via
#   xul.so's internal relative loading, not ld.so's default search path --
#   same false-positive pattern as the wine/syslinux/systemd entries below.
#
# v4.2.11 fixes:
# - update_repo_packages(): added STATS[repo_applied], tracked separately from
#   STATS[updates_repo] (which is the pre-run available count). Previously the
#   summary printed the available count as "applied" even when the pacman
#   transaction failed outright (e.g. untrusted-key abort) and 0 packages were
#   actually installed. Summary and rolling-log now report repo_applied.
# - scan_broken_links(): added /usr/lib/syslinux/ and /usr/lib/systemd/ to
#   SENTRY_IGNORE_PATHS. syslinux .c32 modules use their own COM32 loader, not
#   ld.so, and systemd's private plugin libs (e.g. libsystemd-core ->
#   libsystemd-shared) resolve via $ORIGIN at runtime despite living outside
#   ld.so's default search path. Both were previously flagged as false-positive
#   broken links on every run.
#
# v4.2.10 fix:
# - update_repo_packages() call in update_system() is now only reached through
#   an outer guarded call (update_system || { ... continue ... }), so a pacman
#   failure no longer aborts AUR updates / BIOS check / Alexa check / cleanup.
#
# v4.2.9 fix:
# - check_btrfs_health(): orphaned-subvolume grep pipeline appended with `|| true`
#   so a no-match result (exit 1) no longer aborts the script under set -e.
#
# v4.2.7 additions:
# - check_alexa_media_patch(): verifies the alexa_media custom_components
#   update_last_called() no-op patch (workaround for upstream issue #3019/#3132,
#   TypeError: Cannot serialize non-str key None) is still present on the HA host
#   (192.168.4.222). If a HACS update overwrote it, reruns reapply_patch.sh
#   remotely and flags that an HA core restart is needed.
#
# v4.2.5 fix:
# - scan_broken_links(): added /usr/lib/wine/ to SENTRY_IGNORE_PATHS. Wine's
#   x86_64-unix .so files reference ntdll.so/win32u.so internally rather than
#   via ld.so's default search path, flagging as a false-positive broken link
#   on every run.
# - check_bios_update(): added timeout 30 to fwupdmgr get-updates, which could
#   hang indefinitely with no network path to HP's firmware catalog.
# - Dry-run hardening: BIOS check now skips cleanly without root, snapshot
#   directory creation guarded against already existing.
#
# v4.1.3 additions:
# - resolve_aur_dep_conflicts(): auto-detects AUR pkgs blocking repo soname bumps,
#   rebuilds via yay, retries pacman -Su on success
# - pacman -Su call wrapped with dep-conflict stderr capture + retry logic
#
# v4.1.1 fixes:
#   - error(): ((STATS[error_count]++)) caused set -e exit when counter was 0
#   - with_pacman_lock: flock timeout now returns early instead of silently proceeding
#   - count_aur_updates: guard against empty AUR_USER to avoid sudo -u "" errors
#   - remove_orphans: replaced unsafe $orphans word-split with mapfile + array expansion
#   - version_gt: replaced fragile local IFS=. array expansion with read -ra
#   - get_hp_platform_id: eliminated UUOC (cat file | tr → tr < file)
#
# No interactive prompts by default. Safe for cron/systemd timers.
# Use --interactive to enable reboot/scan prompts and Docker shutdown.

set -euo pipefail
shopt -s nullglob

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

#######################################
# CONSTANTS & CONFIGURATION
#######################################
readonly SCRIPT_NAME="archOS Cleanup"
readonly SCRIPT_VERSION="4.2.17"

readonly DATA_DIR="/var/lib/archos-cleanup"
readonly SNAPSHOT_DIR="${DATA_DIR}/snapshots"
readonly AUTO_LOG_DIR="/var/log/archos-cleanup"

readonly SYSTEM_LOG_DIR="/var/log"
readonly VAR_TMP_DIR="/var/tmp"

readonly MAX_SNAPSHOTS=3
readonly LOG_RETENTION_DAYS=7
readonly CACHE_VERSIONS=3

# HP BIOS update settings
readonly HP_DEVFW_PATH="/boot/EFI/HP/DEVFW"
readonly HP_FTP_BASE="https://ftp.hp.com/pub"

ENABLE_BACKUPS=true
LOG_LEVEL="INFO"
DRY_RUN=false
SKIP_UPDATE=false
SKIP_BIOS_CHECK=false
SKIP_BROKEN_LINKS=false
IGNORE_PKGS=()  # packages to pass to pacman --ignore
INTERACTIVE=false
LOG_FILE=""
AUTO_LOG_FILE=""
AUR_USER=""
BIOS_UPDATE_STAGED=false

declare -A STATS=(
  [packages_before]=0
  [packages_after]=0
  [packages_removed]=0
  [updates_repo]=0
  [repo_applied]=0
  [updates_aur]=0
  [bios_staged]=0
  [dkms_rebuilt]=0
  [alexa_patch_reapplied]=0
  [pydantic_issues]=0
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
      --skip-bios-check   Skip HP BIOS update check
      --skip-broken-links Skip broken shared library scan (also skips the prompt)
  -i, --ignore-pkg PKG  Skip a package during update (repeatable; comma-sep ok)
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
      --skip-bios-check)
        SKIP_BIOS_CHECK=true
        ;;
      --skip-broken-links)
        SKIP_BROKEN_LINKS=true
        ;;
      -i|--ignore-pkg)
        [[ $# -gt 1 ]] || { echo "Error: --ignore-pkg requires a package name"; exit 1; }
        IFS="," read -ra _pkgs <<< "$2"
        IGNORE_PKGS+=("${_pkgs[@]}")
        shift
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
  if [[ -n "$AUTO_LOG_FILE" ]]; then
    echo "$msg" >> "$AUTO_LOG_FILE"
  fi
  if [[ -n "$LOG_FILE" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}
debug(){ log DEBUG "$*"; }
info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
error(){
  local _ec=$(( STATS[error_count] + 1 ))
  STATS[error_count]=$_ec
  log ERROR "$*"
}

#######################################
# SAFETY
#######################################
check_root() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    AUR_USER="$SUDO_USER"
  elif [[ $EUID -ne 0 && -n "${USER:-${LOGNAME:-}}" && "${USER:-${LOGNAME:-}}" != "root" ]]; then
    # v4.2.16: not invoked via sudo (e.g. bare --dry-run) — fall back to the
    # invoking non-root user so AUR checks still work on this single-user box.
    AUR_USER="${USER:-${LOGNAME}}"
  fi
  $DRY_RUN && { warn "Dry-run mode: skipping root check"; return; }
  [[ $EUID -eq 0 ]] || { echo "Must be run as root"; exit 1; }
  if [[ -z "$AUR_USER" ]]; then
    warn "SUDO_USER not set or is root — AUR updates will be skipped"
  fi
}

with_pacman_lock() {
  local lock="/var/lib/pacman/.cleanup.lock"
  debug "Acquiring pacman lock: $lock"
  exec {fd}>>"$lock"
  flock -w 300 "$fd" || { warn "Timed out waiting for pacman lock"; exec {fd}>&-; return 1; }
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

  if [[ -z "$AUR_USER" ]]; then
    debug "No AUR_USER set; skipping AUR update count"
    echo 0
    return
  fi

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
  debug "Pruning old snapshots (keeping $MAX_SNAPSHOTS of each type)"
  local prefix candidates
  for prefix in pre post; do
    mapfile -t candidates < <(ls -1d "${SNAPSHOT_DIR}/${prefix}-"* 2>/dev/null | sort -r | tail -n +$((MAX_SNAPSHOTS + 1)))
    for path in "${candidates[@]}"; do
      if btrfs subvolume show "$path" &>/dev/null; then
        debug "Deleting old snapshot: $path"
        btrfs subvolume delete "$path"
      else
        warn "Non-subvolume entry found, removing: $path"
        rm -rf "$path"
      fi
    done
  done
}

snapshot_pre() {
  $ENABLE_BACKUPS || return
  is_btrfs_root || { debug "Not on Btrfs, skipping snapshot"; return; }
  local snap="${SNAPSHOT_DIR}/pre-$(date +%F_%H-%M-%S)"
  info "Creating pre-update snapshot: $snap"
  $DRY_RUN && { info "[DRY RUN] Would create: $snap"; return; }
  mkdir -p "$SNAPSHOT_DIR"
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
# CORAL TPU DKMS CHECK
#######################################
# After a kernel upgrade the gasket/apex DKMS modules must be rebuilt or
# /dev/apex_0 will be absent at next boot and Frigate will crash-loop.
# This runs automatically when a kernel mismatch is detected.
#
# HISTORICAL NOTE (resolved 2026-08-30): kernel 7.1.1 briefly broke
# gasket/apex DKMS by removing the zap_vma_ptes() symbol the driver
# relied on. /etc/pacman.conf carried an IgnorePkg hold on
# linux-cachyos/linux-cachyos-headers as a workaround from then until
# 2026-08-30. The gasket-dkms-git AUR package was patched upstream on
# 2026-07-27 (commit b1c1958) to use zap_special_vma_range on newer
# kernels with a fallback to zap_vma_ptes on older ones, so the fix now
# lives in the driver itself and isn't tied to holding back a specific
# kernel version. The IgnorePkg hold was removed 2026-08-30 — this
# function's normal DKMS-rebuild-on-mismatch handling is expected to be
# sufficient going forward; no kernel pin should be needed again for
# this reason.
check_coral_dkms() {
  local kernel
  kernel=$(uname -r)

  # Check if gasket is registered with DKMS at all
  if ! dkms status gasket 2>/dev/null | grep -q "gasket/"; then
    debug "CORAL: gasket not registered with DKMS — skipping"
    return
  fi

  # Check if modules are already built for the installed kernel
  local installed_kernel
  installed_kernel=$(pacman -Q linux-cachyos 2>/dev/null | awk '{print $2}' | cut -d- -f1)
  if [[ -z "$installed_kernel" ]]; then
    debug "CORAL: Cannot detect installed kernel version — skipping DKMS check"
    return
  fi

  local dkms_ver
  dkms_ver=$(dkms status gasket 2>/dev/null | awk -F'[/,: ]+' '{print $2}' | head -1)

  # Check for modules built specifically for the RUNNING kernel, not any kernel.
  # After a reboot into a new kernel, dkms may show "installed" for the OLD kernel
  # and incorrectly skip the rebuild — grep for the current kernel string explicitly.
  if dkms status "gasket/${dkms_ver}" 2>/dev/null | grep -q "${kernel}.*installed"; then
    info "CORAL: gasket/${dkms_ver} already installed for kernel ${kernel} — skipping"
    return
  fi

  # Secondary: confirm .ko files actually exist on disk for this kernel
  if [[ -f "/usr/lib/modules/${kernel}/updates/dkms/gasket.ko.zst" ]] || \
     [[ -f "/usr/lib/modules/${kernel}/updates/dkms/gasket.ko" ]]; then
    info "CORAL: gasket .ko present on disk for ${kernel} — skipping rebuild"
    return
  fi

  info "CORAL: gasket/${dkms_ver} not built for kernel ${kernel} — rebuilding now..."
  $DRY_RUN && { info "[DRY RUN] Would run: dkms install gasket/${dkms_ver} -k ${kernel}"; return; }

  if sudo dkms install "gasket/${dkms_ver}" -k "$kernel" 2>&1 | while IFS= read -r line; do debug "CORAL: $line"; done; then
    info "CORAL: Build succeeded — loading modules"
    sudo modprobe gasket 2>/dev/null && sudo modprobe apex 2>/dev/null || warn "CORAL: modprobe failed — modules will load on next boot"
    local _r=$(( STATS[dkms_rebuilt] + 1 ))
    STATS[dkms_rebuilt]=$_r
  else
    warn "CORAL: DKMS build failed — /dev/apex_0 will be absent after reboot until manually rebuilt"
  fi
}

#######################################
# REMOTE: HOME ASSISTANT ALEXA_MEDIA PATCH
#######################################
check_alexa_media_patch() {
  local ha_host="root@192.168.4.222"
  local patch_script="/homeassistant/custom_components/alexa_media/reapply_patch.sh"
  local ha_label="192.168.4.222"

  debug "ALEXA: Checking alexa_media update_last_called patch on ${ha_label}"

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ha_host" "test -x '$patch_script'" 2>/dev/null; then
    warn "ALEXA: Cannot reach ${ha_label} (or reapply_patch.sh missing) — skipping"
    return
  fi

  if $DRY_RUN; then
    info "[DRY RUN] Would run reapply_patch.sh on ${ha_label}"
    return
  fi

  local _output
  if ! _output=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ha_host" "$patch_script" 2>&1); then
    warn "ALEXA: reapply_patch.sh exited non-zero on ${ha_label} — manual check needed:"
    while IFS= read -r line; do warn "ALEXA: $line"; done <<< "$_output"
    return
  fi

  if echo "$_output" | grep -q "already present"; then
    debug "ALEXA: update_last_called patch already in place — no action needed"
  else
    warn "ALEXA: alexa_media patch was missing on ${ha_label} and has been reapplied (likely overwritten by a HACS update) — HA core restart required to take effect"
    while IFS= read -r line; do info "ALEXA: $line"; done <<< "$_output"
    local _r=$(( STATS[alexa_patch_reapplied] + 1 ))
    STATS[alexa_patch_reapplied]=$_r
  fi
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

  # Also flag reboot if a BIOS update was staged
  if $BIOS_UPDATE_STAGED; then
    reboot_needed=1
    warn "HP BIOS update staged — reboot required, then F10 → Update System BIOS"
  fi

  if [[ "$reboot_needed" -eq 1 ]]; then
    check_coral_dkms
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
  # Always sync DB even in dry-run — it is read-only and needed for accurate update counts
  # v4.2.15 fix: pacman -Sy requires root to write synced DB files. In dry-run
  # mode (or if invoked without sudo generally) EUID may not be 0, in which
  # case the sync silently failed and the whole update check was skipped.
  # Fall back to sudo -n (non-interactive) when not already root.
  local sync_cmd=(pacman -Sy --noconfirm)
  if [[ $EUID -ne 0 ]]; then
    sync_cmd=(sudo -n pacman -Sy --noconfirm)
  fi
  if ! timeout 60 "${sync_cmd[@]}" 2>/dev/null; then
    warn "Failed to sync package databases"
    return 1
  fi
  return 0
}


# -----------------------------------------------------------------------------
# resolve_aur_dep_conflicts [v4.1.3]
# Parses pacman dep-conflict stderr, identifies AUR-only offenders, rebuilds
# them via yay against freshly updated repo libs (e.g. boost/openssl soname
# bumps). Returns 0 if ≥1 package was rebuilt so the caller can retry.
# -----------------------------------------------------------------------------
resolve_aur_dep_conflicts() {
  local pacman_stderr="$1"

  local conflict_pkgs
  conflict_pkgs=$(echo "$pacman_stderr"     | grep -oP "required by \K[a-zA-Z0-9@._+\-]+"     | sort -u)

  if [[ -z "$conflict_pkgs" ]]; then
    warn "Dep-conflict detected but could not parse offending package names"
    return 1
  fi

  local aur_pkgs=()
  while IFS= read -r pkg; do
    if ! pacman -Si "$pkg" &>/dev/null; then
      aur_pkgs+=("$pkg")
    fi
  done <<< "$conflict_pkgs"

  if [[ ${#aur_pkgs[@]} -eq 0 ]]; then
    warn "Dep-conflict packages are all from repos — cannot auto-resolve"
    return 1
  fi

  info "AUR dep-conflict: rebuilding [${aur_pkgs[*]}] against new repo libs..."
  local rebuilt=0
  for pkg in "${aur_pkgs[@]}"; do
    debug "  yay --rebuild $pkg"
    if sudo -u "$AUR_USER" yay -S --rebuild --noconfirm --noprogressbar "$pkg"; then
      info "  [OK] $pkg rebuilt successfully"
      (( rebuilt++ )) || true
    else
      warn "  [FAIL] Could not rebuild $pkg — skipping"
    fi
  done

  [[ $rebuilt -gt 0 ]]
}
update_repo_packages() {
  if (( STATS[updates_repo] > 0 )); then
    info "Updating ${STATS[updates_repo]} repo package(s)..."
    # v4.1.3: dep-conflict auto-rebuild wrapper
    # pacman writes dep-resolution errors to stdout. We tee both streams to a
    # tempfile for post-run parsing while still showing output live.
    # set +e guards the pipeline so set -euo pipefail doesn't kill the script
    # before we can inspect the exit code and captured output.
    local _pac_tmp _pac_rc=0
    _pac_tmp=$(mktemp /tmp/pacman-upgrade.XXXXXX)
    set +e
    local _ignore_flag=""
    if [[ ${#IGNORE_PKGS[@]} -gt 0 ]]; then
      _ignore_flag="--ignore $(IFS=,; echo "${IGNORE_PKGS[*]}")"
      info "Ignoring packages: ${IGNORE_PKGS[*]}"
    fi
    LANG=C with_pacman_lock pacman -Su --noconfirm $_ignore_flag 2>&1 | tee "$_pac_tmp"
    _pac_rc=${PIPESTATUS[0]}
    set -e
    local _pac_output
    _pac_output=$(cat "$_pac_tmp")
    rm -f "$_pac_tmp"
    if [[ $_pac_rc -ne 0 ]]; then
      if echo "$_pac_output" | grep -q "could not satisfy dependencies"; then
        warn "Dep-conflict detected — attempting AUR auto-rebuild..."
        if resolve_aur_dep_conflicts "$_pac_output"; then
          info "Rebuild succeeded — retrying repo upgrade..."
          with_pacman_lock pacman -Su --noconfirm $_ignore_flag
          STATS[repo_applied]=${STATS[updates_repo]}
        else
          warn "Auto-rebuild failed — manual intervention required"
          return 1
        fi
      else
        warn "pacman upgrade failed (rc=$_pac_rc)"
        return 1
      fi
    else
      STATS[repo_applied]=${STATS[updates_repo]}
    fi
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
    local _dry_ignore=""
    [[ ${#IGNORE_PKGS[@]} -gt 0 ]] && _dry_ignore=" (ignoring: ${IGNORE_PKGS[*]})"
    info "[DRY RUN] Would update ${STATS[updates_repo]} repo + ${STATS[updates_aur]} AUR packages${_dry_ignore}"
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
  # Read into array to avoid word-splitting surprises
  local -a orphan_list
  mapfile -t orphan_list <<< "$orphans"
  # shellcheck disable=SC2086
  with_pacman_lock pacman -Rns --noconfirm "${orphan_list[@]}"
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
# HP BIOS UPDATE CHECK
#######################################

# Compare two dot-separated version strings. Returns 0 if $1 > $2.
version_gt() {
  local ver_a="$1" ver_b="$2"
  local -a a b
  IFS='.' read -ra a <<< "$ver_a"
  IFS='.' read -ra b <<< "$ver_b"
  local i
  for ((i=0; i<${#a[@]}; i++)); do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 1
}

get_current_bios_version() {
  dmidecode -t bios 2>/dev/null \
    | grep "Version:" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1
}

# Get HP's 4-char platform hex ID from DMI.
# Commercial HP systems store it in product_sku (e.g. "96J89AV" -> first 4 hex chars elsewhere,
# or directly in board product). Falls back to chassis-asset-tag if needed.
get_hp_platform_id() {
  local candidate

  # Preferred source: /sys/class/dmi/id/product_sku — on HP commercial this is often
  # something like "96J89AV#ABA". The platform hex code is a separate value stored in
  # the chassis asset tag on some models.
  candidate=$(tr -d '[:space:]' < /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || true)
  if echo "$candidate" | grep -qiE '^[0-9a-f]{4}$'; then
    echo "$candidate" | tr '[:upper:]' '[:lower:]'
    return
  fi

  # Some HP systems expose it via board_product
  candidate=$(tr -d '[:space:]' < /sys/class/dmi/id/board_product 2>/dev/null || true)
  if echo "$candidate" | grep -qiE '^[0-9a-f]{4}$'; then
    echo "$candidate" | tr '[:upper:]' '[:lower:]'
    return
  fi

  # Last resort: read from dmidecode System Information SKU
  candidate=$(dmidecode -t 1 2>/dev/null | awk -F': ' '/SKU Number/{print $2}' | tr -d '[:space:]')
  echo "$candidate" | tr '[:upper:]' '[:lower:]'
}

# Download HP's imagepal reference catalog for this platform and extract BIOS info.
# Outputs "VERSION SP_URL" on success, empty string on failure.
fetch_hp_bios_catalog() {
  local platform_id="$1"
  local work_dir="$2"

  # HP names their catalog CABs with OS version suffixes; try most likely ones in order
  local found_cab=false
  for os_tag in win11 w11 win10; do
    local url="${HP_FTP_BASE}/caps-softpaq/cmit/imagepal/ref/${platform_id}/${platform_id}_64_${os_tag}.cab"
    debug "BIOS: Trying catalog URL: $url"
    if curl -sf --max-time 30 -L "$url" -o "${work_dir}/ref.cab" 2>/dev/null; then
      found_cab=true
      debug "BIOS: Found catalog at $url"
      break
    fi
  done

  $found_cab || { debug "BIOS: No catalog found for platform ${platform_id}"; echo ""; return; }

  # Extract CAB using 7z (already installed)
  if ! 7z e "${work_dir}/ref.cab" -o"${work_dir}/extracted" -y >/dev/null 2>&1; then
    warn "BIOS: Failed to extract HP catalog CAB"
    echo ""
    return
  fi

  local xml_file
  xml_file=$(find "${work_dir}/extracted" -name "*.xml" 2>/dev/null | head -1)
  if [[ -z "$xml_file" ]]; then
    warn "BIOS: No XML found in HP catalog"
    echo ""
    return
  fi

  debug "BIOS: Parsing catalog XML: $xml_file"

  # Extract the BIOS softpaq entry. HP's XML uses various tag names across versions
  # so we match broadly on category=BIOS and pull the nearest version + URL/ID.
  local bios_section
  bios_section=$(grep -i -A 20 -B 2 'BIOS' "$xml_file" 2>/dev/null | head -60)

  local bios_version
  bios_version=$(echo "$bios_section" | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{2}' | sort -V | tail -1)

  # Try to find a direct download URL in the XML first
  local bios_url
  bios_url=$(echo "$bios_section" | grep -oE 'https://ftp\.hp\.com/pub/softpaq/[^"<>]+\.exe' | head -1)

  # If no URL in XML, derive it from the softpaq ID
  if [[ -z "$bios_url" ]]; then
    local sp_id
    sp_id=$(echo "$bios_section" | grep -oiE 'sp[0-9]{5,6}' | head -1 | tr '[:upper:]' '[:lower:]')
    if [[ -n "$sp_id" ]]; then
      local sp_num="${sp_id#sp}"
      local range_low=$(( (sp_num / 500) * 500 ))
      local range_high=$(( range_low + 499 ))
      bios_url="${HP_FTP_BASE}/softpaq/sp${range_low}-${range_high}/${sp_id}.exe"
    fi
  fi

  if [[ -n "$bios_version" && -n "$bios_url" ]]; then
    echo "${bios_version} ${bios_url}"
  else
    debug "BIOS: Could not parse version/URL from catalog (version='${bios_version}' url='${bios_url}')"
    echo ""
  fi
}

stage_bios_update() {
  local softpaq_url="$1"
  local work_dir="$2"

  info "BIOS: Downloading SoftPaq: $(basename "$softpaq_url")..."
  local exe_file="${work_dir}/bios_softpaq.exe"
  if ! curl -L --max-time 300 --progress-bar "$softpaq_url" -o "$exe_file" 2>/dev/null; then
    warn "BIOS: Download failed (URL: $softpaq_url)"
    return 1
  fi

  info "BIOS: Extracting SoftPaq..."
  local extract_dir="${work_dir}/extracted_sp"
  if ! 7z x "$exe_file" -o"$extract_dir" -y >/dev/null 2>&1; then
    warn "BIOS: SoftPaq extraction failed"
    return 1
  fi

  local bin_file
  bin_file=$(find "$extract_dir" -name "*.bin" | head -1)
  if [[ -z "$bin_file" ]]; then
    warn "BIOS: No .bin file found in SoftPaq"
    return 1
  fi

  info "BIOS: Staging firmware to ${HP_DEVFW_PATH}/firmware.bin..."
  if ! mkdir -p "$HP_DEVFW_PATH"; then
    warn "BIOS: Cannot create ${HP_DEVFW_PATH} (ESP not mounted?)"
    return 1
  fi

  cp "$bin_file" "${HP_DEVFW_PATH}/firmware.bin"
  BIOS_UPDATE_STAGED=true
  STATS[bios_staged]=1
  info "BIOS: Update staged. On next boot: F10 → Update System BIOS to apply."
  return 0
}

check_port_conflicts() {
  info "Checking for crash-looping services caused by port conflicts..."

  local failed_units unit restarts port_line last_err
  failed_units=$(systemctl list-units --type=service --state=running,failed --no-legend --plain 2>/dev/null | awk '{print $1}')

  local flagged=0
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    restarts=$(systemctl show "$unit" -p NRestarts --value 2>/dev/null)
    if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= 5 )); then
      port_line=$(journalctl -u "$unit" -n 50 --no-pager 2>/dev/null | grep -i "address already in use" | tail -1)

      # v4.2.17: tail the last actual error line so a flagged unit comes with
      # a concrete pointer instead of requiring a manual journalctl dig every
      # time. Prefer the last err-priority line; fall back to the last log
      # line if nothing was logged at err level.
      last_err=$(journalctl -u "$unit" -n 50 --no-pager -p err 2>/dev/null | tail -1)
      [[ -z "$last_err" ]] && last_err=$(journalctl -u "$unit" -n 5 --no-pager 2>/dev/null | tail -1)

      if [[ -n "$port_line" ]]; then
        warn "Port conflict detected: $unit has restarted $restarts times - $port_line"
        STATS[port_conflicts]=$(( ${STATS[port_conflicts]:-0} + 1 ))
        flagged=1
      elif (( restarts >= 15 )); then
        warn "Service $unit has restarted $restarts times with no port conflict message - investigate manually"
        [[ -n "$last_err" ]] && warn "  last log line: $last_err"
        STATS[port_conflicts]=$(( ${STATS[port_conflicts]:-0} + 1 ))
        flagged=1
      fi
    fi
  done <<< "$failed_units"

  if (( flagged == 0 )); then
    debug "No crash-looping services detected"
  else
    warn "Port/crash-loop check flagged $flagged service(s) - check for duplicate system+user level units (see elitebook-exec incident 2026-07-08)"
  fi
}

#######################################
# PYTHON / PIP COMPATIBILITY CHECK
#######################################
# A system Python version bump can silently break --user-installed pip
# packages with compiled C extensions (pydantic-core, cachetools, etc.) that
# were built against the old CPython ABI. This surfaced on 2026-09-15: a
# Python 3.14 bump broke pydantic/pydantic-core for elitebook-exec and
# llm-memory, and a separate cachetools/py-key-value-aio[memory] gap
# crash-looped letta-mcp-http. Neither was caught until the services were
# already down. This tries importing each known service's modules under the
# current python3 and flags anything that fails before it becomes a
# crash loop.
check_pydantic_compat() {
  info "Checking Python/pip compatibility for pip-dependent services..."

  local current_py
  current_py=$(python3 --version 2>&1)
  debug "PYCHECK: Running python3: $current_py"

  # Service name -> space-separated list of its compiled-extension imports.
  local -A PY_SERVICE_MODULES=(
    [elitebook-exec.service]="pydantic pydantic_core"
    [llm-memory.service]="pydantic pydantic_core"
    [letta-mcp-http.service]="cachetools"
  )

  local flagged=0
  local svc modules mod
  for svc in "${!PY_SERVICE_MODULES[@]}"; do
    if ! systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
      debug "PYCHECK: $svc not installed on this host — skipping"
      continue
    fi

    modules="${PY_SERVICE_MODULES[$svc]}"
    for mod in $modules; do
      if ! python3 -c "import ${mod}" >/dev/null 2>&1; then
        warn "PYCHECK: $svc depends on '$mod', which fails to import under $current_py — will crash-loop on next start/restart"
        STATS[pydantic_issues]=$(( STATS[pydantic_issues] + 1 ))
        flagged=1
      fi
    done
  done

  if (( flagged == 0 )); then
    debug "PYCHECK: All checked pip modules import cleanly under $current_py"
  else
    warn "PYCHECK: reinstall the affected package(s) with 'pip install --user --force-reinstall --no-cache-dir <pkg>', or pin the system Python version, then restart the affected service(s)."
  fi
}

check_btrfs_health() {
  info "Checking Btrfs metadata usage and subvolume health..."

  local meta_line meta_pct
  meta_line=$(sudo btrfs filesystem usage / 2>/dev/null | grep -E "^Metadata,")
  if [[ -z "$meta_line" ]]; then
    debug "Could not read Btrfs metadata usage; skipping"
    return 0
  fi

  # Extract percentage like "91.80%" from "Metadata,DUP: Size:25.00GiB, Used:22.95GiB (91.80%)"
  meta_pct=$(echo "$meta_line" | grep -oP '\(\K[0-9.]+(?=%\))')

  if [[ -n "$meta_pct" ]]; then
    debug "Btrfs metadata usage: ${meta_pct}%"
    if (( $(echo "$meta_pct > 80" | bc -l 2>/dev/null || echo 0) )); then
      warn "Btrfs metadata usage is high: ${meta_pct}% -- consider a balance pass or check for orphaned subvolumes"
    fi
  fi

  # Flag anything that looks like a manual rollback/backup tree left behind.
  # Known-good subvolumes (@, @home, @root, @srv, @cache, @tmp, @log, @snapshots
  # and their nested children) are NOT matched by this pattern.
  local orphans
  orphans=$(sudo btrfs subvolume list / 2>/dev/null \
    | awk '{print $NF}' \
    | grep -E '^@.*(_old|_pre_rollback|_rollback|_backup|_failed)' \
    | grep -vE '/' \
    | sort -u) || true

  if [[ -n "$orphans" ]]; then
    local orphan_count
    orphan_count=$(echo "$orphans" | wc -l)
    warn "Found ${orphan_count} orphaned-looking Btrfs subvolume root(s) outside normal naming:"
    while IFS= read -r o; do
      warn "  -> $o"
    done <<< "$orphans"
    warn "Not auto-deleted -- review manually: sudo btrfs subvolume list / | grep '<name>'"
    warn "If confirmed unneeded, delete nested children bottom-up before the parent."
  else
    debug "No orphaned rollback/backup subvolume trees detected"
  fi
}

check_bios_update() {
  if $SKIP_BIOS_CHECK; then
    debug "BIOS: Check skipped (--skip-bios-check)"
    return
  fi

  # dmidecode and fwupdmgr both require root; skip entirely in dry-run
  if $DRY_RUN; then
    info "[DRY RUN] Would check for HP BIOS updates (requires root, skipped)"
    return
  fi

  if ! command -v dmidecode >/dev/null 2>&1; then
    debug "BIOS: dmidecode not found, skipping check"
    return
  fi

  info "Checking for HP BIOS updates..."

  local current_ver
  current_ver=$(get_current_bios_version)
  if [[ -z "$current_ver" ]]; then
    warn "BIOS: Cannot determine current version — skipping"
    return
  fi
  info "BIOS: Current version: ${current_ver}"

  # --- Pass 1: try fwupd / LVFS ---
  if command -v fwupdmgr >/dev/null 2>&1; then
    local fwupd_ver
    fwupd_ver=$(timeout 30 fwupdmgr get-updates 2>/dev/null \
      | grep -A 10 "System Firmware" \
      | grep "Available version:" \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
      | head -1)

    if [[ -n "$fwupd_ver" ]]; then
      info "BIOS: fwupd reports update available: ${current_ver} → ${fwupd_ver}"
      if ! $DRY_RUN; then
        if fwupdmgr update --no-reboot-check 2>/dev/null; then
          BIOS_UPDATE_STAGED=true
          STATS[bios_staged]=1
          info "BIOS: fwupd staged update. Reboot required."
        else
          warn "BIOS: fwupd update staging failed — trying HP FTP fallback"
        fi
      else
        info "[DRY RUN] Would apply BIOS update via fwupd (${current_ver} → ${fwupd_ver})"
      fi
      $BIOS_UPDATE_STAGED && return
    else
      debug "BIOS: No update on LVFS, trying HP FTP catalog"
    fi
  fi

  # --- Pass 2: HP FTP imagepal catalog ---
  local platform_id
  platform_id=$(get_hp_platform_id)
  if [[ -z "$platform_id" || ${#platform_id} -ne 4 ]]; then
    info "BIOS: Could not detect HP platform ID (got '${platform_id}') — skipping FTP check"
    info "BIOS: Check manually: https://support.hp.com/us-en/drivers/hp-elitebook-645-14-inch-g10-notebook-pc/2101880055"
    return
  fi
  debug "BIOS: Platform ID: ${platform_id}"

  local work_dir
  work_dir=$(mktemp -d /var/tmp/hp-bios-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '${work_dir}'" RETURN

  local catalog_info
  catalog_info=$(fetch_hp_bios_catalog "$platform_id" "$work_dir")

  if [[ -z "$catalog_info" ]]; then
    info "BIOS: HP catalog unavailable for platform ${platform_id}"
    info "BIOS: Check manually: https://support.hp.com/us-en/drivers/hp-elitebook-645-14-inch-g10-notebook-pc/2101880055"
    return
  fi

  local latest_ver softpaq_url
  latest_ver=$(echo "$catalog_info" | awk '{print $1}')
  softpaq_url=$(echo "$catalog_info" | awk '{print $2}')

  info "BIOS: Latest available: ${latest_ver}"

  if ! version_gt "$latest_ver" "$current_ver"; then
    info "BIOS: Already up to date (${current_ver})"
    return
  fi

  info "BIOS: Update available: ${current_ver} → ${latest_ver}"

  if $DRY_RUN; then
    info "[DRY RUN] Would download and stage BIOS update from ${softpaq_url}"
    return
  fi

  stage_bios_update "$softpaq_url" "$work_dir" \
    || warn "BIOS: Staging failed — update manually from HP support site"
}

#######################################
# BROKEN SHARED LIBRARY SCAN
#######################################
scan_broken_links() {
  if $SKIP_BROKEN_LINKS; then
    info "Broken library scan skipped (--skip-broken-links)"
    return
  fi

  # In non-interactive / cron mode skip the prompt entirely and just run the scan.
  # In interactive mode, ask with a 10-second timeout; no answer = skip.
  local do_scan=true
  if $INTERACTIVE; then
    local answer=""
    echo "" >&2
    # Print prompt directly to /dev/tty so it always appears even when stderr is redirected
    printf '%s' "$(date '+%F %T') [INFO] Run broken shared library scan? [Y/n] (auto-skip in 10s): " >/dev/tty
    if read -r -t 10 answer </dev/tty 2>/dev/null; then
      # Got input — treat empty or Y/y as yes, anything else as no
      if [[ -n "$answer" && ! "$answer" =~ ^[Yy]$ ]]; then
        do_scan=false
      fi
    else
      # Timeout — print a newline so the next log line isn't on the same line
      printf '\n' >/dev/tty
      info "No response in 10 seconds — skipping broken library scan"
      do_scan=false
    fi
  fi

  if ! $do_scan; then
    return
  fi

  info "Scanning for broken shared library links..."

  if ! command -v ldconfig >/dev/null 2>&1; then
    warn "ldconfig not found; cannot scan for broken libraries"
    return
  fi

  local broken_count=0

  # Build the ldconfig cache fresh, then check every installed binary/library
  # for unresolvable soname dependencies.
  local tmpout
  tmpout=$(mktemp /var/tmp/broken-libs-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '${tmpout}'" RETURN

  if $DRY_RUN; then
    info "[DRY RUN] Would run: ldconfig + check all ELF binaries for missing sonames"
    return
  fi

  # Refresh ldconfig cache first so we don't get false positives from a stale cache.
  # Must run as root; fall back to unprivileged if sudo unavailable (e.g. in hooks).
  sudo ldconfig 2>/dev/null || ldconfig 2>/dev/null || true

  # Known false positives: cross-name symlinks whose soname doesn't appear in the
  # ldconfig cache by the aliased name but resolve correctly at runtime via /usr/lib.
  local -a SENTRY_IGNORE=(
    "libvapoursynth-script.so.0"  # symlink -> libvsscript.so; resolves fine via /usr/lib
  )

  # Directories with large non-ELF file counts, excluded from the file(1) scan
  # itself (before the ELF filter runs) so we don't waste time running `file`
  # on tens of thousands of assets that will never be ELF binaries.
  local -a SCAN_EXCLUDE_PATHS=(
    "/usr/share/kicad/"   # footprints/symbols/3dmodels — text/step files, never ELF
  )

  # Path prefixes to skip entirely — ELFs in these directories use internal pseudo-DLLs
  # or non-standard linking that ldd cannot resolve but which work fine at runtime.
  #
  # /usr/lib/systemd/ note: private plugin libs (e.g. libsystemd-core.so ->
  # libsystemd-shared.so) sit right next to their dependencies but outside ld.so's
  # default search path; they resolve via $ORIGIN-relative loading at runtime.
  local -a SENTRY_IGNORE_PATHS=(
    "/usr/lib/wine/"        # Wine x86_64-unix .so files reference ntdll.so/win32u.so internally
    "/usr/lib/syslinux/"    # COM32 modules use syslinux's own object loader, not ld.so
    "/usr/lib/systemd/"     # private plugin libs resolve via $ORIGIN, not ld.so's search path
    "/opt/zen-browser-bin/" # Gecko bundled libs resolve via xul.so's internal relative loading
    "/usr/lib/floorp/"      # same Gecko internal-loading pattern as zen-browser-bin above
  )

  # ldd-based scan: iterate over all ELF files owned by pacman packages
  while IFS= read -r elf; do
    # Skip ELFs under ignored path prefixes (e.g. Wine pseudo-DLLs)
    local path_ignored=false
    for ignore_path in "${SENTRY_IGNORE_PATHS[@]}"; do
      [[ "$elf" == "$ignore_path"* ]] && path_ignored=true && break
    done
    $path_ignored && continue

    local ldd_out
    ldd_out=$(ldd "$elf" 2>/dev/null) || continue
    if echo "$ldd_out" | grep -q "not found"; then
      local missing
      missing=$(echo "$ldd_out" | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')
      # Filter out known-ignored sonames
      local filtered_missing=""
      for soname in $missing; do
        local ignored=false
        for ignore_pat in "${SENTRY_IGNORE[@]}"; do
          [[ "$soname" == "$ignore_pat" ]] && ignored=true && break
        done
        $ignored || filtered_missing+="$soname "
      done
      [[ -z "${filtered_missing// }" ]] && continue
      printf '%s: %s\n' "$elf" "$filtered_missing" >> "$tmpout"
      (( broken_count++ )) || true
    fi
  done < <(pacman -Ql 2>/dev/null \
    | awk '{print $2}' \
    | sort -u \
    | grep -vE "^($(IFS='|'; echo "${SCAN_EXCLUDE_PATHS[*]}"))" \
    | xargs -d'\n' file -L 2>/dev/null \
    | awk -F': ' '/ELF.*dynamically linked/{print $1}')

  if [[ $broken_count -eq 0 ]]; then
    info "No broken shared library links found"
  else
    warn "Found $broken_count ELF file(s) with missing shared libraries:"
    while IFS= read -r line; do
      warn "  $line"
    done < "$tmpout"
    warn "Run 'fix_broken_libs.py' or reinstall the affected packages to resolve."
    local _ec=$(( STATS[error_count] + broken_count ))
    STATS[error_count]=$_ec
  fi
}

#######################################
# ROLLING RUN LOG
#######################################
# Appends a one-line summary record to a persistent TSV log after every run.
# Columns (tab-separated):
#   timestamp  mode  kernel  repo_updates  aur_updates  pkgs_removed  errors  bios_staged  log_path
ROLLING_LOG_FILE="/var/log/archos-cleanup/run-history.log"

write_rolling_log() {
  local mode="live"
  $DRY_RUN && mode="dry-run"

  local kernel_ver ts record target
  kernel_ver=$(uname -r)
  ts=$(date '+%F %T')

  record=$(printf '%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s' \
    "$ts" "$mode" "$kernel_ver" \
    "${STATS[repo_applied]}" "${STATS[updates_aur]}" \
    "${STATS[packages_removed]}" "${STATS[error_count]}" \
    "${STATS[bios_staged]}" "${AUTO_LOG_FILE:-n/a}")

  # Dry-runs can't write to /var/log (no root); use user log dir instead
  if $DRY_RUN; then
    target="${HOME}/.local/log/cachyos-maintenance/run-history.log"
  else
    target="$ROLLING_LOG_FILE"
  fi

  # Ensure log directory exists (may be absent on first live run or after log rotation)
  mkdir -p "$(dirname "$target")" || { warn "Could not create rolling log dir: $(dirname "$target")"; return; }

  # Write TSV header if the file is new/empty
  if [[ ! -s "$target" ]]; then
    printf '%s\n' "# timestamp\tmode\tkernel\trepo_updates\taur_updates\tpkgs_removed\terrors\tbios_staged\tlog_path" >> "$target" \
      || warn "Could not write rolling log header: $target"
  fi

  if printf '%s\n' "$record" >> "$target"; then
    info "Rolling log updated: $target"
  else
    warn "Could not write to rolling log: $target"
  fi
}


#######################################
# MAIN
#######################################
main() {
  parse_args "$@"

  # Auto-log: dry-run goes to ~/.local/log to avoid requiring root
  local _run_type="live"
  local _log_dir="$AUTO_LOG_DIR"
  if $DRY_RUN; then
    _run_type="dry-run"
    _log_dir="${HOME}/.local/log/cachyos-maintenance"
  fi
  mkdir -p "$_log_dir"
  AUTO_LOG_FILE="${_log_dir}/$(date '+%F_%H-%M-%S')_${_run_type}.log"
  touch "$AUTO_LOG_FILE" || { echo "Cannot write auto-log: $AUTO_LOG_FILE"; exit 1; }

  # Initialize optional extra log file if specified
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" || { echo "Cannot write to log file: $LOG_FILE"; exit 1; }
    info "Also logging to: $LOG_FILE"
  fi

  check_root

  info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
  info "Auto-log: $AUTO_LOG_FILE"
  $DRY_RUN    && warn "DRY RUN MODE — No changes will be made"
  $INTERACTIVE && info "Interactive mode enabled"
  $ENABLE_BACKUPS || warn "Backups disabled"
  debug "Log level: $LOG_LEVEL"

  STATS[packages_before]=$(pacman -Q | wc -l | tr -d '[:space:]')
  debug "Current package count: ${STATS[packages_before]}"

  # Each step is guarded with || so a non-fatal failure in one step
  # (e.g. a pacman transaction error) can't silently abort every step
  # after it under `set -e`. See error() history note above -- this is
  # the same class of bug, just at the main() call-site level.
  update_system           || { STATS[error_count]=$((STATS[error_count] + 1)); warn "update_system step failed - continuing with remaining checks"; }
  check_pydantic_compat   || { STATS[error_count]=$((STATS[error_count] + 1)); warn "check_pydantic_compat step failed - continuing"; }
  check_bios_update       || { STATS[error_count]=$((STATS[error_count] + 1)); warn "check_bios_update step failed - continuing"; }
  check_alexa_media_patch || { STATS[error_count]=$((STATS[error_count] + 1)); warn "check_alexa_media_patch step failed - continuing"; }
  check_port_conflicts    || { STATS[error_count]=$((STATS[error_count] + 1)); warn "check_port_conflicts step failed - continuing"; }
  check_btrfs_health      || { STATS[error_count]=$((STATS[error_count] + 1)); warn "check_btrfs_health step failed - continuing"; }
  clean_cache             || { STATS[error_count]=$((STATS[error_count] + 1)); warn "clean_cache step failed - continuing"; }
  remove_orphans          || { STATS[error_count]=$((STATS[error_count] + 1)); warn "remove_orphans step failed - continuing"; }
  clean_logs              || { STATS[error_count]=$((STATS[error_count] + 1)); warn "clean_logs step failed - continuing"; }
  clean_user_cache        || { STATS[error_count]=$((STATS[error_count] + 1)); warn "clean_user_cache step failed - continuing"; }
  scan_broken_links       || { STATS[error_count]=$((STATS[error_count] + 1)); warn "scan_broken_links step failed - continuing"; }

  STATS[packages_after]=$(pacman -Q | wc -l | tr -d '[:space:]')
  STATS[packages_removed]=$((STATS[packages_before] - STATS[packages_after]))

  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Summary:"
  if (( STATS[repo_applied] < STATS[updates_repo] )); then
    info "  Repo updates applied:   ${STATS[repo_applied]} / ${STATS[updates_repo]} available (see warnings above)"
  else
    info "  Repo updates applied:   ${STATS[repo_applied]}"
  fi
  info "  AUR updates applied:    ${STATS[updates_aur]}"
  info "  BIOS update staged:     ${STATS[bios_staged]}"
  info "  Coral DKMS rebuilt:     ${STATS[dkms_rebuilt]}"
  info "  Alexa patch reapplied:  ${STATS[alexa_patch_reapplied]}"
  info "  Python/pip compat issues: ${STATS[pydantic_issues]}"
  info "  Packages removed:       ${STATS[packages_removed]}"
  info "  Errors encountered:     ${STATS[error_count]}"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Cleanup complete"
  info "Full log saved to: $AUTO_LOG_FILE"

  write_rolling_log

  # Reboot check always runs; prompt only in interactive mode
  handle_reboot
}

main "$@"
