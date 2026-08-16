param (
    [string]$ApiUrl = "http://localhost:25325",
    [string]$UndetectablePath,
    [Nullable[int]]$TimeoutSeconds
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\undetectable-app.ps1")

Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $TimeoutSeconds