#!/usr/bin/env bash

echo "[*] Installing base packages..."

sudo pacman -Syu --noconfirm

sudo pacman -S --noconfirm base-devel git curl wget unzip zip sudo openssh \
    jdk-openjdk fzf ripgrep lazygit zsh tmux neovim starship npm \
    clang gcc tree-sitter-cli uv lua rustup zig texlive-basic texlive-binextra \
    texlive-fontsextra texlive-latexextra
