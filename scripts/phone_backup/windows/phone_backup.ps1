# ==================================================
# Android Backup Script for Windows
# Author: dafer
# Version: 3.0 (Windows Edition)
# ==================================================

param(
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Stop"

# ====== CONFIGURATION ======
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PARENT_DIR = Split-Path -Parent $SCRIPT_DIR
$DEFAULT_BACKUP_ROOT = "$env:USERPROFILE\backups"
$DEFAULT_BACKUP_NAME = "last_backup"

# Backup method: sync (BetterADBSync) or pull (adb pull + robocopy)
$BACKUP_METHOD = $env:BACKUP_METHOD
if ([string]::IsNullOrEmpty($BACKUP_METHOD)) {
    $BACKUP_METHOD = "sync"  # Default to BetterADBSync if available
}

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $CONFIG_FILE = Join-Path $PARENT_DIR "backup_paths.ini"
} else {
    $CONFIG_FILE = $ConfigFile
}

# Global variables
$script:BACKUP_ROOT = ""
$script:BACKUP_NAME = ""
$script:BACKUP_DIR = ""
$script:LOG_FILE = ""
$script:DEVICE = ""
$script:BACKED_UP_COUNT = 0
$script:SKIPPED_COUNT = 0
$script:FAILED_COUNT = 0
$script:BACKED_UP_DIRS = @()
$script:ACTUAL_BACKUP_METHOD = ""

# ====== HELPER FUNCTIONS ======

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )

    switch ($Type) {
        "Error" {
            Write-Host "Error: $Message" -ForegroundColor Red
        }
        "Success" {
            Write-Host "Success: $Message" -ForegroundColor Green
        }
        "Warning" {
            Write-Host "Warning: $Message" -ForegroundColor Yellow
        }
        "Info" {
            Write-Host "Info: $Message" -ForegroundColor Blue
        }
        "Section" {
            Write-Host ""
            Write-Host "================================" -ForegroundColor Cyan
            Write-Host "  $Message" -ForegroundColor Cyan
            Write-Host "================================" -ForegroundColor Cyan
            Write-Host ""
        }
        "Highlight" {
            Write-Host ""
            Write-Host ">>> $Message" -ForegroundColor Magenta
        }
        default {
            Write-Host $Message
        }
    }
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Add-Content -Path $script:LOG_FILE -Value $logMessage
}

# ====== DEPENDENCY CHECKS ======

function Test-ADB {
    Write-ColorOutput "Checking for ADB..." "Info"

    $adbPath = Get-Command adb -ErrorAction SilentlyContinue

    if (-not $adbPath) {
        Write-ColorOutput "ADB not found." "Error"
        Write-Host ""
        Write-Host "Install Android Platform Tools:"
        Write-Host "  1. Download from: https://developer.android.com/tools/releases/platform-tools"
        Write-Host "  2. Extract to a folder (e.g., C:\platform-tools)"
        Write-Host "  3. Add the folder to your PATH environment variable"
        Write-Host ""
        Write-Host "Or use: winget install Google.PlatformTools"
        exit 1
    }

    Write-ColorOutput "ADB found: $($adbPath.Source)" "Success"
}

function Test-BackupMethod {
    Write-ColorOutput "Checking backup method..." "Info"

    if ($BACKUP_METHOD -eq "sync") {
        # Check for adbsync (BetterADBSync)
        $adbsyncPath = Get-Command adbsync -ErrorAction SilentlyContinue

        if ($adbsyncPath) {
            Write-ColorOutput "BetterADBSync found - using safe, resumable, incremental sync" "Success"
            $script:ACTUAL_BACKUP_METHOD = "sync"
        } else {
            Write-ColorOutput "BetterADBSync not found - falling back to adb pull + robocopy" "Warning"
            Write-Host ""
            Write-Host "For resumable/incremental backups directly from device, install BetterADBSync:"
            Write-Host "  pip install BetterADBSync --user"
            Write-Host "  or: python -m pip install BetterADBSync --user"
            Write-Host ""
            Start-Sleep -Seconds 2
            $script:ACTUAL_BACKUP_METHOD = "pull"
        }
    } else {
        Write-ColorOutput "Using adb pull + robocopy (maximum speed)" "Info"
        $script:ACTUAL_BACKUP_METHOD = "pull"
    }
}

