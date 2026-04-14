# Invoke-PythonVenv.ps1
# PowerShell wrapper functions for APE and SPE
#
# Usage: Add the following line to your PowerShell profile ($PROFILE):
#   . "C:\path\to\Invoke-PythonVenv.ps1"
#
# This defines 'ape' and 'spe' functions that activate Python virtual
# environments in your current PowerShell session (no nested shell).

# Capture the script directory at load time (not at function invocation time)
$script:_PythonVenvToolsDir = $PSScriptRoot

function ape {
    $marker = Join-Path $env:TEMP "_venv_activate_path.txt"
    Remove-Item $marker -ErrorAction SilentlyContinue

    $exeDir = $script:_PythonVenvToolsDir
    if (-not $exeDir) {
        $cmd = Get-Command ape-core.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exeDir = Split-Path $cmd.Source }
    }

    if (-not $exeDir) {
        Write-Error "Cannot find ape-core.exe. Is it installed?"
        return
    }

    & "$exeDir\ape-core.exe" @args

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

    $exeDir = $script:_PythonVenvToolsDir
    if (-not $exeDir) {
        $cmd = Get-Command spe-core.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exeDir = Split-Path $cmd.Source }
    }

    if (-not $exeDir) {
        Write-Error "Cannot find spe-core.exe. Is it installed?"
        return
    }

    & "$exeDir\spe-core.exe" @args

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
