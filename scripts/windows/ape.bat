@echo off
setlocal EnableDelayedExpansion

:: ---------------------------------------------------------------------
:: CACHE CONFIGURATION
:: ---------------------------------------------------------------------
set "CACHE_FILE=%TEMP%\python_venv_cache.txt"

:: ---------------------------------------------------------------------
:: CHECK FOR HELP FLAG
:: ---------------------------------------------------------------------
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="--help" goto :show_help
if /i "%~1"=="/?" goto :show_help

:: ---------------------------------------------------------------------
:: CHECK FOR CLEAN FLAG
:: ---------------------------------------------------------------------
if /i "%~1"=="-c" goto :clean_cache
if /i "%~1"=="--clean" goto :clean_cache
if /i "%~2"=="-c" goto :clean_cache
if /i "%~2"=="--clean" goto :clean_cache
if /i "%~3"=="-c" goto :clean_cache
if /i "%~3"=="--clean" goto :clean_cache

:: ---------------------------------------------------------------------
:: CHECK FOR UNKNOWN FLAGS (exit immediately if found)
:: ---------------------------------------------------------------------
set "UNKNOWN_FLAG_ERROR="
if not "%~1"=="" call :check_flag "%~1"
if not "%~2"=="" if not defined UNKNOWN_FLAG_ERROR call :check_flag "%~2"
if not "%~3"=="" if not defined UNKNOWN_FLAG_ERROR call :check_flag "%~3"

if defined UNKNOWN_FLAG_ERROR (
    echo.
    echo Warning: Unknown flag "!UNKNOWN_FLAG_ERROR!"
    echo Run 'ape --help' for usage information.
    echo.
    goto :eof
)

:: ---------------------------------------------------------------------
:: CHECK FOR SCAN FLAG
:: ---------------------------------------------------------------------
set "SCAN_MODE=0"
set "CLEAN_MODE=0"
if /i "%~1"=="--scan" set "SCAN_MODE=1"
if /i "%~1"=="-s" set "SCAN_MODE=1"
if /i "%~2"=="--scan" set "SCAN_MODE=1"
if /i "%~2"=="-s" set "SCAN_MODE=1"
if /i "%~3"=="--scan" set "SCAN_MODE=1"
if /i "%~3"=="-s" set "SCAN_MODE=1"
if /i "%~1"=="-c" set "CLEAN_MODE=1"
if /i "%~1"=="--clean" set "CLEAN_MODE=1"
if /i "%~2"=="-c" set "CLEAN_MODE=1"
if /i "%~2"=="--clean" set "CLEAN_MODE=1"
if /i "%~3"=="-c" set "CLEAN_MODE=1"
if /i "%~3"=="--clean" set "CLEAN_MODE=1"

:: ---------------------------------------------------------------------
:: CHECK FOR VERBOSE FLAG
:: ---------------------------------------------------------------------
set "VERBOSE=0"
set "ENV_ARG="
if /i "%~1"=="-v" (
    set "VERBOSE=1"
    if /i "%~2"=="--scan" set "ENV_ARG=%~3"
    if /i "%~2"=="-s" set "ENV_ARG=%~3"
    if /i not "%~2"=="--scan" if /i not "%~2"=="-s" set "ENV_ARG=%~2"
)
if /i "%~1"=="--verbose" (
    set "VERBOSE=1"
    if /i "%~2"=="--scan" set "ENV_ARG=%~3"
    if /i "%~2"=="-s" set "ENV_ARG=%~3"
    if /i not "%~2"=="--scan" if /i not "%~2"=="-s" set "ENV_ARG=%~2"
)
if /i "%~1"=="--scan" (
    if /i "%~2"=="-v" (
        set "VERBOSE=1"
        set "ENV_ARG=%~3"
    )
    if /i "%~2"=="--verbose" (
        set "VERBOSE=1"
        set "ENV_ARG=%~3"
    )
    if not "%VERBOSE%"=="1" (
        set "ENV_ARG=%~2"
    )
)
if /i "%~1"=="-s" (
    if /i "%~2"=="-v" (
        set "VERBOSE=1"
        set "ENV_ARG=%~3"
    )
    if /i "%~2"=="--verbose" (
        set "VERBOSE=1"
        set "ENV_ARG=%~3"
    )
    if not "%VERBOSE%"=="1" (
        set "ENV_ARG=%~2"
    )
)
if not "%VERBOSE%"=="1" if not "%SCAN_MODE%"=="1" set "ENV_ARG=%~1"

