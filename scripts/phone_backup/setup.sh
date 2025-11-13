#!/usr/bin/env bash
# ==================================================
# Android Backup Script - Setup & Dependency Installer
# Version: 3.0 (better-adb-sync)
# ==================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

print_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/arch-release ]; then
            OS="arch"
        elif [ -f /etc/debian_version ]; then
            OS="debian"
        elif [ -f /etc/fedora-release ]; then
            OS="fedora"
        else
            OS="linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        OS="windows"
    else
        OS="unknown"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install ADB
install_adb() {
    print_header "Installing ADB (Android Debug Bridge)"

    if command_exists adb; then
        print_success "ADB is already installed"
        adb --version
        return 0
    fi

    case "$OS" in
        arch)
            print_info "Installing via pacman..."
            sudo pacman -S --noconfirm android-tools
            ;;
        debian)
            print_info "Installing via apt..."
            sudo apt update
            sudo apt install -y adb
            ;;
        fedora)
            print_info "Installing via dnf..."
            sudo dnf install -y android-tools
            ;;
        macos)
            if command_exists brew; then
                print_info "Installing via Homebrew..."
                brew install android-platform-tools
            else
                print_error "Homebrew not found. Install from: https://brew.sh/"
                return 1
            fi
            ;;
        windows)
            print_warning "Please download and install ADB manually:"
            echo "https://developer.android.com/tools/releases/platform-tools"
            echo ""
            echo "After installation, add platform-tools to your PATH"
            return 1
            ;;
        *)
            print_error "Unsupported OS. Install ADB manually:"
            echo "https://developer.android.com/tools/releases/platform-tools"
            return 1
            ;;
    esac

    if command_exists adb; then
        print_success "ADB installed successfully"
    else
        print_error "ADB installation failed"
        return 1
    fi
}

# Install Python3 & pip
install_python() {
    print_header "Checking Python 3"

    if command_exists python3; then
        print_success "Python 3 is already installed"
        python3 --version
    else
        print_warning "Python 3 not found. Installing..."
        case "$OS" in
            arch)
                sudo pacman -S --noconfirm python python-pip
                ;;
            debian)
                sudo apt update
                sudo apt install -y python3 python3-pip
                ;;
            fedora)
                sudo dnf install -y python3 python3-pip
                ;;
            macos)
                if command_exists brew; then
                    brew install python3
                fi
                ;;
        esac
    fi

    # Ensure pip is available
    if ! command_exists pip3 && ! command_exists pip; then
        print_warning "pip not found. Installing..."
        case "$OS" in
            arch)
                sudo pacman -S --noconfirm python-pip
                ;;
            debian)
                sudo apt install -y python3-pip
                ;;
            fedora)
                sudo dnf install -y python3-pip
                ;;
            macos)
                python3 -m ensurepip --upgrade
                ;;
        esac
    fi
}

# Install better-adb-sync
install_better_adb_sync() {
    print_header "Installing BetterADBSync"

    if command_exists adbsync; then
        print_success "adbsync is already installed"
        return 0
    fi

    print_info "Installing BetterADBSync via pip..."
    echo ""
    echo "Repository: https://github.com/jb2170/better-adb-sync"
    echo "Note: BetterADBSync is a maintained fork of the deprecated adb-sync"
    echo ""

    # Try pip3 first, then pip
    if command_exists pip3; then
        pip3 install --user BetterADBSync
    elif command_exists pip; then
        pip install --user BetterADBSync
    else
        print_error "pip not found. Cannot install BetterADBSync"
        return 1
    fi

    # Check if installation was successful
    if command_exists adbsync; then
        print_success "BetterADBSync installed successfully"
    else
        print_warning "BetterADBSync installed but not in PATH"
        echo ""
        echo "Add to your ~/.bashrc or ~/.zshrc:"
        echo 'export PATH="$HOME/.local/bin:$PATH"'
        echo ""
        echo "Then run: source ~/.bashrc"
        echo ""
        echo "Or temporarily add to PATH:"
        export PATH="$HOME/.local/bin:$PATH"
        if command_exists adbsync; then
            print_success "BetterADBSync now available in PATH"
        fi
    fi
}

