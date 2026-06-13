@echo off
:: Ensure the script runs from the directory it is located in
cd /d "%~dp0"

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

:GET_RESOLUTION
set /p "SESSION_RESOLUTION=Enter recording resolution (e.g. 1920x1080): "

:: Validate that the resolution isn't empty
if "%SESSION_RESOLUTION%"=="" (
    echo [Error] Resolution cannot be empty!
    timeout /t 2 >nul
    goto GET_RESOLUTION
)

set "OUTPUT_PATH="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\resolve-recording-output-path.ps1" -SessionType "%SESSION_TYPE%" -SessionName "%SESSION_NAME%" -Resolution "%SESSION_RESOLUTION%"`) do set "OUTPUT_PATH=%%I"

if "%OUTPUT_PATH%"=="" (
    echo [Error] Could not create a recording path. Use a resolution like 1920x1080.
    timeout /t 2 >nul
    goto GET_RESOLUTION
)

echo.
echo Target path: %OUTPUT_PATH%
echo.

:: Execute the CLI tool with the dynamic folder type and session name
.\regxorder-cli.exe record --output "%OUTPUT_PATH%" --title "%SESSION_NAME%" --start-hotkey ctrl+shift+f9 --stop-hotkey ctrl+shift+f10

:: Automatically close the terminal window when done
exit