:: ---------------------------------------------------------------------
:: CONFIGURATION - Directories to search for environments
:: ---------------------------------------------------------------------
set "dirs[1]=%USERPROFILE%"
set "dirs[2]=%USERPROFILE%\.venv"
set "dirs[3]=%USERPROFILE%\venv"
set "dirs[4]=%USERPROFILE%\.venvs"
set "dirs[5]=%USERPROFILE%\venvs"
set "dirs[6]=%USERPROFILE%\code"
set "dirs[7]=%USERPROFILE%\code\.venv"
set "dirs[8]=%USERPROFILE%\code\venv"
set "dirs[9]=%USERPROFILE%\code\.venvs"
set "dirs[10]=%USERPROFILE%\code\venvs"
set "dirs[11]=%USERPROFILE%\code\python"
set "dirs[12]=%USERPROFILE%\code\python\.venv"
set "dirs[13]=%USERPROFILE%\code\python\venv"
set "dirs[14]=%USERPROFILE%\code\python\.venvs"
set "dirs[15]=%USERPROFILE%\code\python\venvs"
set "dirs[16]=%USERPROFILE%\AppData\Local\Programs"
set "dirs[17]=%USERPROFILE%\AppData\Local\Programs\.venv"
set "dirs[18]=%USERPROFILE%\AppData\Local\Programs\venv"
set "dirs[19]=%USERPROFILE%\AppData\Local\Programs\.venvs"
set "dirs[20]=%USERPROFILE%\AppData\Local\Programs\venvs"
set "dirs[21]=%USERPROFILE%\AppData\Local\Programs\Python"
set "dirs[22]=%USERPROFILE%\AppData\Local\Programs\Python\.venv"
set "dirs[23]=%USERPROFILE%\AppData\Local\Programs\Python\venv"
set "dirs[24]=%USERPROFILE%\AppData\Local\Programs\Python\.venvs"
set "dirs[25]=%USERPROFILE%\AppData\Local\Programs\Python\venvs"

if %VERBOSE%==1 (
    echo [DEBUG] Verbose mode enabled.
    echo [DEBUG] Directories to be scanned:
    for /l %%i in (1,1,25) do echo   !dirs[%%i]!
    echo.
)

:: ---------------------------------------------------------------------
:: HANDLE SCAN MODE
:: ---------------------------------------------------------------------
if %SCAN_MODE%==1 (
    echo Performing comprehensive scan...
    echo This may take a moment...
    echo.
    call :scan_all_venvs
    echo Found !cache_index! environments.
    call :save_cache
    echo Cache updated.
    echo.
    if "%ENV_ARG%"=="" (
        if !cache_index! GTR 0 (
            echo.
            echo Found environments:
            echo.
            call :print_scan_results
            echo.
        )
        echo Run 'ape ^<env_name^>' to activate an environment.
        goto :eof
    )
)

:: ---------------------------------------------------------------------
:: CHECK IF ENVIRONMENT NAME PROVIDED
:: ---------------------------------------------------------------------
if "%ENV_ARG%"=="" (
    echo Error: No environment name specified.
    echo.
    echo Usage: ape [OPTIONS] ^<env_name^>
    echo        ape --help for more information
    goto :eof
)

:: ---------------------------------------------------------------------
:: SEARCH FOR THE SPECIFIED ENVIRONMENT
:: ---------------------------------------------------------------------
set "found_path="
set "found_type="
set /a cache_index=0

if %VERBOSE%==1 (
    echo [DEBUG] Searching for environment: %ENV_ARG%
    echo.
)

:: Try cache first
if exist "%CACHE_FILE%" (
    if %VERBOSE%==1 echo [DEBUG] Checking cache...
    for /f "usebackq tokens=1,2,3 delims=|" %%A in ("%CACHE_FILE%") do (
        if /i "%%A"=="%ENV_ARG%" (
            set "found_path=%%C"
            set "found_type=%%B"
            if %VERBOSE%==1 echo [DEBUG] Found in cache: %%A ^(%%B^) at %%C
            if exist "!found_path!\Scripts\activate.bat" (
                goto :activate_env
            ) else (
                if %VERBOSE%==1 echo [DEBUG] Cached path no longer valid, searching directories...
                set "found_path="
                set "found_type="
            )
        )
    )
)

:: If not in cache or cache invalid, search directories
if %VERBOSE%==1 if not defined found_path echo [DEBUG] Searching predefined directories...

for /l %%i in (1,1,25) do (
    set "current_dir=!dirs[%%i]!"
    if exist "!current_dir!" (
        if %VERBOSE%==1 echo [DEBUG] Checking "!current_dir!"

        rem Check if the environment exists in this directory
        set "env_dir=!current_dir!\%ENV_ARG%"
        if exist "!env_dir!" (
            set "env_type="

            rem Detect type (venv, conda, uv)
            if exist "!env_dir!\conda-meta" set "env_type=conda"
            if not defined env_type if exist "!env_dir!\pyvenv.cfg" (
                findstr /C:"uv" "!env_dir!\pyvenv.cfg" >nul 2>&1
                if !errorlevel!==0 set "env_type=uv"
            )
            if not defined env_type if exist "!env_dir!\Scripts\activate.bat" set "env_type=venv"

            rem If valid environment found, store it
            if defined env_type (
                set "found_path=!env_dir!"
                set "found_type=!env_type!"
                if %VERBOSE%==1 echo [DEBUG] Found !env_type! environment at: !env_dir!
                goto :activate_env
            )
        )
    )
    if not exist "!current_dir!" (
        if %VERBOSE%==1 echo [DEBUG] Directory not found: "!current_dir!"
    )
)

