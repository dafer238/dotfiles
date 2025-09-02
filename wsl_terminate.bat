@echo off
:menu
cls
echo Listing all WSL distros with status:
echo.
wsl -l -v
echo.

set /p input=Enter distro name to terminate, Enter to terminate all, or q to quit: 

if /i "%input%"=="q" goto end

if "%input%"=="" (
    echo Shutting down all WSL distros...
    wsl --shutdown
    echo All WSL distros terminated.
    pause
    goto end
)

echo Terminating distro: %input%
wsl --terminate %input%
echo Done.
pause
goto end

:end
