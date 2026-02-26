#!/usr/bin/env bash

echo "[*] Installing base packages..."

sudo apt update && sudo apt upgrade -y

sudo apt install -y build-essential git curl wget unzip zip sudo openssh-client \
    default-jdk fzf ripgrep zsh tmux clang gcc

# lazygit (not in standard apt repos)
if ! command -v lazygit &>/dev/null; then
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    curl -Lo /tmp/lazygit.tar.gz \
        "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar -xf /tmp/lazygit.tar.gz -C /tmp lazygit
    sudo install /tmp/lazygit /usr/local/bin
fi

# neovim (apt version is often outdated; use the official AppImage)
if ! command -v nvim &>/dev/null; then
    curl -Lo /tmp/nvim.appimage https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage
    chmod u+x /tmp/nvim.appimage
    sudo mv /tmp/nvim.appimage /usr/local/bin/nvim
fi

# starship
if ! command -v starship &>/dev/null; then
    curl -sS https://starship.rs/install.sh | sh -s -- --yes
fi

# Node.js + npm (LTS via NodeSource)
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
fi

# tree-sitter CLI (via npm)
if ! command -v tree-sitter &>/dev/null; then
    sudo npm install -g tree-sitter-cli
fi

# uv (Python package manager)
if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# rustup
if ! command -v rustup &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

# zig (latest stable via official tarball from ziglang.org)
if ! command -v zig &>/dev/null; then
    ZIG_VERSION=$(curl -s https://ziglang.org/download/index.json \
        | grep -o '"[0-9]*\.[0-9]*\.[0-9]*"' | head -1 | tr -d '"')
    curl -Lo /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    sudo tar -xf /tmp/zig.tar.xz -C /usr/local/lib
    sudo ln -sf "/usr/local/lib/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig
fi

# TeX Live
sudo apt install -y texlive texlive-fonts-extra texlive-latex-extra

echo "[*] Base packages installed."
