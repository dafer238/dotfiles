@echo off
setlocal
rem Launcher for library.ps1 - prefers PowerShell 7 (pwsh), falls back to Windows PowerShell 5.1.
rem ExecutionPolicy Bypass applies only to this one process; it does not change system settings.
set "LIB_PS=powershell"
where pwsh >nul 2>&1 && set "LIB_PS=pwsh"
rem One parenthesised line: cmd reads batch files as it goes, and 'library uninstall' deletes this file.
(%LIB_PS% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0library.ps1" %* & call exit /b %%errorlevel%%)
