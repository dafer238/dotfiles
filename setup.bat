@echo off
REM Windows Dotfiles Setup Script
REM This script creates symlinks (or copies if symlinks fail) for dotfiles in the user's profile.

SETLOCAL ENABLEDELAYEDEXPANSION

REM Get user profile path
SET USERPROFILE=%USERPROFILE%
SET DOTFILES_DIR=%~dp0configs

REM Function to create symlink or fallback to copy
REM Usage: call :link_or_copy "source" "destination"
:link_or_copy
REM Try to create symlink
mklink /H "%~2" "%~1" 2>nul
IF %ERRORLEVEL% EQU 0 (
    echo Linked %~2 to %~1
    GOTO :EOF
)
REM If symlink fails, fallback to copy
copy /Y "%~1" "%~2"
echo Copied %~1 to %~2
GOTO :EOF

REM .zshrc (for WSL or compatible shells)
IF EXIST "%DOTFILES_DIR%\.zshrc" (
    call :link_or_copy "%DOTFILES_DIR%\.zshrc" "%USERPROFILE%\.zshrc"
)

REM .tmux.conf (for WSL or compatible shells)
IF EXIST "%DOTFILES_DIR%\.tmux.conf" (
    call :link_or_copy "%DOTFILES_DIR%\.tmux.conf" "%USERPROFILE%\.tmux.conf"
)

REM starship.toml
IF EXIST "%DOTFILES_DIR%\starship.toml" (
    IF NOT EXIST "%USERPROFILE%\.config" (
        mkdir "%USERPROFILE%\.config"
    )
    IF NOT EXIST "%USERPROFILE%\.config\starship.toml" (
        call :link_or_copy "%DOTFILES_DIR%\starship.toml" "%USERPROFILE%\.config\starship.toml"
    )
)

REM nvim config
IF EXIST "%DOTFILES_DIR%\nvim" (
    IF NOT EXIST "%USERPROFILE%\.config" (
        mkdir "%USERPROFILE%\.config"
    )
    REM Symlink the nvim folder (requires admin for directory symlinks, fallback to copy)
    mklink /D "%USERPROFILE%\.config\nvim" "%DOTFILES_DIR%\nvim" 2>nul
    IF %ERRORLEVEL% NEQ 0 (
        xcopy "%DOTFILES_DIR%\nvim" "%USERPROFILE%\.config\nvim" /E /I /Y
        echo Copied nvim config to %USERPROFILE%\.config\nvim
    ) ELSE (
        echo Linked nvim config to %USERPROFILE%\.config\nvim
    )
)

REM zed config
IF EXIST "%DOTFILES_DIR%\zed" (
    IF NOT EXIST "%USERPROFILE%\.config" (
        mkdir "%USERPROFILE%\.config"
    )
    mklink /D "%USERPROFILE%\.config\zed" "%DOTFILES_DIR%\zed" 2>nul
    IF %ERRORLEVEL% NEQ 0 (
        xcopy "%DOTFILES_DIR%\zed" "%USERPROFILE%\.config\zed" /E /I /Y
        echo Copied zed config to %USERPROFILE%\.config\zed
    ) ELSE (
        echo Linked zed config to %USERPROFILE%\.config\zed
    )
)

REM ghostty config
IF EXIST "%DOTFILES_DIR%\config" (
    IF NOT EXIST "%USERPROFILE%\.config" (
        mkdir "%USERPROFILE%\.config"
    )
    call :link_or_copy "%DOTFILES_DIR%\config" "%USERPROFILE%\.config\ghostty\config"
)

echo Dotfiles setup complete!
ENDLOCAL
pause
