# 📱 Android Backup - Quick Guide

## Setup (One Time)

```bash
# Install dependencies
sudo pacman -S android-tools  # or apt/brew equivalent
pip3 install --user BetterADBSync

# Verify adbsync is in PATH
adbsync --help

# Enable USB Debugging on phone
# Settings → About → Tap Build Number 7x → Developer Options → USB Debugging
```

## Basic Usage

```bash
cd ~/code/dotfiles/scripts/phone_backup
./phone_backup.sh
```

Follow prompts:

1. Backup location (default: `~/backups/`)
2. Folder name (default: `last_backup`)
3. Y/n for each path (Enter = Yes)
4. Y/n for external drive copy
5. Y/n for each directory to copy to external drive

## Configuration

Edit `backup_paths.ini`:

```ini
[FolderName]
path=DCIM
description=Photos and videos
enabled=true
```

- `enabled=true` → Backs up
- `enabled=false` → Skips without deleting entry

## Performance Options

```bash
# Default: Safe, resumable, incremental (recommended)
./phone_backup.sh

# Speed mode: Faster first backup, no resume
BACKUP_METHOD=pull ./phone_backup.sh
```

## Resume Failed Backup

Just re-run with **same folder name**. BetterADBSync (adbsync) resumes automatically.

## External Drive Backup

After phone backup completes:

- Detects connected drives automatically
- Select drive from menu
- Prompts Y/n for each directory individually (like phone backup)
- Uses rsync (safe, resumable, incremental)
- Can skip directories you don't want on external drive

## Tips

- **First backup:** Use `BACKUP_METHOD=pull` for speed
- **Regular backups:** Use default (BetterADBSync) for efficiency
- **USB 3.0 ports:** 10x faster than USB 2.0
- **Keep phone unlocked** during transfer
- **Check logs:** `~/backups/your_folder/backup_*.log`

## Troubleshooting

```bash
# Device not detected
adb devices
adb kill-server && adb start-server

# BetterADBSync not found (falls back to adb pull automatically)
pip3 install --user BetterADBSync
export PATH="$HOME/.local/bin:$PATH"

# Verify installation
adbsync --help

# Source path doesn't exist
# Check path in backup_paths.ini matches your phone's structure
```

## File Structure

```
backup_paths.ini      # What to backup (edit this)
phone_backup.sh       # Main script
setup.sh              # Dependency installer
PERFORMANCE.md        # Detailed performance guide
```

## Common Configs

**Minimal (photos only):**

```ini
[DCIM]
path=DCIM
description=Camera
enabled=true
```

**Full backup:**
Enable all paths in `backup_paths.ini`

**Selective:**
Set `enabled=false` for paths you want to skip

---

**That's it!** Run `./phone_backup.sh` and follow prompts.
