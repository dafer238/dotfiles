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

echo.
echo ================================
echo Done!
echo ================================
echo.
pause
