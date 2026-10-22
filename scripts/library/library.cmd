@echo off
rem Launcher for library.ps1 - prefers PowerShell 7 (pwsh), falls back to Windows PowerShell 5.1.
rem ExecutionPolicy Bypass applies only to this one process; it does not change system settings.
where pwsh >nul 2>&1
if %errorlevel%==0 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0library.ps1" %*
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0library.ps1" %*
)
exit /b %errorlevel%
