@echo off
REM Windows Dotfiles Setup Script
REM This script creates symlinks (or copies if symlinks fail) for dotfiles in the user's profile.

SETLOCAL ENABLEDELAYEDEXPANSION

REM Get user profile path
SET USERPROFILE=%USERPROFILE%
REM Ensure DOTFILES_DIR ends with a backslash
SET DOTFILES_DIR=%~dp0configs

echo DEBUG: DOTFILES_DIR is "%DOTFILES_DIR%"
dir "%DOTFILES_DIR%"

REM Ensure DOTFILES_DIR exists
IF NOT EXIST "%DOTFILES_DIR%" (
    echo ERROR: Dotfiles directory "%DOTFILES_DIR%" does not exist.
    goto end
)

REM Ensure .config directory exists
IF NOT EXIST "%USERPROFILE%\.config" (
    mkdir "%USERPROFILE%\.config"
)

REM Skip over function definitions
GOTO :main

REM Function to copy files with prompt if destination exists
REM Usage: call :copy_file_with_prompt "source" "destination"
:copy_file_with_prompt
IF "%~1"=="" (
    echo ERROR: Source path is empty, skipping.
    GOTO :EOF
)
IF NOT EXIST "%~1" (
    echo ERROR: Source "%~1" does not exist.
    GOTO :EOF
)
IF EXIST "%~2" (
    set /p OVERWRITE=Destination "%~2" exists. Overwrite? (Y/n)
    IF /I "!OVERWRITE!"=="n" (
        echo Skipped "%~2"
        GOTO :EOF
    )
)
copy /Y "%~1" "%~2" >nul 2>&1
IF %ERRORLEVEL% EQU 0 (
    echo Copied %~2 from %~1
) ELSE (
    echo ERROR: Failed to copy %~1 to %~2
)
GOTO :EOF

REM Function to create directory symlink with prompt if destination exists
REM Usage: call :symlink_dir_with_prompt "source_dir" "destination_dir"
:symlink_dir_with_prompt
IF "%~1"=="" (
    echo ERROR: Source directory path is empty, skipping.
    GOTO :EOF
)
IF NOT EXIST "%~1" (
    echo ERROR: Source directory "%~1" does not exist.
    GOTO :EOF
)
IF EXIST "%~2" (
    set /p OVERWRITE=Destination directory "%~2" exists. Overwrite? (Y/n)
    IF /I "!OVERWRITE!"=="n" (
        echo Skipped "%~2"
        GOTO :EOF
    )
    rmdir /S /Q "%~2"
)
mklink /J "%~2" "%~1" 2>nul
IF %ERRORLEVEL% EQU 0 (
    echo Created junction %~2 to %~1
) ELSE (
    echo ERROR: Failed to create junction %~2 to %~1
)
GOTO :EOF

REM ========== MAIN SCRIPT ==========
:main

REM .zshrc (for WSL or compatible shells)
echo DEBUG: Checking existence of "%DOTFILES_DIR%\.zshrc"
IF EXIST "%DOTFILES_DIR%\.zshrc" (
    echo DEBUG: About to copy "%DOTFILES_DIR%\.zshrc" to "%USERPROFILE%\.zshrc"
    call :copy_file_with_prompt "%DOTFILES_DIR%\.zshrc" "%USERPROFILE%\.zshrc"
) ELSE (
    echo DEBUG: "%DOTFILES_DIR%\.zshrc" does not exist
)

REM .tmux.conf (for WSL or compatible shells)
echo DEBUG: Checking existence of "%DOTFILES_DIR%\.tmux.conf"
IF EXIST "%DOTFILES_DIR%\.tmux.conf" (
    echo DEBUG: About to copy "%DOTFILES_DIR%\.tmux.conf" to "%USERPROFILE%\.tmux.conf"
    call :copy_file_with_prompt "%DOTFILES_DIR%\.tmux.conf" "%USERPROFILE%\.tmux.conf"
) ELSE (
    echo DEBUG: "%DOTFILES_DIR%\.tmux.conf" does not exist
)

