@echo off
setlocal enabledelayedexpansion
echo ================================
echo Building Rust Versions of APE and SPE
echo ================================
echo.

:: Check if Rust is installed
where cargo >nul 2>nul
if %errorlevel% neq 0 (
    echo Error: Cargo not found. Please install Rust from https://rustup.rs/
    echo.
    pause
    exit /b 1
)

echo Rust version:
rustc --version
echo.
echo Cargo version:
cargo --version
echo.

:: Build both programs
echo Building APE-CORE and SPE-CORE...
echo.
cargo build --release
if %errorlevel% neq 0 (
    echo.
    echo Error: Failed to build
    pause
    exit /b 1
)
echo.
echo Build successful!
echo.

:: Show file sizes
echo ================================
echo Build Complete!
echo ================================
echo.
echo Compiled binaries:
echo.
dir /b target\release\*.exe 2>nul
echo.
echo Shell wrappers:
echo   ape.cmd, spe.cmd (CMD)
echo   Invoke-PythonVenv.ps1 (PowerShell)
echo.

:: -------------------------------------------------------
:: Install to target directory
:: -------------------------------------------------------
set "TARGET_DIR=%USERPROFILE%\AppData\Local\Programs\scripts"

echo.
set /p "DO_INSTALL=Install to %TARGET_DIR%? (Y/N): "
if /i not "%DO_INSTALL%"=="Y" (
    echo.
    echo Skipping install. Binaries are at: %~dp0target\release\
    echo.
    pause
    exit /b 0
)

:: Create target directory if needed
if not exist "!TARGET_DIR!" (
    echo.
    echo Creating directory: !TARGET_DIR!
    mkdir "!TARGET_DIR!" 2>nul
    if %errorlevel% neq 0 (
        echo Error: Failed to create directory.
        pause
        exit /b 1
    )
)

echo.
echo Installing files to: !TARGET_DIR!
echo.

:: Clean up old files (both old and new naming)
for %%F in (ape-core.exe spe-core.exe ape.exe spe.exe ape.cmd spe.cmd Invoke-PythonVenv.ps1) do (
    if exist "!TARGET_DIR!\%%F" del "!TARGET_DIR!\%%F" 2>nul
)

:: Create hard links for core binaries
set "LINK_OK=1"
mklink /H "!TARGET_DIR!\ape-core.exe" "%~dp0target\release\ape-core.exe" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [OK] ape-core.exe (hard link)
) else (
    echo   [FALLBACK] Copying ape-core.exe...
    copy /Y "%~dp0target\release\ape-core.exe" "!TARGET_DIR!\ape-core.exe" >nul
)

mklink /H "!TARGET_DIR!\spe-core.exe" "%~dp0target\release\spe-core.exe" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [OK] spe-core.exe (hard link)
) else (
    echo   [FALLBACK] Copying spe-core.exe...
    copy /Y "%~dp0target\release\spe-core.exe" "!TARGET_DIR!\spe-core.exe" >nul
)

:: Copy wrapper scripts
copy /Y "%~dp0ape.cmd" "!TARGET_DIR!\ape.cmd" >nul 2>&1
echo   [OK] ape.cmd
copy /Y "%~dp0spe.cmd" "!TARGET_DIR!\spe.cmd" >nul 2>&1
echo   [OK] spe.cmd
copy /Y "%~dp0Invoke-PythonVenv.ps1" "!TARGET_DIR!\Invoke-PythonVenv.ps1" >nul 2>&1
echo   [OK] Invoke-PythonVenv.ps1
echo.

:: -------------------------------------------------------
:: Add to user PATH (if not already there)
:: -------------------------------------------------------
echo Checking PATH...
call :AddToPath "!TARGET_DIR!"
echo.

:: -------------------------------------------------------
:: Setup PowerShell profiles automatically
:: Query PowerShell itself for the actual $PROFILE path
:: (handles OneDrive redirection, localized folder names, etc.)
:: -------------------------------------------------------
echo Setting up PowerShell profiles...
set "DOT_SOURCE_LINE=. "!TARGET_DIR!\Invoke-PythonVenv.ps1""

