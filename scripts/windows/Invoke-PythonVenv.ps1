# Invoke-PythonVenv.ps1
# PowerShell wrapper functions for APE and SPE
#
# Usage: Add the following line to your PowerShell profile ($PROFILE):
#   . "C:\path\to\Invoke-PythonVenv.ps1"
#
# This defines 'ape' and 'spe' functions that activate Python virtual
# environments in your current PowerShell session (no nested shell).

function ape {
    $marker = Join-Path $env:TEMP "_venv_activate_path.txt"
    Remove-Item $marker -ErrorAction SilentlyContinue

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) {
        # Fallback: find ape-core.exe in PATH
        $scriptDir = Split-Path (Get-Command ape-core.exe -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue
    }

    & "$scriptDir\ape-core.exe" @args

    if (Test-Path $marker) {
        $venvPath = (Get-Content $marker -Raw).Trim()
        Remove-Item $marker -ErrorAction SilentlyContinue
        $activatePs1 = Join-Path $venvPath "Scripts\Activate.ps1"
        if (Test-Path $activatePs1) {
            . $activatePs1
        } else {
            Write-Warning "Activate.ps1 not found at: $activatePs1"
        }
    }
}

function spe {
    $marker = Join-Path $env:TEMP "_venv_activate_path.txt"
    Remove-Item $marker -ErrorAction SilentlyContinue

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) {
        $scriptDir = Split-Path (Get-Command spe-core.exe -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue
    }

    & "$scriptDir\spe-core.exe" @args

    if (Test-Path $marker) {
        $venvPath = (Get-Content $marker -Raw).Trim()
        Remove-Item $marker -ErrorAction SilentlyContinue
        $activatePs1 = Join-Path $venvPath "Scripts\Activate.ps1"
        if (Test-Path $activatePs1) {
            . $activatePs1
        } else {
            Write-Warning "Activate.ps1 not found at: $activatePs1"
        }
    }
}
