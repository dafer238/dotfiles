# Installation

### Clone the dotfiles
```bash
git clone --recurse-submodules https://github.com/dafer238/dotfiles.git ~/dev
```
or with SSH privileges

```bash
git clone --recurse-submodules git@github.com:dafer238/dotfiles.git ~/dev
```

### Clone and link files, dependancies need to be installed manually
```bash
git clone --recurse-submodules https://github.com/dafer238/dotfiles.git ~/dev
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
