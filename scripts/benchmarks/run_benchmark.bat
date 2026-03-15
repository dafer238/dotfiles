@echo off
setlocal

REM Number of full benchmark cycles
set CYCLES=10

REM Delay between cycles (seconds)
set DELAY=20

REM Output file
set OUTPUT=all-results.csv

echo "App","Run","StartupSeconds","RAM_MB" > %OUTPUT%

for /L %%i in (1,1,%CYCLES%) do (
    echo.
    echo ===== Benchmark cycle %%i of %CYCLES% =====

    powershell -ExecutionPolicy Bypass -File benchmark-apps.ps1

    if exist benchmark-results.csv (
        REM Skip the header line and append only data rows
        powershell -Command "Get-Content benchmark-results.csv | Select-Object -Skip 1 | Set-Content benchmark-results-noheader.csv"
        type benchmark-results-noheader.csv >> %OUTPUT%
        del benchmark-results-noheader.csv
    )

    echo Waiting %DELAY% seconds before next cycle...
    timeout /t %DELAY% >nul
)

echo.
echo Benchmark complete. Raw results saved to %OUTPUT%
echo.
echo Generating summary...
powershell -ExecutionPolicy Bypass -File summarize-results.ps1 -CsvPath %OUTPUT%

pause