# Install rsync
install_rsync() {
    print_header "Checking rsync"

    if command_exists rsync; then
        print_success "rsync is already installed"
        return 0
    fi

    print_info "Installing rsync..."
    case "$OS" in
        arch)
            sudo pacman -S --noconfirm rsync
            ;;
        debian)
            sudo apt install -y rsync
            ;;
        fedora)
            sudo dnf install -y rsync
            ;;
        macos)
            print_success "rsync comes pre-installed on macOS"
            ;;
        *)
            print_warning "Please install rsync manually"
            ;;
    esac
}

# Test device connection
test_device() {
    print_header "Testing Device Connection"

    print_info "Starting ADB server..."
    adb start-server >/dev/null 2>&1 || true

    print_info "Looking for connected devices..."
    sleep 1

    local devices
    devices=$(adb devices 2>/dev/null | grep -w "device" | grep -v "List" | wc -l)

    if [ "$devices" -eq 0 ]; then
        print_warning "No devices detected"
        echo ""
        echo "To connect your device:"
        echo "1. Enable USB Debugging:"
        echo "   Settings → About Phone → Tap 'Build Number' 7x"
        echo "   Settings → Developer Options → Enable USB Debugging"
        echo ""
        echo "2. Connect USB cable"
        echo "3. Accept authorization on phone"
        echo ""
        echo "Then run: adb devices"
    else
        print_success "Device(s) detected:"
        adb devices | grep -w "device" | grep -v "List"
    fi
}

# Make scripts executable
setup_permissions() {
    print_header "Setting Up Permissions"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$script_dir/phone_backup.sh" ]; then
        chmod +x "$script_dir/phone_backup.sh"
        print_success "Made phone_backup.sh executable"
    fi

    if [ -f "$script_dir/setup.sh" ]; then
        chmod +x "$script_dir/setup.sh"
        print_success "Made setup.sh executable"
    fi
}

# Summary
print_summary() {
    print_header "Installation Summary"

    local all_ok=true

    echo "Dependency Status:"
    echo ""

    if command_exists adb; then
        print_success "ADB: Installed"
    else
        print_error "ADB: Not Found"
        all_ok=false
    fi

    if command_exists python3 || command_exists python; then
        print_success "Python 3: Installed"
    else
        print_error "Python 3: Not Found"
        all_ok=false
    fi

    if command_exists adbsync; then
        print_success "BetterADBSync: Installed"
    else
        print_warning "BetterADBSync: Not Found (will use adb pull)"
    fi

    if command_exists rsync; then
        print_success "rsync: Installed"
    else
        print_warning "rsync: Not Found (external drive backup unavailable)"
    fi

    echo ""

    if [ "$all_ok" = true ]; then
        print_success "All core dependencies installed!"
        echo ""
        echo "Next steps:"
        echo "1. Connect your Android device via USB"
        echo "2. Enable USB Debugging on your phone"
        echo "3. Run: ./phone_backup.sh"
    else
        print_warning "Some dependencies are missing"
        echo "Install missing dependencies manually or re-run this script"
    fi
}

# Main
main() {
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📱 Android Backup Script - Setup v3.0"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    detect_os
    print_info "Detected OS: $OS"

    echo ""
    read -p "Install missing dependencies? [Y/n]: " install_deps
    install_deps="${install_deps:-y}"

    if [[ "$install_deps" =~ ^[Yy]$ ]]; then
        install_adb || print_warning "ADB installation skipped/failed"
        install_python || print_warning "Python installation skipped/failed"
        install_better_adb_sync || print_warning "BetterADBSync installation skipped/failed"
        install_rsync || print_warning "rsync installation skipped/failed"
    fi

    setup_permissions
    test_device
    print_summary

    echo ""
    print_info "Documentation: see GUIDE.md and README.md"
}

main "$@"
