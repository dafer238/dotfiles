@echo off
setlocal enabledelayedexpansion
set "_MARKER=%TEMP%\_venv_activate_path.txt"
if exist "!_MARKER!" del "!_MARKER!"
"%~dp0spe-core.exe" %*
if not exist "!_MARKER!" goto :eof
set /p "_VENV_PATH="<"!_MARKER!"
del "!_MARKER!"
endlocal & call "%_VENV_PATH%\Scripts\activate.bat"
