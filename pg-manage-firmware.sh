#!/bin/sh
#
# pg-manage-firmware
#
# PGSD / GhostBSD / FreeBSD helper to optimize firmware installation:
#   1. Show firmware needed by fwget for current hardware
#   2. Remove unused firmware packages from managed families
#   3. Reinstall only hardware-required firmware via fwget
#
# Managed firmware families:
#   - gpu-firmware-amd-kmod-*, gpu-firmware-intel-kmod-*, gpu-firmware-radeon-kmod-*
#   - gpu-firmware-kmod (generic GPU firmware)
#   - wifi-firmware-* (all WiFi firmware)
#   - bwi-firmware-kmod, bwn-firmware-kmod (Broadcom WiFi)
#   - malo-firmware-kmod (Marvell WiFi)
#   - intel-firmware*
#   - bluetooth-firmware*, broadcom-firmware*, rtlbt-firmware
#
# Copyright (c) 2025 Pacific Grove Software Distribution Foundation
# Author: Vester (Vic) Thacker
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

set -e
umask 022

# Configuration
readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly FIRMWARE_PATTERNS='gpu-firmware-(amd|intel|radeon)-kmod|gpu-firmware-kmod|wifi-firmware-|bw[in]-firmware-kmod|malo-firmware-kmod|intel-firmware|b(luetooth|roadcom)-firmware|rtlbt-firmware'
readonly BACKUP_DIR="/var/tmp"
readonly LOG_FILE="${LOG_FILE:-/var/log/pg-manage-firmware.log}"

# Detect UTF-8 support for box drawing characters
if [ "${LANG:-}" != "${LANG#*.UTF-8}" ] && [ "${LC_ALL:-}" != "${LC_ALL#*.UTF-8}" ]; then
    readonly SEPARATOR_CHAR="─"
    readonly CHECK_MARK="✓"
else
    readonly SEPARATOR_CHAR="-"
    readonly CHECK_MARK="*"
fi

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
        echo >&2
        echo "Error: Script failed with exit code $exit_code" >&2
        echo "Your system state may have changed. Consider running 'pkg check -d' to verify." >&2
        if [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_FILE" ]; then
            echo "Package list backup available at: $BACKUP_FILE" >&2
        fi
    fi
}
trap cleanup EXIT

