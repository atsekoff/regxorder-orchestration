@echo off
:: Ensure the script runs from the directory it is located in
cd /d "%~dp0"

:RUN_BROWSER
echo [Batch] Initiating Undetectable profile launch...

:: Call the PowerShell script and pass the profile name as an argument
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\open-undetectable.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo [Batch] Failed to launch profile.
    exit /b %ERRORLEVEL%
)

echo [Batch] Launch workflow complete.

call play.bat