:: ---------------------------------------------------------------------
:: ENVIRONMENT NOT FOUND
:: ---------------------------------------------------------------------
echo Error: Environment "%ENV_ARG%" not found.
echo.
if exist "%CACHE_FILE%" (
    echo Tip: Try running 'ape --scan' to update the cache and find new environments.
) else (
    echo Tip: Try running 'ape --scan' to perform a comprehensive search.
)
echo      Or use 'spe' to see all available environments.
goto :eof

:: ---------------------------------------------------------------------
:: ACTIVATE ENVIRONMENT
:: ---------------------------------------------------------------------
:activate_env
if not defined found_path goto :eof

set "activate_script=%found_path%\Scripts\activate.bat"

if not exist "%activate_script%" (
    echo Error: Activation script not found at "%activate_script%"
    goto :eof
)

if %VERBOSE%==1 (
    echo [DEBUG] Activating: %found_path%
    echo [DEBUG] Type: %found_type%
    echo [DEBUG] Activation script: %activate_script%
    echo.
)

echo Activating "%ENV_ARG%" (%found_type%)...
echo.
echo [%ENV_ARG% activated - Type 'deactivate' or 'exit' to exit or close the window]
echo.

REM Keep the shell open with the environment activated
cmd /k ""%activate_script%""

goto :eof

:: ---------------------------------------------------------------------
:: SCAN AND CACHE FUNCTIONS
:: ---------------------------------------------------------------------

:scan_all_venvs
set /a cache_index=0
set /a scan_count=0
if %VERBOSE%==1 (
    echo [DEBUG] Scanning for pyvenv.cfg files in user directory...
) else (
    echo Scanning...
)

rem Search for pyvenv.cfg files in user directory, excluding temp and cache folders
for /f "delims=" %%F in ('dir /s /b "%USERPROFILE%\pyvenv.cfg" 2^>nul') do (
    set /a scan_count+=1
    if %VERBOSE%==1 (
        echo [DEBUG] Checking: %%F
    ) else (
        set /a progress=!scan_count! %% 3
        if !progress!==0 echo Scanning... [!scan_count! files checked]
    )
    set "cfg_file=%%F"
    set "skip_this=0"

    rem Check if path contains excluded directories
    echo %%F | findstr /i /c:"\Temp\" /c:"\Cache\" /c:"\tmp\" /c:"node_modules" >nul
    if not errorlevel 1 set "skip_this=1"

    if "!skip_this!"=="0" (
        set "env_dir=%%~dpF"
        set "env_dir=!env_dir:~0,-1!"

        rem Get environment name from path
        for %%D in ("!env_dir!") do set "env_name=%%~nxD"

        set "env_type="

        rem Detect type
        if exist "!env_dir!\conda-meta" set "env_type=conda"
        if not defined env_type (
            findstr /C:"uv" "%%F" >nul 2>&1
            if !errorlevel!==0 set "env_type=uv"
        )
        if not defined env_type if exist "!env_dir!\Scripts\activate.bat" set "env_type=venv"

        if defined env_type (
            set /a cache_index+=1
            set "cache_name[!cache_index!]=!env_name!"
            set "cache_type[!cache_index!]=!env_type!"
            set "cache_path[!cache_index!]=!env_dir!"
            if %VERBOSE%==1 echo [DEBUG] Found: !env_name! ^(!env_type!^) at !env_dir!
        )
    )
)
if %VERBOSE%==1 (
    echo [DEBUG] Scan complete. Found !cache_index! environments.
) else (
    echo Scan complete. Checked !scan_count! files.
)
goto :eof

:: ---------------------------------------------------------------------
:: CLEAN CACHE FUNCTION
:: ---------------------------------------------------------------------
:clean_cache
echo Removing cache file...
if exist "%CACHE_FILE%" (
    del "%CACHE_FILE%" 2>nul
    if exist "%CACHE_FILE%" (
        echo Error: Failed to remove cache file at %CACHE_FILE%
    ) else (
        echo Cache file removed successfully: %CACHE_FILE%
    )
) else (
    echo Cache file does not exist: %CACHE_FILE%
)
echo.
goto :eof

