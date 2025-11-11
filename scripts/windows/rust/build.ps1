# Build script for Rust versions of APE and SPE
# PowerShell version

Write-Host "================================" -ForegroundColor Cyan
Write-Host "Building Rust Versions of APE and SPE" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Check if Rust is installed
try {
    $null = Get-Command cargo -ErrorAction Stop
} catch {
    Write-Host "Error: Cargo not found. Please install Rust from https://rustup.rs/" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Rust version:" -ForegroundColor Green
rustc --version
Write-Host ""
Write-Host "Cargo version:" -ForegroundColor Green
cargo --version
Write-Host ""

# Build both programs
Write-Host "Building APE and SPE..." -ForegroundColor Yellow
Write-Host ""
cargo build --release
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Error: Failed to build" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host ""
Write-Host "Build successful!" -ForegroundColor Green
Write-Host ""

# Show file sizes
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Build Complete!" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Compiled binaries:" -ForegroundColor Green
Write-Host ""

if (Test-Path "target\release\ape.exe") {
    $apeSize = (Get-Item "target\release\ape.exe").Length / 1KB
    Write-Host "  ape.exe - $([math]::Round($apeSize, 2)) KB"
}

if (Test-Path "target\release\spe.exe") {
    $speSize = (Get-Item "target\release\spe.exe").Length / 1KB
    Write-Host "  spe.exe - $([math]::Round($speSize, 2)) KB"
}
Write-Host ""

# Ask if user wants to copy to parent directory
Write-Host ""
$response = Read-Host "Copy binaries to parent Scripts directory? (Y/N)"
if ($response -eq 'Y' -or $response -eq 'y') {
    Write-Host ""
    Write-Host "Copying files..." -ForegroundColor Yellow

    $parentDir = Split-Path -Parent $PSScriptRoot

    Copy-Item -Path "target\release\ape.exe" -Destination "$parentDir\ape.exe" -Force
    Copy-Item -Path "target\release\spe.exe" -Destination "$parentDir\spe.exe" -Force

    Write-Host ""
    Write-Host "Files copied to: $parentDir" -ForegroundColor Green
    Write-Host ""
    Write-Host "You can now use 'ape' and 'spe' from anywhere (if Scripts is in PATH)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Binaries are located at: $PSScriptRoot\target\release\" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To install manually:" -ForegroundColor Yellow
    Write-Host "  1. Copy target\release\ape.exe to a directory in your PATH"
    Write-Host "  2. Copy target\release\spe.exe to a directory in your PATH"
    Write-Host ""
    Write-Host "Or run this script again and choose 'Y' to copy automatically."
}

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Done!" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit"
