@echo off
setlocal EnableDelayedExpansion

:: Keep console open if double-clicked
if "%~1"=="" if not defined PROMPT_COMMAND set PROMPT_COMMAND=1

:: ---------------------------------------------------------------------
:: CACHE CONFIGURATION
:: ---------------------------------------------------------------------
set "CACHE_FILE=%TEMP%\python_venv_cache.txt"
set "CACHE_LOCK=%TEMP%\python_venv_cache.lock"

:: ---------------------------------------------------------------------
:: CHECK FOR HELP FLAG FIRST
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

:: ---------------------------------------------------------------------
:: CHECK FOR UNKNOWN FLAGS (exit immediately if found)
:: ---------------------------------------------------------------------
set "UNKNOWN_FLAG_ERROR="
if not "%~1"=="" call :check_flag "%~1"
if not "%~2"=="" if not defined UNKNOWN_FLAG_ERROR call :check_flag "%~2"

if defined UNKNOWN_FLAG_ERROR (
    echo.
    echo Warning: Unknown flag "!UNKNOWN_FLAG_ERROR!"
    echo Run 'spe --help' for usage information.
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
if /i "%~1"=="-c" set "CLEAN_MODE=1"
if /i "%~1"=="--clean" set "CLEAN_MODE=1"
if /i "%~2"=="-c" set "CLEAN_MODE=1"
if /i "%~2"=="--clean" set "CLEAN_MODE=1"

:: ---------------------------------------------------------------------
:: CHECK FOR VERBOSE FLAG
:: ---------------------------------------------------------------------
set "VERBOSE=0"
if /i "%~1"=="-v" set "VERBOSE=1"
if /i "%~1"=="--verbose" set "VERBOSE=1"
if /i "%~2"=="-v" set "VERBOSE=1"
if /i "%~2"=="--verbose" set "VERBOSE=1"

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
:: LOAD CACHE OR SCAN
:: ---------------------------------------------------------------------
set /a index=0

if %SCAN_MODE%==1 (
    echo Performing comprehensive scan...
    echo This may take a moment...
    echo.
    call :scan_all_venvs
    echo Found !index! environments.
    call :save_cache
    echo Cache updated.
    echo.
    rem After scanning, index is already set, don't reset it
    goto :display_results
)

:: ---------------------------------------------------------------------
:: LOAD FROM CACHE IF EXISTS
:: ---------------------------------------------------------------------
set "use_cache=0"

if exist "%CACHE_FILE%" (
    if %VERBOSE%==1 echo [DEBUG] Loading from cache...
    call :load_cache
    set "use_cache=1"
    goto :display_results
)

:: ---------------------------------------------------------------------
:: FIND ALL ENVIRONMENTS (if no cache)
:: ---------------------------------------------------------------------
echo Searching for Python environments in predefined directories...
if %VERBOSE%==1 echo [DEBUG] Tip: Use --scan to search your entire user folder
echo.
call :scan_predefined_dirs

:display_results

if %index%==0 (
    echo No Python environments found.
    echo.
    if %SCAN_MODE%==0 (
        echo Tip: Try running 'spe --scan' for a comprehensive search.
        echo.
    )
    pause
    goto :eof
)

:: ---------------------------------------------------------------------
:: PRINT TABLE HEADER
:: ---------------------------------------------------------------------
call :print_header

:: ---------------------------------------------------------------------
:: PRINT TABLE ROWS
:: ---------------------------------------------------------------------
for /l %%N in (1,1,%index%) do (
    set "n=!env_name[%%N]!"
    set "t=!env_type[%%N]!"
    set "p=!env_path[%%N]!"
    call :print_row %%N "!n!" "!t!" "!p!"
)

echo.

:: ---------------------------------------------------------------------
:: ASK USER WHICH ENVIRONMENT TO ACTIVATE
:: ---------------------------------------------------------------------
:ask_env
echo Enter the number or name of the environment, or Q to quit
set /p "venv_input=> "

if /i "%venv_input%"=="q" (
    echo Exiting...
    goto :eof
)

set "venv_name="
set "venv_path="

for /l %%N in (1,1,%index%) do (
    if "%venv_input%"=="%%N" (
        set "venv_name=!env_name[%%N]!"
        set "venv_path=!env_path[%%N]!"
    )
    if not defined venv_name (
        if /i "%venv_input%"=="!env_name[%%N]!" (
            set "venv_name=!env_name[%%N]!"
            set "venv_path=!env_path[%%N]!"
        )
    )
)

if defined venv_path (
    echo.
    echo Activating "!venv_name!" ...
    echo.
    echo [!venv_name! activated - Type 'deactivate' or 'exit' to close]
    echo.
    cmd /k "!venv_path!\Scripts\activate.bat"
    goto :eof
) else (
    echo.
    echo Environment "%venv_input%" not found.
    echo.
    goto ask_env
)

goto :eof

:: ---------------------------------------------------------------------
:: HELPER FUNCTIONS
:: ---------------------------------------------------------------------

:scan_predefined_dirs
for /l %%i in (1,1,25) do (
    set "current_dir=!dirs[%%i]!"
    if exist "!current_dir!" (
        if %VERBOSE%==1 echo [DEBUG] Checking "!current_dir!"
        for /f "delims=" %%D in ('dir /b /ad "!current_dir!" 2^>nul') do (
            set "env_dir=!current_dir!\%%D"
            set "env_name=%%D"
            set "env_type="

            rem Detect type (venv, conda, uv)
            if exist "!env_dir!\conda-meta" set "env_type=conda"
            if not defined env_type if exist "!env_dir!\pyvenv.cfg" (
                findstr /C:"uv" "!env_dir!\pyvenv.cfg" >nul 2>&1
                if !errorlevel!==0 set "env_type=uv"
            )
            if not defined env_type if exist "!env_dir!\Scripts\activate.bat" set "env_type=venv"

            rem Handle result via flag (no ELSE in loop!)
            set "is_valid=0"
            if defined env_type set "is_valid=1"

            if "!is_valid!"=="1" (
                set /a index+=1
                set "env_name[!index!]=!env_name!"
                set "env_type[!index!]=!env_type!"
                set "env_path[!index!]=!env_dir!"
                if %VERBOSE%==1 echo [DEBUG] Added !env_name! (!env_type!)
            )
            if "!is_valid!"=="0" (
                if %VERBOSE%==1 echo [DEBUG] Skipping non-python folder: !env_name!
            )
        )
    )
    if not exist "!current_dir!" (
        if %VERBOSE%==1 echo [DEBUG] Directory not found: "!current_dir!"
    )
)

)
goto :eof

