# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"
    
# Enable plugins
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)

# Source the plugins
source $ZSH/oh-my-zsh.sh

# Initialize starship
eval "$(starship init zsh)"

# Add cargo to path
# source "$HOME/.cargo/env"

# Automatically attach to the last session or create a new one
if [[ -z "$TMUX" ]]; then
    # Check for existing sessions
    if tmux ls &>/dev/null; then
        # Attach to the last session
        tmux attach -t $(tmux ls -F "#{session_name}" | tail -n1)
    else
        # Create a new "dev" session with specific windows
        tmux new-session -d -s dev

        # Create second window for Neovim
        tmux new-window -t dev:2

        # Attach to the first window
        tmux select-window -t dev:1
        tmux attach -t dev
    fi
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

# Always start in the home directory
cd ~
