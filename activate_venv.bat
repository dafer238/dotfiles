@echo off
setlocal enabledelayedexpansion

:: Get the directory where the batch file is located
set "venv_folder=%~dp0"

:: Initialize variables
set /a index=0

:: List all subdirectories and assume each is a venv if it contains Scripts\activate.bat
echo Available virtual environments:
echo.
for /d %%D in ("%venv_folder%*") do (
    if exist "%%D\Scripts\activate.bat" (
        set /a index+=1
        set "venv!index!=%%~nxD"
        echo   !index!. %%~nxD
    )
)
echo.

:: If no venvs found
if %index%==0 (
    echo No virtual environments with activation scripts found in "%venv_folder%".
    goto :eof
)

:ask_venv_name
:: Prompt for selection
set /p venv_input="Enter the number or name of the virtual environment to activate: "

:: Check if input is a number between 1 and index
set "venv_name="
for /l %%N in (1,1,%index%) do (
    if "!venv_input!"=="%%N" set "venv_name=!venv%%N!"
)

:: If not a number, assume it is a name
if not defined venv_name (
    set "venv_name=%venv_input%"
)

:: Construct the full path to the virtual environment activation script
set "venv_path=%venv_folder%%venv_name%\Scripts\activate.bat"

:: Check if the activation script exists
if exist "%venv_path%" (
    call "%venv_path%"
    cmd
) else (
    echo Virtual environment "%venv_name%" not found in "%venv_folder%."
    echo.
    goto ask_venv_name
)

endlocal
