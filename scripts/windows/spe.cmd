@echo off
set "_MARKER=%TEMP%\_venv_activate_path.txt"
if exist "%_MARKER%" del "%_MARKER%"
"%~dp0spe-core.exe" %*
if exist "%_MARKER%" (
    set /p "_VENV_PATH="<"%_MARKER%"
    del "%_MARKER%"
    call "%_VENV_PATH%\Scripts\activate.bat"
)
