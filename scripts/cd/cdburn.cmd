@echo off
setlocal
rem Launcher for cdburn.py - prefers the Python launcher (py -3), falls back to python.
set "CDB_PY=python"
where py >nul 2>&1 && set "CDB_PY=py -3"
%CDB_PY% "%~dp0cdburn.py" %*
exit /b %errorlevel%
