param (
    [string]$ApiUrl = "http://localhost:25325",
    [string]$UndetectablePath,
    [Nullable[int]]$StartupTimeoutSeconds
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\scripts\lib\undetectable-app.ps1")

function Test-ValuePresent {
    param([object]$Value)

    return $null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds

$response = Invoke-RestMethod -Uri "$ApiUrl/proxies/list" -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 20
if ($response.code -ne 0) {
    throw "Undetectable /proxies/list returned code $($response.code)."
}

$proxyIds = if ($response.data) { @($response.data.PSObject.Properties.Name) } else { @() }
if ($proxyIds.Count -eq 0) {
    Write-Output "No configured proxies were returned."
    exit 0
}

$proxyNumber = 0
$reports = foreach ($proxyId in $proxyIds) {
    $proxyNumber++
    $proxy = $response.data.$proxyId
    $propertyNames = @($proxy.PSObject.Properties.Name | Sort-Object)

    [PSCustomObject]@{
        ProxyNumber      = $proxyNumber
        Type             = if (Test-ValuePresent $proxy.type) { [string]$proxy.type } else { "<missing>" }
        HasHost          = Test-ValuePresent $proxy.host
        HasPort          = Test-ValuePresent $proxy.port
        HasLogin         = Test-ValuePresent $proxy.login
        HasPassword      = Test-ValuePresent $proxy.password
        HasIpChangeLink  = Test-ValuePresent $proxy.ipchangelink
        AvailableFields  = $propertyNames -join ", "
    }
}

Write-Output "Undetectable proxy capability report (values and credentials redacted)"
Write-Output "Proxy count: $($reports.Count)"
$reports | Format-Table -AutoSize

$directlyUsable = @($reports | Where-Object { $_.HasHost -and $_.HasPort })
Write-Output "Entries with host and port: $($directlyUsable.Count)/$($reports.Count)"
Write-Output "Share this report; do not share the raw /proxies/list response."