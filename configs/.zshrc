# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

export LANG=en_US.UTF-8
export LC_ALL=

# Enable plugins
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)

# Source the plugins
source $ZSH/oh-my-zsh.sh

# Initialize starship
eval "$(starship init zsh)"

# Add cargo to path
export PATH="$HOME/.cargo/bin:$PATH"

# Automatically attach to an unattached session, or create a new one
if [[ -z "$TMUX" ]]; then
    # Look for an existing session that has no clients attached
    unattached=$(tmux ls -F "#{session_name} #{session_attached}" 2>/dev/null \
        | awk '$2 == 0 { print $1 }' | tail -n1)

    if [[ -n "$unattached" ]]; then
        # A previously-closed terminal left a session behind — resume it
        exec tmux attach -t "$unattached"
    elif ! tmux ls &>/dev/null; then
        # No sessions exist at all — bootstrap the initial dev layout
        tmux new-session -d -s dev
        tmux new-window -t dev:2
        tmux select-window -t dev:1
        exec tmux attach -t dev
    else
        # Every session already has a client — open a fresh independent session
        exec tmux new-session
    fi
fi

# WSLg integration for Arch
if [ -d /mnt/wslg/runtime-dir ]; then
    export XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir
    export WAYLAND_DISPLAY=wayland-0
    export DISPLAY=:0
fi

# Function to activate a virtual environment from ~/code/python/venvs
ape() {
  local venv_path=~/code/python/venvs/$1
  if [ -d "$venv_path" ]; then
    source "$venv_path/bin/activate"
  else
    echo "Virtual environment '$1' not found in ~/code/python/venvs"
  fi
}

[[ -f "$HOME/.local/bin/env" ]] && . "$HOME/.local/bin/env"

# Always start in the home directory
cd ~