:save_cache
if %VERBOSE%==1 echo [DEBUG] Saving cache to %CACHE_FILE%
if %VERBOSE%==1 echo [DEBUG] Number of environments to save: %cache_index%
if exist "%CACHE_FILE%" del "%CACHE_FILE%" 2>nul
if %cache_index% GTR 0 (
    for /l %%i in (1,1,%cache_index%) do (
        echo !cache_name[%%i]!^|!cache_type[%%i]!^|!cache_path[%%i]!>> "%CACHE_FILE%"
        if %VERBOSE%==1 echo [DEBUG] Saved: !cache_name[%%i]! ^| !cache_type[%%i]! ^| !cache_path[%%i]!
    )
) else (
    if %VERBOSE%==1 echo [DEBUG] No environments to save
)
goto :eof

:: ---------------------------------------------------------------------
:: HELP FUNCTION
:: ---------------------------------------------------------------------
:show_help
echo.
echo APE - Activate Python Environment
echo ==================================
echo.
echo DESCRIPTION:
echo   Quickly activate a Python virtual environment by name.
echo   Searches predefined directories for the specified environment.
echo.
echo USAGE:
echo   ape [OPTIONS] ^<env_name^>
echo   ape --scan [OPTIONS]
echo.
echo ARGUMENTS:
echo   env_name         Name of the environment to activate
echo.
echo OPTIONS:
echo   -h, --help       Show this help message and exit
echo   -v, --verbose    Enable verbose output (shows debug information)
echo   -s, --scan       Perform comprehensive scan and update cache
echo   -c, --clean      Remove the cache file and exit
echo.
echo BEHAVIOR:
echo   Searches for the specified environment using cached results (if available),
echo   or searches predefined directories. With --scan, performs a comprehensive
echo   search of your entire user folder and updates the persistent cache.
echo.
echo   Opens a new command prompt with the environment activated. The environment
echo   stays active until you close the window or type 'deactivate' or 'exit'.
echo.
echo SEARCHED DIRECTORIES:
echo   - %%USERPROFILE%%
echo   - %%USERPROFILE%%\.venv, \venv, \.venvs, \venvs
echo   - %%USERPROFILE%%\code (and its .venv, venv, .venvs, venvs subdirs)
echo   - %%USERPROFILE%%\code\python (and its .venv, venv, .venvs, venvs subdirs)
echo   - %%USERPROFILE%%\AppData\Local\Programs (and its .venv, venv, .venvs, venvs subdirs)
echo   - %%USERPROFILE%%\AppData\Local\Programs\Python (and its .venv, venv, .venvs, venvs subdirs)
echo.
echo SUPPORTED ENVIRONMENT TYPES:
echo   - venv   : Standard Python virtual environments
echo   - conda  : Anaconda/Miniconda environments
echo   - uv     : UV-created virtual environments
echo.
echo EXAMPLES:
echo   ape myenv              Activate environment named 'myenv'
echo   ape -s                 Scan entire user folder and update cache
echo   ape --scan             Scan entire user folder and update cache (same as -s)
echo   ape -s myenv           Scan and then activate 'myenv'
echo   ape -v finance         Activate 'finance' with debug output
echo   ape -c                 Remove the cache file
echo   ape --clean            Remove the cache file (same as -c)
echo   ape --help             Show this help message
echo.
echo CACHE:
echo   - Cache location: %%TEMP%%\python_venv_cache.txt
echo   - Run 'ape --scan' after creating new venvs to update cache
echo   - Delete cache file to force directory search
echo   - Cache persists until manually deleted
echo.
echo NOTES:
echo   - Type 'deactivate' then 'exit' to close the activated shell
echo   - Use 'spe' to interactively browse all available environments
echo   - First time use: Run 'ape --scan' to build the cache for faster searches
echo   - Both 'ape' and 'spe' open new shells with the environment activated
echo.
goto :eof

:check_flag
set "flag=%~1"
if not "%flag:~0,1%"=="-" goto :eof

rem Check if it's a known flag
if /i "%flag%"=="-v" goto :eof
if /i "%flag%"=="--verbose" goto :eof
if /i "%flag%"=="--scan" goto :eof
if /i "%flag%"=="-s" goto :eof
if /i "%flag%"=="-c" goto :eof
if /i "%flag%"=="--clean" goto :eof
if /i "%flag%"=="-h" goto :eof
if /i "%flag%"=="--help" goto :eof
if /i "%flag%"=="/?" goto :eof

rem Unknown flag detected - set error flag
set "UNKNOWN_FLAG_ERROR=%flag%"
goto :eof

:print_scan_results
for /l %%i in (1,1,%cache_index%) do (
    echo   %%i. !cache_name[%%i]! ^(!cache_type[%%i]!^)
    echo      !cache_path[%%i]!
    echo.
)
goto :eof
