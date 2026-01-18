#!/usr/bin/env pwsh
# Windows Setup Script - Install Scoop and Development Packages

Write-Host "[*] Setting up Scoop package manager..." -ForegroundColor Cyan

# Set execution policy to allow Scoop installation
Write-Host "[*] Setting execution policy..." -ForegroundColor Yellow
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# Install Scoop
Write-Host "[*] Installing Scoop..." -ForegroundColor Yellow
if (!(Get-Command scoop -ErrorAction SilentlyContinue))
{
    Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
} else
{
    Write-Host "[*] Scoop is already installed" -ForegroundColor Green
}

# Update Scoop
Write-Host "[*] Updating Scoop..." -ForegroundColor Yellow
scoop update

# Add extra buckets
Write-Host "[*] Adding Scoop buckets..." -ForegroundColor Cyan
scoop bucket add extras
scoop bucket add java
scoop bucket add versions

# Install base development tools
Write-Host "[*] Installing base packages..." -ForegroundColor Cyan
$basePackages = @(
    'git',
    'curl',
    'wget',
    'unzip',
    '7zip',
    'openssh'
)

foreach ($package in $basePackages)
{
    Write-Host "[*] Installing $package..." -ForegroundColor Yellow
    scoop install $package
}

# Install development tools
Write-Host "[*] Installing development tools..." -ForegroundColor Cyan
$devTools = @(
    'openjdk',           # jdk-openjdk equivalent
    'fzf',
    'ripgrep',
    'lazygit',
    'zsh',
    'neovim',
    'starship',
    'nodejs',            # npm comes with nodejs
    'llvm',              # includes clang
    'gcc',               # via mingw
    'tree-sitter',
    'python',            # for uv (Python package manager)
    'rustup',
    'zig',
    'latex',             # MiKTeX or TeX Live
    'tmux'               # Windows port
)

foreach ($tool in $devTools)
{
    Write-Host "[*] Installing $tool..." -ForegroundColor Yellow
    scoop install $tool
}

# Install uv (Python package manager) via pip or cargo
Write-Host "[*] Installing uv (Python package manager)..." -ForegroundColor Yellow
if (Get-Command cargo -ErrorAction SilentlyContinue)
{
    cargo install uv
} elseif (Get-Command pip -ErrorAction SilentlyContinue)
{
    pip install uv
} else
{
    Write-Host "[!] Could not install uv - neither cargo nor pip found" -ForegroundColor Red
}

# Initialize rustup
Write-Host "[*] Initializing Rust toolchain..." -ForegroundColor Yellow
if (Get-Command rustup -ErrorAction SilentlyContinue)
{
    rustup default stable
}

Write-Host "[*] Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Installed packages:" -ForegroundColor Cyan
scoop list
Write-Host ""
Write-Host "You may need to restart your terminal for some changes to take effect." -ForegroundColor Yellow
