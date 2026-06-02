param (
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$Title
)

$ErrorActionPreference = "Stop"

$process = Start-Process -FilePath (Join-Path $PSScriptRoot "regxorder-cli.exe") `
    -ArgumentList @("record", "--output", $OutputPath, "--title", $Title, "--start-hotkey", "ctrl+shift+f9", "--stop-hotkey", "ctrl+shift+f10") `
    -NoNewWindow `
    -PassThru

Start-Sleep -Milliseconds 250
& (Join-Path $PSScriptRoot "focus-undetectable-window.ps1") | Out-Null

$process.WaitForExit()
exit $process.ExitCode