function Test-Device {
    Write-ColorOutput "Checking for connected Android device..." "Info"

    & adb start-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500

    $devices = & adb devices 2>&1 | Select-String -Pattern "\tdevice$"

    if ($devices.Count -eq 0) {
        Write-ColorOutput "No device detected." "Error"
        Write-Host ""
        Write-Host "Make sure:"
        Write-Host "  1. USB Debugging is enabled"
        Write-Host "  2. USB connection is authorized"
        Write-Host "  3. Cable is properly connected"
        exit 1
    } elseif ($devices.Count -gt 1) {
        Write-ColorOutput "Multiple devices detected. Using first device." "Warning"
    }

    $script:DEVICE = ($devices[0] -split '\s+')[0]
    Write-ColorOutput "Device detected: $($script:DEVICE)" "Success"
}

# ====== CONFIG PARSER ======

function Parse-IniConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        Write-ColorOutput "Config file not found: $ConfigPath" "Error"
        exit 1
    }

    $entries = @()
    $currentSection = ""
    $currentPath = ""
    $currentDescription = ""
    $currentEnabled = ""

    Get-Content $ConfigPath | ForEach-Object {
        $line = $_.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            return
        }

        if ($line -match '^\[(.+)\]$') {
            if ($currentSection -and $currentPath -and $currentEnabled -eq "true") {
                $entries += [PSCustomObject]@{
                    Path = $currentPath
                    Description = $currentDescription
                }
            }

            $currentSection = $matches[1]
            $currentPath = ""
            $currentDescription = ""
            $currentEnabled = ""
        }
        elseif ($line -match '^(.+?)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()

            switch ($key) {
                "path" { $currentPath = $value }
                "description" { $currentDescription = $value }
                "enabled" { $currentEnabled = $value }
            }
        }
    }

    if ($currentSection -and $currentPath -and $currentEnabled -eq "true") {
        $entries += [PSCustomObject]@{
            Path = $currentPath
            Description = $currentDescription
        }
    }

    return $entries
}

# ====== USER PROMPTS ======

function Get-BackupLocation {
    Write-ColorOutput "BACKUP LOCATION SETUP" "Section"

    $backupRoot = Read-Host "Enter backup root directory [$DEFAULT_BACKUP_ROOT]"
    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        $script:BACKUP_ROOT = $DEFAULT_BACKUP_ROOT
    } else {
        $script:BACKUP_ROOT = $backupRoot
    }

    $backupName = Read-Host "Enter backup folder name [$DEFAULT_BACKUP_NAME]"
    if ([string]::IsNullOrWhiteSpace($backupName)) {
        $script:BACKUP_NAME = $DEFAULT_BACKUP_NAME
    } else {
        $script:BACKUP_NAME = $backupName
    }

    $script:BACKUP_DIR = Join-Path $script:BACKUP_ROOT $script:BACKUP_NAME

    Write-Host ""
    Write-ColorOutput "Backup will be saved to: $($script:BACKUP_DIR)" "Info"

    if (-not (Test-Path $script:BACKUP_DIR)) {
        Write-ColorOutput "Creating backup directory..." "Info"
        New-Item -ItemType Directory -Path $script:BACKUP_DIR -Force | Out-Null
        Write-ColorOutput "Directory created" "Success"
    } else {
        Write-ColorOutput "Using existing directory" "Info"
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LOG_FILE = Join-Path $script:BACKUP_DIR "backup_$timestamp.log"
}

function Get-UserConfirmation {
    param(
        [string]$Path,
        [string]$Description
    )

    Write-ColorOutput $Path "Highlight"
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        Write-Host "   $Description" -ForegroundColor Cyan
    }

    $response = Read-Host "Backup this location? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($response)) {
        $response = "y"
    }

    if ($response -match '^[Yy]') {
        return $true
    } else {
        Write-ColorOutput "Skipped: $Path" "Warning"
        return $false
    }
}

# ====== BACKUP FUNCTIONS ======