# Logging function
log() {
    local msg="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        echo "[$timestamp] $msg" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$timestamp] $msg"
    else
        echo "[$timestamp] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Verbose output
verbose() {
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        echo "$@" >&2
    fi
}

usage() {
    cat <<EOF
pg-manage-firmware version $VERSION

Usage: $SCRIPT_NAME [OPTIONS]

Optimize firmware installation by removing unused firmware packages and
reinstalling only what the current hardware requires.

OPTIONS:
  --dry-run    Show what would be changed without modifying the system
  --verbose    Enable verbose output and logging
  --help       Display this help message

OPERATION:
  Without options, this script will:
    1. Query fwget to identify hardware-required firmware
    2. List currently installed firmware from managed families
    3. Prompt for confirmation
    4. Create backup of package list
    5. Remove managed firmware packages
    6. Run fwget to install only hardware-required firmware
    7. Verify installation success

MANAGED FAMILIES:
  gpu-firmware-*-kmod-* (AMD, Intel, Radeon), wifi-firmware-*,
  bwi-firmware-kmod, bwn-firmware-kmod, malo-firmware-kmod,
  intel-firmware*, bluetooth-firmware*, broadcom-firmware*, rtlbt-firmware

EXAMPLES:
  $SCRIPT_NAME --dry-run         # Preview changes without modification
  sudo $SCRIPT_NAME              # Execute firmware optimization
  sudo $SCRIPT_NAME --verbose    # Run with detailed logging

FILES:
  $LOG_FILE    Operation log (when writable)
  $BACKUP_DIR/pg-manage-firmware-backup-*.txt    Package backups

Copyright (c) 2025 Pacific Grove Software Distribution Foundation
Author: Vester (Vic) Thacker

EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script requires root privileges." >&2
        echo "Please run: sudo $SCRIPT_NAME" >&2
        exit 1
    fi
}

check_tools() {
    local missing=0
    
    for cmd in pkg fwget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found in PATH." >&2
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        echo >&2
        echo "Please ensure all required tools are installed." >&2
        exit 1
    fi
    
    verbose "Tool check passed: pkg and fwget are available"
}

warn_ssh() {
    # Check if we're in an SSH session
    if [ -z "${SSH_TTY:-}" ] && [ -z "${SSH_CONNECTION:-}" ]; then
        return 0
    fi
    
    # Check if running interactively
    if [ ! -t 0 ]; then
        echo "Error: Running over SSH in non-interactive mode." >&2
        echo "This is too dangerous as network firmware removal may cut connectivity." >&2
        echo "Please run from an interactive SSH session or local console." >&2
        exit 1
    fi
    
    cat >&2 <<EOF

┌─────────────────────────────────────────────────────────────┐
│ WARNING: SSH Session Detected                               │
├─────────────────────────────────────────────────────────────┤
│ Removing network/WiFi firmware during an SSH session may    │
│ cause connectivity loss. Recommendations:                   │
│   • Run from local console, or                              │
│   • Ensure alternative access (IPMI, physical access), or   │
│   • Verify wired connection won't be affected               │
└─────────────────────────────────────────────────────────────┘

EOF
    printf "Continue anyway? [y/N]: " >&2
    if ! read -r response; then
        echo >&2
        echo "EOF detected. Aborted." >&2
        exit 0
    fi
    
    case "$response" in
        [yY]|[yY][eE][sS]) 
            log "User chose to continue despite SSH warning"
            echo >&2
            ;;
        *) 
            echo "Aborted." >&2
            log "User aborted due to SSH warning"
            exit 0 
            ;;
    esac
}

list_installed_firmware() {
    local result
    local exit_code
    
    verbose "Querying installed firmware packages..."
    
    # Use -x flag for regex matching (not -e which doesn't work as expected)
    result="$(pkg query -x '%n' "^($FIRMWARE_PATTERNS)" 2>&1)" || exit_code=$?
    
    if [ "${exit_code:-0}" -ne 0 ]; then
        # Check if it's just "no packages match" which is fine
        # pkg query -x returns non-zero when no packages match, which is valid
        case "$result" in
            *"no packages"*|*"No packages"*|"")
                verbose "No matching firmware packages found"
                return 0
                ;;
            *)
                echo "Error: pkg query failed: $result" >&2
                return 1
                ;;
        esac
    fi
    
    if [ -n "$result" ]; then
        echo "$result" | sort -u
    fi
}

get_needed_firmware() {
    local output
    local exit_code
    
    verbose "Running fwget dry-run to detect hardware requirements..."
    
    output="$(fwget -n 2>&1)" || exit_code=$?
    
    if [ "${exit_code:-0}" -ne 0 ]; then
        verbose "Warning: fwget -n returned non-zero exit code: ${exit_code:-0}"
        # Continue anyway as fwget might return non-zero for various non-critical reasons
    fi
    
    if [ -z "$output" ]; then
        verbose "fwget produced no output"
        return 0
    fi
    
    # Extract package names from fwget output
    # Expected format: lines starting with whitespace followed by +/- and package name
    echo "$output" | \
        grep -E '^[[:space:]]*[-+][[:space:]]+' 2>/dev/null | \
        sed -E 's/^[[:space:]]*[-+][[:space:]]+//' | \
        awk '{print $1}' | \
        grep -v '^$' | \
        sort -u || true
}

