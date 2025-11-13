@echo off
REM ==================================================
REM Android Backup Script Launcher for Windows
REM Wrapper to easily run the PowerShell backup script
REM ==================================================

REM Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"

REM Check if PowerShell is available
where powershell >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo Error: PowerShell is not available on this system.
    echo Please install PowerShell or run the script manually.
    pause
    exit /b 1
)

echo ============================================================
echo   Android Backup Script for Windows
echo   Starting PowerShell script...
echo ============================================================
echo.

REM Run the PowerShell script with execution policy bypass
REM Pass any arguments from batch file to PowerShell script
if "%~1"=="" (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT_DIR%phone_backup.ps1"
) else (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%SCRIPT_DIR%phone_backup.ps1" -ConfigFile "%~1"
)

REM Capture the exit code
set BACKUP_EXIT_CODE=%ERRORLEVEL%

echo.
echo ============================================================
echo   Script execution completed with exit code: %BACKUP_EXIT_CODE%
echo ============================================================
echo.

REM Pause to keep window open if run by double-clicking
if "%~1"=="" (
    pause
)

exit /b %BACKUP_EXIT_CODE%