function Test-DeviceConnection {
    param(
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $devices = & adb devices 2>&1 | Select-String -Pattern "device$"
        if ($devices) {
            return $true
        }

        if ($i -lt $MaxRetries) {
            Write-ColorOutput "Device connection check failed (attempt $i/$MaxRetries). Retrying in $RetryDelaySeconds seconds..." "Warning"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    return $false
}

function Backup-WithAdbSync {
    param(
        [string]$SourcePath,
        [string]$TargetDir
    )

    Write-ColorOutput "Syncing with BetterADBSync..." "Info"

    # Check device connection before attempting sync
    if (-not (Test-DeviceConnection)) {
        Write-ColorOutput "Device connection lost. Please check USB connection and try again." "Error"
        Write-Log "Device connection check failed before sync"
        return $false
    }

    # adbsync syntax: adbsync push LOCAL ANDROID  or  adbsync pull ANDROID LOCAL
    $adbsyncArgs = @(
        "pull",
        $SourcePath,
        $TargetDir
    )

    $maxAttempts = 2
    $attemptDelay = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-ColorOutput "Retry attempt $attempt of $maxAttempts..." "Info"
            Start-Sleep -Seconds $attemptDelay
        }

        # Capture output without treating stderr as exceptions
        $outputLines = @()
        $errorLines = @()

        try {
            # Run adbsync and capture output line by line
            $process = Start-Process -FilePath "adbsync" -ArgumentList $adbsyncArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\adbsync_out.txt" -RedirectStandardError "$env:TEMP\adbsync_err.txt"
            $exitCode = $process.ExitCode

            if (Test-Path "$env:TEMP\adbsync_out.txt") {
                $outputLines = Get-Content "$env:TEMP\adbsync_out.txt" -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\adbsync_out.txt" -Force -ErrorAction SilentlyContinue
            }

            if (Test-Path "$env:TEMP\adbsync_err.txt") {
                $errorLines = Get-Content "$env:TEMP\adbsync_err.txt" -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\adbsync_err.txt" -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log "AdbSync execution error: $_"
            Write-ColorOutput "Failed to execute adbsync: $_" "Error"

            if ($attempt -lt $maxAttempts) {
                Write-ColorOutput "Will retry after delay..." "Warning"
                continue
            }
            return $false
        }

        # Log all output (but don't display verbose tree info)
        $outputLines | ForEach-Object { Write-Log $_ }
        $errorLines | ForEach-Object { Write-Log "STDERR: $_" }

        # Count synced files and show summary only
        $syncedFiles = ($outputLines | Select-String -Pattern "PULL").Count
        $skippedFiles = ($outputLines | Select-String -Pattern "SKIP").Count

        if ($syncedFiles -gt 0) {
            Write-Host "Synced: $syncedFiles files"
        } elseif ($skippedFiles -gt 0) {
            Write-Host "All files up to date (checked: $skippedFiles files)"
        } else {
            Write-Host "No files to sync"
        }

        # Check for critical errors in output
        $allOutput = $outputLines + $errorLines
        $criticalErrors = $allOutput | Select-String -Pattern "\[ERROR\]|error:|failed|cannot connect|device not found|device offline|permission denied" -CaseSensitive:$false

        if ($exitCode -eq 0) {
            return $true
        } elseif ($criticalErrors) {
            # Check if it's a transient connection error that we should retry
            $transientErrors = $allOutput | Select-String -Pattern "device offline|connection|timeout" -CaseSensitive:$false
            if ($transientErrors -and $attempt -lt $maxAttempts) {
                Write-ColorOutput "Transient connection error detected. Will retry..." "Warning"
                continue
            }

            # Non-zero exit with critical errors - show them
            Write-ColorOutput "Critical errors detected:" "Error"
            $criticalErrors | ForEach-Object { Write-Host "  $_" }
            Write-Log "Critical errors: $criticalErrors"

            if ($attempt -lt $maxAttempts) {
                continue
            }
            return $false
        } else {
            # Non-zero exit but no critical errors - likely just warnings
            # Consider it successful if we're in an existing backup directory or if files were synced/checked
            if ((Test-Path $TargetDir) -or ($syncedFiles -gt 0) -or ($skippedFiles -gt 0)) {
                if ($exitCode -ne 0) {
                    Write-ColorOutput "Completed with warnings (exit code: $exitCode)" "Warning"
                    Write-Log "Completed with warnings - exit code: $exitCode"
                }
                return $true
            } else {
                Write-ColorOutput "Failed with exit code: $exitCode" "Error"
                if ($errorLines) {
                    Write-Host "Error output:"
                    $errorLines | ForEach-Object { Write-Host "  $_" }
                }

                if ($attempt -lt $maxAttempts) {
                    continue
                }
                return $false
            }
        }
    }

    # If we get here, all attempts failed
    return $false
}

function Backup-WithAdbPull {
    param(
        [string]$SourcePath,
        [string]$TargetDir
    )

    Write-ColorOutput "Pulling files from device..." "Info"

    $tempDir = Join-Path $env:TEMP "android_backup_temp"
    if (Test-Path $tempDir) {
        Remove-Item -Recurse -Force $tempDir
    }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $pullCmd = "adb pull `"$SourcePath`" `"$tempDir`""
    Write-Log "Executing: $pullCmd"

    $pullOutput = Invoke-Expression $pullCmd 2>&1
    $pullOutput | ForEach-Object { Write-Host $_ }
    $pullOutput | ForEach-Object { Write-Log $_ }

    $pulledFolder = Get-ChildItem -Path $tempDir | Select-Object -First 1
    if (-not $pulledFolder) {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        return $false
    }

    Write-ColorOutput "Syncing to backup directory..." "Info"

    $sourceForRobocopy = $pulledFolder.FullName

    $robocopyArgs = @(
        $sourceForRobocopy,
        $TargetDir,
        "/E",
        "/DCOPY:DAT",
        "/R:3",
        "/W:5",
        "/MT:8",
        "/XO"
    )

    $robocopyOutput = & robocopy @robocopyArgs
    $robocopyExitCode = $LASTEXITCODE

    # Clean up temp directory
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

    # Robocopy exit codes: 0-7 are success, 8+ are errors
    if ($robocopyExitCode -lt 8) {
        $robocopyOutput | ForEach-Object { Write-Log $_ }
        return $true
    } else {
        Write-Log "Robocopy failed with exit code: $robocopyExitCode"
        return $false
    }
}

function Backup-Folder {
    param(
        [string]$Folder,
        [string]$Description
    )

    $sourcePath = "/sdcard/$Folder"
    $targetDir = Join-Path $script:BACKUP_DIR $Folder
    $parentDir = Split-Path -Parent $targetDir

    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $logMessage = "Backing up: $Folder from $sourcePath to $targetDir at $(Get-Date) using method: $($script:ACTUAL_BACKUP_METHOD)"
    Write-Host $logMessage
    Write-Log $logMessage

    $checkCmd = "adb shell `"[ -e '$sourcePath' ] && echo EXISTS || echo NOTFOUND`""
    $exists = Invoke-Expression $checkCmd 2>&1 | Select-String -Pattern "EXISTS"

    if (-not $exists) {
        $msg = "Path does not exist on device: $sourcePath"
        Write-ColorOutput $msg "Warning"
        Write-Log $msg
        Write-Host ""
        $script:SKIPPED_COUNT++
        return
    }

    Write-ColorOutput "Counting files on device..." "Info"
    $countCmd = "adb shell `"find '$sourcePath' -type f 2>/dev/null | wc -l`""
    $fileCount = Invoke-Expression $countCmd 2>&1
    $fileCount = $fileCount.Trim()
    Write-Host "Files to backup: $fileCount"
    Write-Log "Files to backup: $fileCount"

    # Perform backup based on method
    $backupSuccess = $false
    try {
        if ($script:ACTUAL_BACKUP_METHOD -eq "sync") {
            $backupSuccess = Backup-WithAdbSync -SourcePath $sourcePath -TargetDir $targetDir
        } else {
            $backupSuccess = Backup-WithAdbPull -SourcePath $sourcePath -TargetDir $targetDir
        }

        if ($backupSuccess) {
            Write-ColorOutput "Finished: $Folder" "Success"
            Write-Log "SUCCESS: $Folder"
            $script:BACKED_UP_COUNT++
            $script:BACKED_UP_DIRS += $Folder
        } else {
            throw "Backup operation returned failure"
        }
    } catch {
        $errorMsg = "Failed: $Folder - $_"
        Write-ColorOutput $errorMsg "Error"
        Write-Log "ERROR: $errorMsg"
        $script:FAILED_COUNT++

        Write-Host ""
        Write-Host "You can re-run the script to resume this backup."

        $continueResponse = Read-Host "Continue with remaining backups? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($continueResponse)) {
            $continueResponse = "y"
        }

        if ($continueResponse -notmatch '^[Yy]') {
            Write-ColorOutput "Backup interrupted by user." "Error"
            exit 1
        }
    }

    Write-Host ""
}