REM starship.toml
echo DEBUG: Checking existence of "%DOTFILES_DIR%\starship.toml"
IF EXIST "%DOTFILES_DIR%\starship.toml" (
    echo DEBUG: About to copy "%DOTFILES_DIR%\starship.toml" to "%USERPROFILE%\.config\starship.toml"
    call :copy_file_with_prompt "%DOTFILES_DIR%\starship.toml" "%USERPROFILE%\.config\starship.toml"
) ELSE (
    echo DEBUG: "%DOTFILES_DIR%\starship.toml" does not exist
)
REM zed config - copy files to AppData\Roaming\Zed
echo DEBUG: Checking existence of "%DOTFILES_DIR%\zed"
IF EXIST "%DOTFILES_DIR%\zed" (
    IF EXIST "%USERPROFILE%\AppData\Roaming\Zed" (
        set /p OVERWRITE=Destination directory "%USERPROFILE%\AppData\Roaming\Zed" exists. Overwrite? (Y/n)
        IF /I "!OVERWRITE!"=="n" (
            echo Skipped Zed config
            GOTO :skip_zed
        )
        echo DEBUG: Removing existing Zed directory
        rmdir /S /Q "%USERPROFILE%\AppData\Roaming\Zed"
    )
    echo DEBUG: Creating Zed directory
    mkdir "%USERPROFILE%\AppData\Roaming\Zed"
    echo DEBUG: Copying Zed config files to "%USERPROFILE%\AppData\Roaming\Zed"
    REM Copy only regular files, exclude symlinks and broken links
    FOR %%F IN ("%DOTFILES_DIR%\zed\*.*") DO (
        IF EXIST "%%F" (
            copy /Y "%%F" "%USERPROFILE%\AppData\Roaming\Zed\" >nul 2>&1
            IF !ERRORLEVEL! EQU 0 (
                echo Copied %%~nxF
            )
        )
    )
    echo Copied Zed config files to %USERPROFILE%\AppData\Roaming\Zed
    :skip_zed
) ELSE (
    echo DEBUG: "%DOTFILES_DIR%\zed" does not exist
)

REM nvim config
echo DEBUG: Checking existence of "%DOTFILES_DIR%\nvim"
IF EXIST "%DOTFILES_DIR%\nvim" (
    IF NOT EXIST "%USERPROFILE%\AppData\Local" (
        mkdir "%USERPROFILE%\AppData\Local"
    )
    echo DEBUG: About to create junction "%DOTFILES_DIR%\nvim" to "%USERPROFILE%\AppData\Local\nvim"
    call :symlink_dir_with_prompt "%DOTFILES_DIR%\nvim" "%USERPROFILE%\AppData\Local\nvim"
) ELSE (
    echo DEBUG: "%DOTFILES_DIR%\nvim" does not exist
)

REM ghostty config (handle as file or directory)
echo DEBUG: Checking existence of "%DOTFILES_DIR%\ghostty"
IF EXIST "%DOTFILES_DIR%\ghostty" (
    echo DEBUG: About to create junction "%DOTFILES_DIR%\ghostty" to "%USERPROFILE%\.config\ghostty"
    call :symlink_dir_with_prompt "%DOTFILES_DIR%\ghostty" "%USERPROFILE%\.config\ghostty"
) ELSE (
    echo DEBUG: "%DOTFILES_DIR%\ghostty" does not exist
    echo DEBUG: Checking existence of "%DOTFILES_DIR%\config"
    IF EXIST "%DOTFILES_DIR%\config" (
        IF NOT EXIST "%USERPROFILE%\.config\ghostty" (
            mkdir "%USERPROFILE%\.config\ghostty"
        )
        echo DEBUG: About to copy "%DOTFILES_DIR%\config" to "%USERPROFILE%\.config\ghostty\config"
        call :copy_file_with_prompt "%DOTFILES_DIR%\config" "%USERPROFILE%\.config\ghostty\config"
    ) ELSE (
        echo DEBUG: "%DOTFILES_DIR%\config" does not exist
    )
)

echo Dotfiles setup complete!
:end
ENDLOCAL
pause
