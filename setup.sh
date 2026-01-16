#!/bin/bash

# Dotfiles setup script for Linux
# This script symlinks config files from ~/dev/configs to their expected locations.

set -e

DOTFILES_DIR="$HOME/dev/configs"

# Symlink mappings: source -> destination
declare -A SYMLINKS=(
    ["$DOTFILES_DIR/config"]="$HOME/.config/ghostty/config"
    ["$DOTFILES_DIR/.zshrc"]="$HOME/.zshrc"
    ["$DOTFILES_DIR/.tmux.conf"]="$HOME/.tmux.conf"
    ["$DOTFILES_DIR/starship.toml"]="$HOME/.config/starship.toml"
    ["$DOTFILES_DIR/nvim"]="$HOME/.config/nvim"
    ["$DOTFILES_DIR/zed"]="$HOME/.config/zed"
)

echo "Setting up dotfiles..."

for SRC in "${!SYMLINKS[@]}"; do
    DEST="${SYMLINKS[$SRC]}"
    DEST_DIR=$(dirname "$DEST")

    # Create destination directory if it doesn't exist
    if [ ! -d "$DEST_DIR" ]; then
        echo "Creating directory: $DEST_DIR"
        mkdir -p "$DEST_DIR"
    fi

    # Remove existing file/symlink if present
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
        echo "Removing existing: $DEST"
        rm -rf "$DEST"
    fi

    # Create symlink
    echo "Linking $SRC -> $DEST"
    ln -s "$SRC" "$DEST"
done

echo "Dotfiles setup complete!"