confirm_action() {
    local prompt="${1:-Proceed?}"
    
    printf "%s [y/N]: " "$prompt"
    
    # Handle EOF gracefully (Ctrl+D)
    if ! read -r response; then
        echo >&2
        echo "EOF detected. Aborted." >&2
        exit 0
    fi
    
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

print_section() {
    local title="$1"
    local width=70
    local separator
    
    # Build separator string
    separator=""
    i=0
    while [ $i -lt $width ]; do
        separator="${separator}${SEPARATOR_CHAR}"
        i=$((i + 1))
    done
    
    echo
    echo "$title"
    printf "%s\n" "$separator"
}

count_lines() {
    local text="$1"
    local count=0
    
    if [ -z "$text" ]; then
        echo "0"
        return
    fi
    
    # Use a loop to avoid the "echo empty string = 1 line" issue
    while IFS= read -r line; do
        count=$((count + 1))
    done <<EOF
$text
EOF
    
    echo "$count"
}

backup_pkg_list() {
    local pkg_list="$1"
    local backup_file
    
    backup_file="$BACKUP_DIR/pg-manage-firmware-backup-$(date +%s).txt"
    
    if echo "$pkg_list" > "$backup_file" 2>/dev/null; then
        verbose "Created backup: $backup_file"
        echo "$backup_file"
        return 0
    else
        echo "Warning: Could not create backup file: $backup_file" >&2
        return 1
    fi
}

remove_packages() {
    local pkg_list="$1"
    local pkg_count
    local temp_file
    
    pkg_count="$(count_lines "$pkg_list")"
    
    if [ "$pkg_count" -eq 0 ]; then
        echo "No packages to remove."
        return 0
    fi
    
    # Create temporary file for package list
    temp_file="$(mktemp)" || {
        echo "Error: Could not create temporary file" >&2
        return 1
    }
    
    # Clean up temp file on exit
    trap 'rm -f "$temp_file"' EXIT INT TERM
    
    echo "$pkg_list" > "$temp_file"
    
    verbose "Removing $pkg_count package(s)..."
    log "Removing packages: $pkg_list"
    
    # Use xargs to safely handle package names
    if xargs pkg remove -y < "$temp_file"; then
        log "Successfully removed $pkg_count package(s)"
        rm -f "$temp_file"
        return 0
    else
        log "Error: Package removal failed"
        rm -f "$temp_file"
        return 1
    fi
}

verify_pkg_database() {
    verbose "Verifying package database integrity..."
    
    if pkg check -d >/dev/null 2>&1; then
        verbose "Package database verification passed"
        return 0
    else
        echo "Warning: Package database inconsistency detected" >&2
        echo "You may want to run 'pkg check -d' manually to diagnose" >&2
        log "Package database verification failed"
        return 1
    fi
}

main() {
    local DRY_RUN=0
    local VERBOSE=0
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                echo "Try '$SCRIPT_NAME --help' for more information." >&2
                exit 1
                ;;
        esac
    done
    
    log "==================== pg-manage-firmware v$VERSION started ===================="
    log "Options: DRY_RUN=$DRY_RUN VERBOSE=$VERBOSE"
    
    require_root
    check_tools
    warn_ssh
    
    # Step 1: Show hardware requirements
    print_section "Step 1: Hardware Firmware Requirements (fwget analysis)"
    
    local needed_fw
    needed_fw="$(get_needed_firmware)"
    
    local needed_count
    needed_count="$(count_lines "$needed_fw")"
    
    if [ "$needed_count" -gt 0 ]; then
        echo "$needed_fw"
        echo
        echo "→ $needed_count firmware package(s) needed for current hardware"
        log "Hardware requires $needed_count firmware package(s)"
    else
        echo "No firmware requirements detected (or fwget produced no output)"
        log "No firmware requirements detected"
    fi
    
    # Step 2: Show currently installed
    print_section "Step 2: Currently Installed Managed Firmware"
    
    local installed_fw
    installed_fw="$(list_installed_firmware)" || {
        echo "Error: Failed to query installed packages" >&2
        exit 1
    }
    
    local installed_count
    installed_count="$(count_lines "$installed_fw")"
    
    if [ "$installed_count" -eq 0 ]; then
        echo "No managed firmware packages currently installed."
        echo
        log "No managed firmware packages installed"
        
        if [ "$needed_count" -eq 0 ]; then
            print_section "$CHECK_MARK No Firmware Management Needed"
            echo "System has no firmware requirements and no managed firmware installed."
            log "No action needed - system has no firmware requirements"
            exit 0
        fi
        
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY RUN] Would run: fwget"
            log "Dry run: would install firmware"
            exit 0
        fi
        
        echo "Running fwget to install required firmware..."
        print_section "Installing Firmware"
        log "Installing firmware via fwget"
        
        if fwget; then
            print_section "$CHECK_MARK Complete"
            log "Firmware installation completed successfully"
        else
            echo "Error: fwget failed" >&2
            log "Error: fwget failed"
            exit 1
        fi
        exit 0
    fi
    
    echo "$installed_fw"
    echo
    echo "→ $installed_count managed firmware package(s) currently installed"
    log "Found $installed_count managed firmware package(s) installed"
    
    # Step 3: Show what will happen
    print_section "Step 3: Planned Actions"
    
    if [ "$DRY_RUN" -eq 1 ]; then
        cat <<EOF
[DRY RUN MODE - No changes will be made]

Would execute:
  1. Create backup of current package list
  2. Remove $installed_count firmware package(s)
  3. Verify package database integrity
  4. Run 'fwget' to reinstall hardware-required firmware
  5. Verify firmware installation

To apply these changes, run without --dry-run flag.
EOF
        log "Dry run completed - no changes made"
        exit 0
    fi
    
    cat <<EOF
This will:
  1. Create backup of current package list
  2. Remove $installed_count installed firmware package(s) listed above
  3. Run 'fwget' to reinstall only hardware-required firmware
  4. Result: Smaller footprint, only necessary firmware installed

EOF
    
    if ! confirm_action "Proceed with firmware optimization?"; then
        echo "Aborted. No changes made."
        log "User aborted operation"
        exit 0
    fi
    
    log "User confirmed - proceeding with firmware optimization"
    
    # Create backup
    print_section "Creating Backup"
    BACKUP_FILE="$(backup_pkg_list "$installed_fw")"
    if [ -n "$BACKUP_FILE" ]; then
        echo "Backup created: $BACKUP_FILE"
    fi
    
    # Step 4: Remove packages
    print_section "Step 4: Removing Managed Firmware Packages"
    
    if ! remove_packages "$installed_fw"; then
        echo "Error: Failed to remove packages" >&2
        log "Error: Package removal failed"
        exit 1
    fi
    
    echo
    echo "→ Successfully removed $installed_count package(s)"
    
    # Verify database integrity
    verify_pkg_database || true
    
    # Step 5: Install required firmware
    print_section "Step 5: Installing Hardware-Required Firmware"
    
    log "Running fwget to install required firmware"
    
    if ! fwget; then
        echo >&2
        echo "Warning: fwget encountered an error." >&2
        echo "Run 'fwget -v' manually for detailed information." >&2
        log "Error: fwget failed during installation"
        exit 1
    fi
    
    log "fwget completed successfully"
    
    # Step 6: Verify installation
    print_section "Step 6: Verifying Installation"
    
    local still_needed
    still_needed="$(get_needed_firmware)"
    local still_needed_count
    still_needed_count="$(count_lines "$still_needed")"
    
    if [ "$still_needed_count" -gt 0 ]; then
        echo "Warning: fwget reports some firmware still needed:" >&2
        echo "$still_needed" >&2
        echo
        echo "This may be normal if the firmware requires a reboot to activate." >&2
        log "Warning: $still_needed_count firmware package(s) still reported as needed"
    else
        verbose "All required firmware successfully installed"
        log "All required firmware successfully installed"
    fi
    
    # Final summary
    print_section "$CHECK_MARK Firmware Optimization Complete"
    
    local final_fw
    final_fw="$(list_installed_firmware)"
    local final_count
    final_count="$(count_lines "$final_fw")"
    
    cat <<EOF

Summary:
  Before: $installed_count managed firmware package(s)
  After:  $final_count managed firmware package(s)
  Backup: $BACKUP_FILE
  
Your system now has only hardware-required firmware installed.

EOF
    
    log "Optimization complete: $installed_count -> $final_count packages"
    log "==================== pg-manage-firmware completed successfully ===================="
}

main "$@"
