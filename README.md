# Installation

## Quick Setup

After cloning, run the setup script for your OS to automatically symlink dotfiles to their locations.

### Linux

```bash
git clone --recurse-submodules https://github.com/dafer238/dotfiles.git ~/dev
cd ~/dev
bash setup.sh
```

### Windows

```bat
git clone --recurse-submodules https://github.com/dafer238/dotfiles.git %USERPROFILE%\dev
cd %USERPROFILE%\dev
setup.bat
```

### SSH Clone (Linux)

```bash
git clone --recurse-submodules git@github.com:dafer238/dotfiles.git ~/dev
cd ~/dev
bash setup.sh
```

---

### Manual Linking (Linux only, if you prefer)

```bash
ln -sfn ~/dev/configs/config ~/.config/ghostty/config
ln -sfn ~/dev/configs/.zshrc ~/.zshrc
ln -sfn ~/dev/configs/.tmux.conf ~/.tmux.conf
ln -sfn ~/dev/configs/starship.toml ~/.config/starship.toml
ln -sfn ~/dev/configs/nvim ~/.config/nvim
ln -sfn ~/dev/configs/zed ~/.config/zed
```

## Pleasant development experience
![Terminal overview](https://github.com/dafer238/dafer-nvim/blob/93e4b52af0d80ae918d3b730932c0e3633b8d270/images/neofetch_desktop.png)
![Neovim setup](https://github.com/dafer238/dafer-nvim/blob/93e4b52af0d80ae918d3b730932c0e3633b8d270/images/neovim.png)
