# pg-manage-firmware

A PGSD / GhostBSD / FreeBSD utility to optimize firmware installation by removing unused firmware packages and reinstalling only what your hardware actually requires.

## Overview

`pg-manage-firmware` helps reduce system footprint by intelligently managing firmware packages. It uses FreeBSD's `fwget` utility to detect hardware requirements, removes unnecessary firmware from managed families, and reinstalls only what your system needs.

## Requirements

- PGSD or FreeBSD or GhostBSD system
- Root privileges (sudo)
- `pkg` package manager
- `fwget` firmware installation tool

## Installation

1. Download the script:
```bash
curl -O https://github.com/pgsdf/pg-manage-firmware
# or
wget https://github.com/pgsdf/pg-manage-firmware
```

2. Make it executable:
```bash
chmod +x pg-manage-firmware
```

3. Move to system binary directory (optional):
```bash
sudo mv pg-manage-firmware /usr/local/sbin/
```

## Usage

### Basic Usage
```bash
# Preview what would be changed (recommended first step)
sudo pg-manage-firmware --dry-run

# Execute firmware optimization
sudo pg-manage-firmware

# Run with detailed logging
sudo pg-manage-firmware --verbose
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be changed without modifying the system |
| `--verbose`, `-v` | Enable verbose output and detailed logging |
| `--help`, `-h` | Display help message and exit |

## Operation Flow

When executed, `pg-manage-firmware` performs the following steps:

1. **Hardware Analysis**: Queries `fwget` to identify required firmware
2. **Current State**: Lists currently installed managed firmware packages
3. **User Confirmation**: Prompts for confirmation before making changes
4. **Backup Creation**: Creates timestamped backup of package list
5. **Package Removal**: Removes managed firmware packages
6. **Database Check**: Verifies package database integrity
7. **Firmware Installation**: Runs `fwget` to install required firmware
8. **Verification**: Confirms installation success
9. **Summary**: Displays before/after statistics

## Examples

### Preview Changes
```bash
sudo pg-manage-firmware --dry-run
```

Output:
```
Step 1: Hardware Firmware Requirements (fwget analysis)
──────────────────────────────────────────────────────────────────────
intel-firmware-kmod
wifi-firmware-iwlwifi-kmod

→ 2 firmware package(s) needed for current hardware

Step 2: Currently Installed Managed Firmware
──────────────────────────────────────────────────────────────────────
gpu-firmware-amd-kmod-20240101
gpu-firmware-radeon-kmod-20240101
intel-firmware-kmod
wifi-firmware-iwlwifi-kmod
wifi-firmware-rtlwifi-kmod

→ 5 managed firmware package(s) currently installed

[DRY RUN MODE - No changes will be made]

Would execute:
  1. Create backup of current package list
  2. Remove 5 firmware package(s)
  3. Verify package database integrity
  4. Run 'fwget' to reinstall hardware-required firmware
  5. Verify firmware installation
```

### Execute Optimization
```bash
sudo pg-manage-firmware
```

The script will:
- Show hardware requirements
- List current firmware packages
- Ask for confirmation
- Remove unnecessary firmware
- Reinstall required firmware
- Display summary

### Verbose Mode
```bash
sudo pg-manage-firmware --verbose
```

Provides detailed output including:
- Tool availability checks
- Package query operations
- Backup creation status
- Database verification results
- All operations logged to `/var/log/pg-manage-firmware.log`

## Safety Features

### SSH Session Detection

When running over SSH, the script:
- Detects SSH connections via `$SSH_TTY` or `$SSH_CONNECTION`
- Displays prominent warning about potential connectivity loss
- Prompts for explicit confirmation to continue
- Refuses to run non-interactively over SSH

### Backup System

- Creates timestamped backup of package list before removal
- Stores backups in `/var/tmp/pg-manage-firmware-backup-<timestamp>.txt`
- Displays backup location in error messages
- Allows manual recovery if needed

### Error Handling

- Validates tool availability before execution
- Checks root privileges
- Verifies package database integrity
- Provides detailed error messages
- Logs all operations for troubleshooting

## Files and Directories

| Path | Description |
|------|-------------|
| `/var/log/pg-manage-firmware.log` | Operation log file |
| `/var/tmp/pg-manage-firmware-backup-*.txt` | Package list backups |

## Troubleshooting

### No firmware detected

If `fwget` reports no firmware requirements:
```bash
# Run fwget manually with verbose output
sudo fwget -v
```

### Package removal fails

1. Check the backup file location in error message
2. Verify package database:
```bash
sudo pkg check -d
```

### Firmware not installing

Run fwget manually for detailed diagnostics:
```bash
sudo fwget -v
```

### Restore from backup

If you need to restore the previous state:
```bash
# Find your backup
ls -lt /var/tmp/pg-manage-firmware-backup-*.txt | head -1

# Reinstall packages from backup
sudo xargs pkg install -y < /var/tmp/pg-manage-firmware-backup-<timestamp>.txt
```

## Logging

All operations are logged to `/var/log/pg-manage-firmware.log` including:
- Execution start/completion timestamps
- Detected firmware requirements
- Package removal operations
- Installation results
- Error messages

View recent log entries:
```bash
sudo tail -50 /var/log/pg-manage-firmware.log
```

## Best Practices

1. **Always use --dry-run first** to preview changes
2. **Run from local console** when possible, especially on laptops
3. **Ensure alternative access** (IPMI, physical access) before running over SSH
4. **Keep backups** - don't delete backup files immediately after execution
5. **Review logs** after execution to confirm success
6. **Reboot if needed** - some firmware requires reboot to activate

## Copyright and License

Copyright (c) 2025 Pacific Grove Software Distribution Foundation

Author: Vester (Vic) Thacker

## Contact and Support

- **Telegram**: https://t.me/PGSD_Foundation
- **Issues**: https://github.com/pgsdf/pg-manage-firmware/issues

