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

cls
echo ===================================================
echo               REGXORDER RECORDING SESSION          
echo ===================================================
echo.

:GET_TYPE
echo.
echo Select the session type:
echo [1] pre-session
echo [2] main-session
echo [3] post-session
echo.
set /p "TYPE_CHOICE=Enter choice (1, 2, or 3): "

:: Map the choice to the folder name (acting as our enum)
if "%TYPE_CHOICE%"=="1" set "SESSION_TYPE=pre-sessions"
if "%TYPE_CHOICE%"=="2" set "SESSION_TYPE=main-sessions"
if "%TYPE_CHOICE%"=="3" set "SESSION_TYPE=post-sessions"

:: Validate the selection
if "%SESSION_TYPE%"=="" (
    echo [Error] Invalid choice! Please select 1, 2, or 3.
    timeout /t 2 >nul
    echo.
    goto GET_TYPE
)

:GET_NAME
set /p "SESSION_NAME=Enter session name (e.g. google_search): "

:: Validate that the session name isn't empty
if "%SESSION_NAME%"=="" (
    echo [Error] Session name cannot be empty!
    timeout /t 2 >nul
    goto GET_NAME
)

set "OUTPUT_PATH="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\resolve-recording-output-path.ps1" -SessionType "%SESSION_TYPE%" -SessionName "%SESSION_NAME%"`) do set "OUTPUT_PATH=%%I"

if "%OUTPUT_PATH%"=="" (
    echo [Error] Could not create a recording path from the selected profile resolution.
    exit /b 1
)

echo.
echo Target path: %OUTPUT_PATH%
echo.

:: Execute the CLI tool, then focus the selected browser profile once recording is beginning
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-record-with-focus.ps1" -OutputPath "%OUTPUT_PATH%" -Title "%SESSION_NAME%"

if %ERRORLEVEL% NEQ 0 (
    echo [Batch] Recording failed.
    exit /b %ERRORLEVEL%
)

:: Automatically close the terminal window when done
exit