# ====== EXTERNAL DRIVE BACKUP ======

function Get-ExternalDrives {
    $drives = @()

    $systemDrive = $env:SystemDrive.Substring(0, 1)

    Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Name.Length -eq 1 -and
        $_.Name -ne $systemDrive -and
        $_.Used -ne $null
    } | ForEach-Object {
        $driveLetter = $_.Name
        $driveInfo = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue

        if ($driveInfo) {
            $drives += [PSCustomObject]@{
                Letter = $driveLetter
                Path = "$($driveLetter):\"
                Label = $driveInfo.FileSystemLabel
                FreeSpace = [math]::Round($driveInfo.SizeRemaining / 1GB, 2)
                Size = [math]::Round($driveInfo.Size / 1GB, 2)
            }
        }
    }

    return $drives
}

function Start-ExternalBackup {
    if ($script:BACKED_UP_DIRS.Count -eq 0) {
        Write-ColorOutput "No directories were backed up. Skipping external drive backup." "Info"
        return
    }

    Write-ColorOutput "EXTERNAL DRIVE BACKUP" "Section"

    Write-Host "Would you like to copy the backup to an external drive?"
    Write-Host "This uses robocopy (safe, resumable, incremental)."
    Write-Host ""

    $externalResponse = Read-Host "Copy to external drive? [y/N]"
    if ([string]::IsNullOrWhiteSpace($externalResponse)) {
        $externalResponse = "n"
    }

    if ($externalResponse -notmatch '^[Yy]') {
        Write-ColorOutput "Skipping external drive backup" "Info"
        return
    }

    Write-ColorOutput "Detecting external drives..." "Info"
    $drives = Get-ExternalDrives

    if ($drives.Count -eq 0) {
        Write-ColorOutput "No external drives detected" "Warning"
        Write-Host ""
        Write-Host "After connecting a drive, you can manually copy with:"
        Write-Host "  robocopy `"$($script:BACKUP_DIR)`" `"X:\AndroidBackups\$($script:BACKUP_NAME)`" /E /DCOPY:DAT"
        return
    }

    Write-Host ""
    Write-Host "Available drives:"
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $drive = $drives[$i]
        $label = if ($drive.Label) { $drive.Label } else { "Unlabeled" }
        Write-Host "$($i+1)) $($drive.Path) [$label] (Free: $($drive.FreeSpace) GB / $($drive.Size) GB)"
    }
    Write-Host "0) Cancel"

    Write-Host ""
    $driveChoice = Read-Host "Select drive number"

    if ($driveChoice -eq "0" -or [string]::IsNullOrWhiteSpace($driveChoice)) {
        Write-ColorOutput "Cancelled external drive backup" "Info"
        return
    }

    $selectedIndex = [int]$driveChoice - 1
    if ($selectedIndex -lt 0 -or $selectedIndex -ge $drives.Count) {
        Write-ColorOutput "Invalid selection" "Error"
        return
    }

    $externalDrive = $drives[$selectedIndex]
    $externalBase = Join-Path $externalDrive.Path "AndroidBackups\$($script:BACKUP_NAME)"

    Write-Host ""
    Write-ColorOutput "Destination: $externalBase" "Info"
    Write-Host ""

    Write-ColorOutput "Creating destination directory..." "Info"
    New-Item -ItemType Directory -Path $externalBase -Force | Out-Null

    Write-ColorOutput "COPYING TO EXTERNAL DRIVE" "Section"

    $copiedCount = 0
    $skippedCount = 0

    foreach ($folder in $script:BACKED_UP_DIRS) {
        Write-ColorOutput $folder "Highlight"

        $copyResponse = Read-Host "Copy this directory to external drive? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($copyResponse)) {
            $copyResponse = "y"
        }

        if ($copyResponse -notmatch '^[Yy]') {
            Write-ColorOutput "Skipped: $folder" "Warning"
            $skippedCount++
            continue
        }

        $sourcePath = Join-Path $script:BACKUP_DIR $folder
        $targetPath = Join-Path $externalBase $folder

        if (-not (Test-Path $sourcePath)) {
            Write-ColorOutput "Source directory does not exist: $sourcePath" "Warning"
            $skippedCount++
            continue
        }

        Write-Host ""
        Write-ColorOutput "Copying: $folder" "Info"
        Write-Host "Source: $sourcePath"
        Write-Host "Target: $targetPath"
        Write-Host ""

        $robocopyArgs = @(
            $sourcePath,
            $targetPath,
            "/E",
            "/DCOPY:DAT",
            "/R:3",
            "/W:5",
            "/MT:8",
            "/XO"
        )

        $robocopyOutput = & robocopy @robocopyArgs
        $robocopyExitCode = $LASTEXITCODE

        if ($robocopyExitCode -lt 8) {
            Write-ColorOutput "Copied: $folder" "Success"
            $copiedCount++
        } else {
            Write-ColorOutput "Failed to copy: $folder (Exit code: $robocopyExitCode)" "Error"
            $skippedCount++

            $continueResponse = Read-Host "Continue with remaining directories? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($continueResponse)) {
                $continueResponse = "y"
            }

            if ($continueResponse -notmatch '^[Yy]') {
                Write-ColorOutput "Stopped external drive backup" "Info"
                break
            }
        }
    }

    Write-Host ""
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "  External Drive Backup Summary" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "  Copied: $copiedCount"
    Write-Host "  Skipped: $skippedCount"
    Write-Host "  Location: $externalBase"
    Write-Host "================================" -ForegroundColor Cyan

    if ($copiedCount -gt 0) {
        Write-ColorOutput "External drive backup completed!" "Success"
        Write-Host "Backup location: $externalBase"
    }
}

