#!/usr/bin/env bash
# ==================================================
# Android Backup Script - Performance & Safety Optimized
# Author: dafer
# Version: 3.0
# ==================================================
# Features:
#   - Pure bash (no Python dependency)
#   - better-adb-sync for safety OR adb pull for raw speed
#   - Resumable, incremental backups
#   - Interactive prompts
#   - External drive rsync at the end
#   - Maximum performance with parallel options
# ==================================================

set -euo pipefail

# ====== CONFIGURATION ======
DEFAULT_BACKUP_ROOT="$HOME/backups"
DEFAULT_BACKUP_NAME="last_backup"
CONFIG_FILE="${1:-$HOME/scripts/phone_backup/backup_paths.ini}"

# Performance: Use adb-sync for safety, adb pull for speed
BACKUP_METHOD="${BACKUP_METHOD:-sync}"  # Options: sync, pull

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Global variables
BACKUP_ROOT=""
BACKUP_NAME=""
BACKUP_DIR=""
LOG_FILE=""
DEVICE=""
BACKED_UP_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# ====== HELPER FUNCTIONS ======

print_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >/dev/null
}

# ====== DEPENDENCY CHECKS ======

check_adb() {
    if ! command -v adb >/dev/null 2>&1; then
        print_error "adb not found."
        echo ""
        echo "Install it:"
        echo "  - Linux: sudo pacman -S android-tools"
        echo "  - macOS: brew install android-platform-tools"
        echo "  - Windows: https://developer.android.com/tools/releases/platform-tools"
        exit 1
    fi
}

check_backup_method() {
    if [ "$BACKUP_METHOD" = "sync" ]; then
        if ! command -v adbsync >/dev/null 2>&1; then
            print_warning "BetterADBSync not found. Falling back to adb pull."
            echo ""
            echo "For resumable/incremental backups, install BetterADBSync:"
            echo "  pip3 install BetterADBSync --user"
            echo ""
            BACKUP_METHOD="pull"
            sleep 2
        else
            print_success "Using BetterADBSync (safe, resumable, incremental)"
        fi
    else
        print_info "Using adb pull (maximum speed, no resume)"
    fi
}

check_device() {
    print_info "Checking for connected Android device..."
    adb start-server >/dev/null 2>&1

    local device_count
    device_count=$(adb devices 2>/dev/null | grep -w "device" | grep -v "List" | wc -l)

    if [ "$device_count" -eq 0 ]; then
        print_error "No device detected."
        echo ""
        echo "Make sure:"
        echo "  1. USB Debugging is enabled"
        echo "  2. USB connection is authorized"
        echo "  3. Cable is properly connected"
        exit 1
    elif [ "$device_count" -gt 1 ]; then
        print_warning "Multiple devices detected. Using first device."
    fi

    DEVICE=$(adb devices 2>/dev/null | grep -w "device" | grep -v "List" | head -1 | awk '{print $1}')
    print_success "Device detected: $DEVICE"
}

check_rsync() {
    if ! command -v rsync >/dev/null 2>&1; then
        print_warning "rsync not found. External drive backup will be unavailable."
        return 1
    fi
    return 0
}

# ====== CONFIG PARSER (Pure Bash) ======

parse_ini_config() {
    local config_file=$1
    local current_section=""
    local path=""
    local description=""
    local enabled=""

    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            # If we have a complete entry, output it
            if [ -n "$current_section" ] && [ -n "$path" ] && [ "$enabled" = "true" ]; then
                echo "${path}|${description}"
            fi

            current_section="${BASH_REMATCH[1]}"
            path=""
            description=""
            enabled=""
        # Key-value pairs
        elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            case "$key" in
                path) path="$value" ;;
                description) description="$value" ;;
                enabled) enabled="$value" ;;
            esac
        fi
    done < "$config_file"

    # Output last entry
    if [ -n "$current_section" ] && [ -n "$path" ] && [ "$enabled" = "true" ]; then
        echo "${path}|${description}"
    fi
}

# ====== USER PROMPTS ======