:scan_all_venvs
set /a index=0
set /a scan_count=0
if %VERBOSE%==1 (
    echo [DEBUG] Scanning for pyvenv.cfg files in user directory...
    echo [DEBUG] This may take a few minutes depending on folder size...
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
            set /a index+=1
            set "env_name[!index!]=!env_name!"
            set "env_type[!index!]=!env_type!"
            set "env_path[!index!]=!env_dir!"
            if %VERBOSE%==1 echo [DEBUG] Found: !env_name! ^(!env_type!^) at !env_dir!
        )
    )
)
if %VERBOSE%==1 (
    echo [DEBUG] Scan complete. Found !index! environments.
) else (
    echo Scan complete. Checked !scan_count! files.
)
goto :eof

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
if %VERBOSE%==1 echo [DEBUG] Number of environments to save: %index%
if exist "%CACHE_FILE%" del "%CACHE_FILE%" 2>nul
if %index% GTR 0 (
    for /l %%i in (1,1,%index%) do (
        echo !env_name[%%i]!^|!env_type[%%i]!^|!env_path[%%i]!>> "%CACHE_FILE%"
        if %VERBOSE%==1 echo [DEBUG] Saved: !env_name[%%i]! ^| !env_type[%%i]! ^| !env_path[%%i]!
    )
) else (
    if %VERBOSE%==1 echo [DEBUG] No environments to save
)
goto :eof

:load_cache
set /a index=0
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("%CACHE_FILE%") do (
    set /a index+=1
    set "env_name[!index!]=%%A"
    set "env_type[!index!]=%%B"
    set "env_path[!index!]=%%C"
    if %VERBOSE%==1 echo [DEBUG] Loaded from cache: %%A ^(%%B^)
)
if %VERBOSE%==1 echo [DEBUG] Loaded !index! environments from cache
goto :eof

:print_header
echo   #   Name                 Type      Path
echo   --  -------------------- --------  ----------------------------------------------
goto :eof

:print_row
setlocal
set "num=%~1"
set "name=%~2"
set "type=%~3"
set "path=%~4"
set "name_padded=%name%                  "
set "type_padded=%type%       "
echo   %num%.  !name_padded:~0,20!  !type_padded:~0,8!  %path%
endlocal
goto :eof

:show_help
echo.
echo SPE - Search Python Environment
echo ================================
echo.
echo DESCRIPTION:
echo   Interactively search and activate Python virtual environments.
echo   Scans predefined directories for venv, conda, and uv environments.
echo.
echo USAGE:
echo   spe [OPTIONS]
echo.
echo OPTIONS:
echo   -h, --help       Show this help message and exit
echo   -v, --verbose    Enable verbose output (shows debug information)
echo   -s, --scan       Perform comprehensive scan and update cache
echo   -c, --clean      Remove the cache file and exit
echo.
echo BEHAVIOR:
echo   By default, searches predefined directories quickly. Uses cached results
echo   if available. With --scan, performs a comprehensive search of your entire
echo   user folder for virtual environments and updates the persistent cache.
echo.
echo   You can select an environment by number or by typing its name.
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
echo   spe              List and activate an environment (uses cache if exists)
echo   spe -s           Scan entire user folder and update cache
echo   spe --scan       Scan entire user folder and update cache (same as -s)
echo   spe -v           List environments with debug output
echo   spe -s -v        Scan with verbose output
echo   spe -c           Remove the cache file
echo   spe --clean      Remove the cache file (same as -c)
echo   spe --help       Show this help message
echo.
echo CACHE:
echo   - Cache location: %%TEMP%%\python_venv_cache.txt
echo   - Run with --scan after creating new venvs to update cache
echo   - Delete cache file to force fresh scan on next run
echo   - Cache persists until manually deleted
echo.
echo NOTES:
echo   - Type 'deactivate' or 'exit' in the activated environment to return to normal
echo   - Type 'Q' at the selection prompt to quit without activating
echo   - First run without cache uses predefined directories (fast)
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