# ====== MAIN SCRIPT ======

function Main {
    Clear-Host

    Write-Host "=============================================="
    Write-Host "  Android Backup Script v3.0 (Windows)"
    Write-Host "  Performance & Safety Optimized"
    Write-Host "=============================================="
    Write-Host ""

    Write-ColorOutput "Checking dependencies..." "Info"
    Test-ADB
    Test-BackupMethod
    Write-ColorOutput "Dependencies OK" "Success"

    Test-Device

    Get-BackupLocation

    if (-not (Test-Path $CONFIG_FILE)) {
        Write-ColorOutput "Config file not found: $CONFIG_FILE" "Error"
        Write-Host ""
        Write-Host "Create a config file with format:"
        Write-Host "[SectionName]"
        Write-Host "path=DCIM"
        Write-Host "description=Photos"
        Write-Host "enabled=true"
        exit 1
    }

    Write-ColorOutput "Using config: $CONFIG_FILE" "Info"

    $logHeader = "Android Backup Session Started: $(Get-Date), Device: $($script:DEVICE), Method: $($script:ACTUAL_BACKUP_METHOD), Config: $CONFIG_FILE, Location: $($script:BACKUP_DIR)"
    Write-Host $logHeader
    Write-Log $logHeader

    $entries = Parse-IniConfig $CONFIG_FILE
    $pathCount = $entries.Count

    foreach ($entry in $entries) {
        if (Get-UserConfirmation -Path $entry.Path -Description $entry.Description) {
            Backup-Folder -Folder $entry.Path -Description $entry.Description
        } else {
            $script:SKIPPED_COUNT++
            Write-Log "SKIPPED: $($entry.Path)"
        }
    }

    Write-ColorOutput "BACKUP COMPLETED" "Section"

    $summary = @"
================================
  BACKUP SUMMARY
================================
  Time: $(Get-Date)
  Method: $($script:ACTUAL_BACKUP_METHOD)
  Total paths: $pathCount
  Backed up: $($script:BACKED_UP_COUNT)
  Skipped: $($script:SKIPPED_COUNT)
  Failed: $($script:FAILED_COUNT)
  Location: $($script:BACKUP_DIR)
  Log: $($script:LOG_FILE)
================================
"@
    Write-Host $summary
    Write-Log $summary

    if ($script:FAILED_COUNT -gt 0) {
        Write-ColorOutput "Some backups failed. Check log for details." "Warning"
    } else {
        Write-ColorOutput "All backups completed successfully!" "Success"
    }

    Start-ExternalBackup

    Write-Host ""
    Write-ColorOutput "ALL DONE" "Section"
    Write-ColorOutput "Backup saved to: $($script:BACKUP_DIR)" "Success"
    Write-ColorOutput "Log file: $($script:LOG_FILE)" "Info"

    if ($script:FAILED_COUNT -gt 0) {
        Write-Host ""
        Write-ColorOutput "To resume failed transfers, run the script again with:" "Info"
        Write-Host "  - Same backup folder name: $($script:BACKUP_NAME)"
        Write-Host "  - Same backup root: $($script:BACKUP_ROOT)"
    }
}

Main