prompt_backup_location() {
    print_section "📁 BACKUP LOCATION SETUP"

    read -p "Enter backup root directory [${DEFAULT_BACKUP_ROOT}]: " backup_root
    BACKUP_ROOT="${backup_root:-$DEFAULT_BACKUP_ROOT}"
    BACKUP_ROOT="${BACKUP_ROOT/#\~/$HOME}"

    read -p "Enter backup folder name [${DEFAULT_BACKUP_NAME}]: " backup_name
    BACKUP_NAME="${backup_name:-$DEFAULT_BACKUP_NAME}"

    BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_NAME}"

    echo ""
    print_info "Backup will be saved to: $BACKUP_DIR"

    if [ ! -d "$BACKUP_DIR" ]; then
        print_info "Creating backup directory..."
        mkdir -p "$BACKUP_DIR" || {
            print_error "Failed to create directory: $BACKUP_DIR"
            exit 1
        }
        print_success "Directory created"
    else
        print_info "Using existing directory"
    fi

    LOG_FILE="$BACKUP_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
}

prompt_continue() {
    local path=$1
    local description=$2

    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${MAGENTA}📂 %s${NC}\n" "$path"
    if [ -n "$description" ]; then
        printf "   ${CYAN}%s${NC}\n" "$description"
    fi
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    read -p "Backup this location? [Y/n]: " response
    response="${response:-y}"

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        print_warning "Skipped: $path"
        return 1
    fi
}

# ====== BACKUP FUNCTIONS ======

backup_with_adb_sync() {
    local source_path=$1
    local target_dir=$2

    # BetterADBSync syntax: adbsync pull ANDROID LOCAL
    # Options:
    # --del: delete files on destination that aren't on source (optional, commented for safety)
    # Note: adbsync automatically preserves timestamps

    if adbsync pull "$source_path" "$target_dir" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        return 1
    fi
}

backup_with_adb_pull() {
    local source_path=$1
    local parent_dir=$2

    # adb pull is faster but doesn't skip existing files
    # Good for first-time full backups
    if adb pull "$source_path" "$parent_dir" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        return 1
    fi
}

backup_folder() {
    local folder=$1
    local description=$2
    local source_path="/sdcard/$folder"
    local target_dir="$BACKUP_DIR/$folder"
    local parent_dir
    parent_dir=$(dirname "$target_dir")

    mkdir -p "$parent_dir"

    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📂 Backing up: $folder"
        echo "   Source: $source_path"
        echo "   Target: $target_dir"
        echo "   Method: $BACKUP_METHOD"
        echo "   Time: $(date)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } | tee -a "$LOG_FILE"

    # Check if source exists on device
    if ! adb shell "[ -e '$source_path' ]" 2>/dev/null; then
        print_warning "Path does not exist on device: $source_path" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        ((SKIPPED_COUNT++))
        return 0
    fi

    # Perform backup based on method
    local backup_success=false
    if [ "$BACKUP_METHOD" = "sync" ]; then
        if backup_with_adb_sync "$source_path" "$parent_dir"; then
            backup_success=true
        fi
    else
        if backup_with_adb_pull "$source_path"
 "$parent_dir"; then
            backup_success=true
        fi
    fi

    if [ "$backup_success" = true ]; then
        print_success "Finished: $folder" | tee -a "$LOG_FILE"
        ((BACKED_UP_COUNT++))
        track_backed_up_dir "$folder"
    else
        print_error "Failed: $folder" | tee -a "$LOG_FILE"
        ((FAILED_COUNT++))

        echo "You can re-run the script to resume this backup." | tee -a "$LOG_FILE"

        read -p "Continue with remaining backups? [Y/n]: " continue_response
        continue_response="${continue_response:-y}"

        if [[ ! "$continue_response" =~ ^[Yy]$ ]]; then
            print_error "Backup interrupted by user."
            exit 1
        fi
    fi

    echo "" | tee -a "$LOG_FILE"
}

# ====== EXTERNAL DRIVE BACKUP ======

# Track which directories were backed up
BACKED_UP_DIRS=()

track_backed_up_dir() {
    local dir=$1
    BACKED_UP_DIRS+=("$dir")
}

