@echo off
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
echo Building APE and SPE...
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

:: Ask if user wants to copy to parent directory
echo.
set /p "COPY_FILES=Copy binaries to parent Scripts directory? (Y/N): "
if /i "%COPY_FILES%"=="Y" (
    echo.
    echo Copying files...
    copy /Y target\release\ape.exe ..\ape.exe
    copy /Y target\release\spe.exe ..\spe.exe
    echo.
    echo Files copied to: %~dp0..\
    echo.
    echo You can now use 'ape' and 'spe' from anywhere (if Scripts is in PATH)
) else (
    echo.
    echo Binaries are located at: %~dp0target\release\
    echo.
    echo To install manually:
    echo   1. Copy target\release\ape.exe to a directory in your PATH
    echo   2. Copy target\release\spe.exe to a directory in your PATH
    echo.
    echo Or run this script again and choose 'Y' to copy automatically.
)

:: Ask if user wants to create hard links
echo.
set /p "CREATE_HARDLINKS=Create hard links in %%USERPROFILE%%\AppData\Local\Programs\scripts? (Y/N): "
if /i "%CREATE_HARDLINKS%"=="Y" (
    set "TARGET_DIR=%USERPROFILE%\AppData\Local\Programs\scripts"

    :: Check if target directory exists
    if not exist "!TARGET_DIR!" (
        echo.
        echo Creating directory: !TARGET_DIR!
        mkdir "!TARGET_DIR!" 2>nul
        if %errorlevel% neq 0 (
            echo Error: Failed to create directory.
            goto :skip_hardlinks
        )
    )

    echo.
    echo Creating hard links...
    echo.

    :: Delete existing links if they exist
    if exist "!TARGET_DIR!\ape.exe" del "!TARGET_DIR!\ape.exe" 2>nul
    if exist "!TARGET_DIR!\spe.exe" del "!TARGET_DIR!\spe.exe" 2>nul

    :: Create hard links (mklink /H doesn't require admin privileges)
    set "APE_SUCCESS=0"
    set "SPE_SUCCESS=0"

    mklink /H "!TARGET_DIR!\ape.exe" "%~dp0target\release\ape.exe" >nul 2>&1
    if %errorlevel% equ 0 (
        echo Created hard link: !TARGET_DIR!\ape.exe
        set "APE_SUCCESS=1"
    ) else (
        echo Error: Failed to create hard link for ape.exe
    )

    mklink /H "!TARGET_DIR!\spe.exe" "%~dp0target\release\spe.exe" >nul 2>&1
    if %errorlevel% equ 0 (
        echo Created hard link: !TARGET_DIR!\spe.exe
        set "SPE_SUCCESS=1"
    ) else (
        echo Error: Failed to create hard link for spe.exe
    )

    echo.
    if "!APE_SUCCESS!"=="1" if "!SPE_SUCCESS!"=="1" (
        echo Hard links created successfully in: !TARGET_DIR!
        echo Note: Hard links share the same file data. Rebuilding will update both.
    ) else (
        echo Warning: Some hard links may not have been created.
    )
    echo.
) else (
    echo.
    echo Skipping hard link creation.
)

:skip_hardlinks

echo.
echo ================================
echo Done!
echo ================================
echo.
pause
