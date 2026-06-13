param (
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$Title
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

try {
    & (Join-Path $PSScriptRoot "focus-undetectable-window.ps1") | Out-Null
}
catch {
    Write-Host "Focus failed for recording window '$Title': $_" -ForegroundColor Red
    exit 1
}

$process = Start-Process -FilePath (Join-Path $repoRoot "regxorder-cli.exe") `
    -ArgumentList @("record", "--output", $OutputPath, "--title", $Title, "--start-hotkey", "ctrl+shift+f9", "--stop-hotkey", "ctrl+shift+f10") `
    -WorkingDirectory $repoRoot `
    -NoNewWindow `
    -PassThru

$process.WaitForExit()
exit $process.ExitCode