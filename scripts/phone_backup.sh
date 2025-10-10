#!/usr/bin/env bash
# ==================================================
# Android Backup Script (via ADB)
# Author: dafer
# ==================================================

CONFIG_FILE="${1:-$HOME/scripts/backup_paths.conf}"
BACKUP_DIR="$HOME/Documents/backup"
LOG_FILE="$BACKUP_DIR/backup_$(date +%Y%m%d_%H%M%S).log"

check_adb() {
    if ! command -v adb >/dev/null 2>&1; then
        echo "❌ adb not found. Install it first: sudo pacman -S android-tools"
        exit 1
    fi
}

check_device() {
    echo "🔍 Checking for connected Android device..."
    adb start-server >/dev/null
    DEVICE=$(adb devices | grep -w "device" | awk '{print $1}')
    if [ -z "$DEVICE" ]; then
        echo "❌ No device detected. Make sure USB Debugging is enabled and confirm authorization on your phone."
        exit 1
    else
        echo "✅ Device detected: $DEVICE"
    fi
}

backup_folder() {
    local folder=$1
    local target_dir="$BACKUP_DIR/$folder"
    local parent_dir
    parent_dir=$(dirname "$target_dir")
    mkdir -p "$parent_dir"
    echo "-----------------------------------------------------" | tee -a "$LOG_FILE"
    echo "📂 Backing up /sdcard/$folder → $target_dir" | tee -a "$LOG_FILE"
    adb pull "/sdcard/$folder" "$parent_dir" | tee -a "$LOG_FILE"
    echo "✅ Finished backing up $folder" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

# ====== MAIN ======
check_adb
check_device
mkdir -p "$BACKUP_DIR"

echo "=== 📦 ANDROID BACKUP STARTED $(date) ===" | tee "$LOG_FILE"
echo "Logs saved to: $LOG_FILE" | tee -a "$LOG_FILE"
echo "📄 Using config file: $CONFIG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Read config safely, preserving folder names with spaces
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    backup_folder "$line"
done < "$CONFIG_FILE"

echo "🎉 All backups completed successfully at $(date)" | tee -a "$LOG_FILE"
echo "Files saved in: $BACKUP_DIR"
echo "Log file: $LOG_FILE"