detect_external_drives() {
    local drives=()

    case "$(uname -s)" in
        Linux*)
            # Find mounted drives in /media and /mnt
            while IFS= read -r mount_point; do
                if [ -n "$mount_point" ] && [ -d "$mount_point" ] && [ -w "$mount_point" ]; then
                    drives+=("$mount_point")
                fi
            done < <(df -h | grep -E '/media|/mnt' | awk '{print $6}')
            ;;
        Darwin*)
            # macOS: Check /Volumes
            while IFS= read -r mount_point; do
                if [ -n "$mount_point" ] && [ "$mount_point" != "/Volumes/Macintosh HD" ]; then
                    drives+=("$mount_point")
                fi
            done < <(ls -1 /Volumes 2>/dev/null | while read vol; do echo "/Volumes/$vol"; done)
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Windows Git Bash: Check common drive letters
            for drive in {D..Z}; do
                local drive_path="/$drive"
                if [ -d "$drive_path" ] && [ -w "$drive_path" ]; then
                    drives+=("$drive_path")
                fi
            done
            ;;
    esac

    printf '%s\n' "${drives[@]}"
}

prompt_external_backup() {
    if ! check_rsync; then
        return
    fi

    # Check if any directories were backed up
    if [ ${#BACKED_UP_DIRS[@]} -eq 0 ]; then
        print_info "No directories were backed up. Skipping external drive backup."
        return
    fi

    print_section "💾 EXTERNAL DRIVE BACKUP"

    echo "Would you like to copy the backup to an external drive?"
    echo "This uses rsync (safe, resumable, incremental)."
    echo ""

    read -p "Copy to external drive? [y/N]: " external_response
    external_response="${external_response:-n}"

    if [[ ! "$external_response" =~ ^[Yy]$ ]]; then
        print_info "Skipping external drive backup"
        return
    fi

    # Detect external drives
    print_info "Detecting external drives..."
    local drives
    mapfile -t drives < <(detect_external_drives)

    if [ ${#drives[@]} -eq 0 ]; then
        print_warning "No external drives detected"
        echo ""
        echo "Manual copy command:"
        echo "  rsync -avh --progress \"$BACKUP_DIR\" /path/to/external/drive/"
        return
    fi

    # Show available drives
    echo ""
    echo "Available external drives:"
    for i in "${!drives[@]}"; do
        local size=$(df -h "${drives[$i]}" 2>/dev/null | awk 'NR==2 {print $4}')
        printf "%d) %s (Free: %s)\n" $((i+1)) "${drives[$i]}" "$size"
    done
    echo "0) Cancel"

    echo ""
    read -p "Select drive number: " drive_choice

    if [ "$drive_choice" = "0" ] || [ -z "$drive_choice" ]; then
        print_info "Cancelled external drive backup"
        return
    fi

    local selected_index=$((drive_choice - 1))
    if [ "$selected_index" -lt 0 ] || [ "$selected_index" -ge ${#drives[@]} ]; then
        print_error "Invalid selection"
        return
    fi

    local external_drive="${drives[$selected_index]}"
    local external_base="${external_drive}/AndroidBackups/${BACKUP_NAME}"

    echo ""
    print_info "Destination: $external_base"
    echo ""

    # Create base destination directory
    print_info "Creating destination directory..."
    mkdir -p "$external_base" || {
        print_error "Failed to create directory on external drive"
        return
    }

    # Perform rsync for each backed up directory
    print_section "🔄 Copying to External Drive"

    local copied_count=0
    local skipped_count=0

    for folder in "${BACKED_UP_DIRS[@]}"; do
        echo ""
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        printf "${MAGENTA}📂 %s${NC}\n" "$folder"
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        read -p "Copy this directory to external drive? [Y/n]: " copy_response
        copy_response="${copy_response:-y}"

        if [[ ! "$copy_response" =~ ^[Yy]$ ]]; then
            print_warning "Skipped: $folder"
            ((skipped_count++))
            continue
        fi

        local source_path="$BACKUP_DIR/$folder"
        local target_path="$external_base/$folder"

        if [ ! -d "$source_path" ]; then
            print_warning "Source directory does not exist: $source_path"
            ((skipped_count++))
            continue
        fi

        # Create parent directory for target
        local target_parent=$(dirname "$target_path")
        mkdir -p "$target_parent" || {
            print_error "Failed to create directory: $target_parent"
            ((skipped_count++))
            continue
        }

        echo ""
        print_info "Copying: $folder"
        echo "Source: $source_path"
        echo "Target: $target_path"
        echo ""

        # rsync options:
        # -a: archive mode (preserves permissions, timestamps, etc.)
        # -v: verbose
        # -h: human-readable sizes
        # --progress: show progress
        # --partial: keep partially transferred files
        # --append-verify: resume transfers and verify
        if rsync -avh --progress --partial --append-verify "$source_path/" "$target_path/"; then
            print_success "Copied: $folder"
            ((copied_count++))
        else
            print_error "Failed to copy: $folder"
            ((skipped_count++))

            read -p "Continue with remaining directories? [Y/n]: " continue_response
            continue_response="${continue_response:-y}"

            if [[ ! "$continue_response" =~ ^[Yy]$ ]]; then
                print_info "Stopped external drive backup"
                break
            fi
        fi
    done

    # Summary
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  External Drive Backup Summary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  Copied: $copied_count"
    echo "  Skipped: $skipped_count"
    echo "  Location: $external_base"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ $copied_count -gt 0 ]; then
        print_success "External drive backup completed!"
        echo "Backup location: $external_base"
    fi
}

# ====== MAIN SCRIPT ======

main() {
    clear

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📱 ANDROID BACKUP SCRIPT v3.0"
    echo "  Performance & Safety Optimized"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check dependencies
    print_info "Checking dependencies..."
    check_adb
    check_backup_method
    print_success "Dependencies OK"

    # Check device
    check_device

    # Prompt for backup location
    prompt_backup_location

    # Check config file
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config file not found: $CONFIG_FILE"
        echo ""
        echo "Create a config file with format:"
        echo "[SectionName]"
        echo "path=DCIM"
        echo "description=Photos"
        echo "enabled=true"
        exit 1
    fi

    print_info "Using config: $CONFIG_FILE"

    # Start backup log
    {
        echo "==================================================="
        echo "  ANDROID BACKUP SESSION"
        echo "  Started: $(date)"
        echo "  Device: $DEVICE"
        echo "  Method: $BACKUP_METHOD"
        echo "  Config: $CONFIG_FILE"
        echo "  Location: $BACKUP_DIR"
        echo "==================================================="
        echo ""
    } | tee "$LOG_FILE"

    # Parse and process backup paths
    local path_count=0

    while IFS='|' read -r path_name path_desc; do
        [ -z "$path_name" ] && continue
        ((path_count++))

        if prompt_continue "$path_name" "$path_desc"; then
            backup_folder "$path_name" "$path_desc"
        else
            ((SKIPPED_COUNT++))
            log_message "SKIPPED: $path_name"
        fi
    done < <(parse_ini_config "$CONFIG_FILE")

    # Backup Summary
    print_section "🎉 BACKUP COMPLETED"

    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  BACKUP SUMMARY"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Time: $(date)"
        echo "  Total paths: $path_count"
        echo "  Backed up: $BACKED_UP_COUNT"
        echo "  Skipped: $SKIPPED_COUNT"
        echo "  Failed: $FAILED_COUNT"
        echo "  Location: $BACKUP_DIR"
        echo "  Log: $LOG_FILE"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } | tee -a "$LOG_FILE"

    if [ $FAILED_COUNT -gt 0 ]; then
        print_warning "Some backups failed. Check log for details."
    else
        print_success "All backups completed successfully!"
    fi

    # External drive backup prompt
    prompt_external_backup

    # Final message
    echo ""
    print_section "✨ ALL DONE"
    print_success "Backup saved to: $BACKUP_DIR"
    print_info "Log file: $LOG_FILE"

    if [ $FAILED_COUNT -gt 0 ]; then
        echo ""
        print_info "To resume failed transfers, run the script again with:"
        echo "  - Same backup folder name: $BACKUP_NAME"
        echo "  - Same backup root: $BACKUP_ROOT"
    fi
}

# Run main function
main