:: PowerShell 7+ (pwsh) — ask pwsh for its $PROFILE
set "PS7_PROFILE="
where pwsh >nul 2>nul
if !errorlevel! equ 0 (
    for /f "delims=" %%P in ('pwsh -NoProfile -NoLogo -Command "$PROFILE" 2^>nul') do set "PS7_PROFILE=%%P"
)
if defined PS7_PROFILE (
    for %%F in ("!PS7_PROFILE!") do set "PS7_DIR=%%~dpF"
    call :SetupProfile "!PS7_PROFILE!" "!PS7_DIR!" "PowerShell 7"
) else (
    echo   [SKIP] pwsh not found, skipping PowerShell 7 profile
)

:: Windows PowerShell 5.1 — ask powershell for its $PROFILE
set "PS5_PROFILE="
where powershell >nul 2>nul
if !errorlevel! equ 0 (
    for /f "delims=" %%P in ('powershell -NoProfile -NoLogo -Command "$PROFILE" 2^>nul') do set "PS5_PROFILE=%%P"
)
if defined PS5_PROFILE (
    for %%F in ("!PS5_PROFILE!") do set "PS5_DIR=%%~dpF"
    call :SetupProfile "!PS5_PROFILE!" "!PS5_DIR!" "Windows PowerShell 5.1"
) else (
    echo   [SKIP] powershell not found, skipping Windows PowerShell 5.1 profile
)

echo.
echo ================================
echo Installation Complete!
echo ================================
echo.
echo Installed to: !TARGET_DIR!
echo.
echo What was set up:
echo   - Core binaries: ape-core.exe, spe-core.exe
echo   - CMD wrappers: ape.cmd, spe.cmd (work in cmd.exe)
echo   - PowerShell wrapper: Invoke-PythonVenv.ps1
echo   - User PATH: updated
echo   - PowerShell profiles: updated (both pwsh 7 and 5.1)
echo.
echo Open a NEW terminal and type 'ape' or 'spe' to get started.
echo.
pause
exit /b 0

:: -------------------------------------------------------
:: SUBROUTINES
:: -------------------------------------------------------

:AddToPath
:: Adds a directory to the user PATH via registry if not already present.
:: Usage: call :AddToPath "C:\some\path"
set "_NEW_PATH=%~1"
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "_CUR_PATH=%%B"
if not defined _CUR_PATH (
    reg add "HKCU\Environment" /v PATH /t REG_EXPAND_SZ /d "!_NEW_PATH!" /f >nul 2>&1
    echo   [OK] Created PATH with: !_NEW_PATH!
    goto :eof
)
echo !_CUR_PATH! | findstr /i /c:"!_NEW_PATH!" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [OK] Already in PATH: !_NEW_PATH!
) else (
    reg add "HKCU\Environment" /v PATH /t REG_EXPAND_SZ /d "!_CUR_PATH!;!_NEW_PATH!" /f >nul 2>&1
    echo   [OK] Added to PATH: !_NEW_PATH!
)
goto :eof

:SetupProfile
:: Adds the dot-source line to a PowerShell profile.
:: Usage: call :SetupProfile "profile_path" "profile_dir" "label"
set "_PROF_PATH=%~1"
set "_PROF_DIR=%~2"
set "_PROF_LABEL=%~3"
set "_MARKER=# [PythonVenvTools]"

:: Create directory if needed
if not exist "!_PROF_DIR!" (
    mkdir "!_PROF_DIR!" 2>nul
)

:: Check if profile exists and already has our line
if exist "!_PROF_PATH!" (
    findstr /c:"Invoke-PythonVenv.ps1" "!_PROF_PATH!" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK] !_PROF_LABEL! profile already configured
        goto :eof
    )
    :: Append our lines
    echo.>> "!_PROF_PATH!"
    echo !_MARKER!>> "!_PROF_PATH!"
    echo !DOT_SOURCE_LINE!>> "!_PROF_PATH!"
    echo   [OK] Updated !_PROF_LABEL! profile
) else (
    :: Create new profile
    echo !_MARKER!> "!_PROF_PATH!"
    echo !DOT_SOURCE_LINE!>> "!_PROF_PATH!"
    echo   [OK] Created !_PROF_LABEL! profile
)
goto :eof
