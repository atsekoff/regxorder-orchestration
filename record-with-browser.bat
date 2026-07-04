@set "PS_EXE=pwsh"
@where "%PS_EXE%" >nul 2>nul || set "PS_EXE=powershell"
@"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\record.ps1" -WithBrowser %*