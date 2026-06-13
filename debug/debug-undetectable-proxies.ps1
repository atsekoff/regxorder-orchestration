param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [switch]$TestConnectivity,
    [int]$ConnectTimeoutSeconds = 5
)

$ErrorActionPreference = "Stop"

# Import helper functions (scripts/lib lives one level up from this debug folder)
. (Join-Path $PSScriptRoot "..\scripts\lib\undetectable-app.ps1")

function Test-ProxyReachable {
    param(
        [Parameter(Mandatory = $true)][string]$ProxyHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSeconds = 5
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ProxyHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            return $false
        }

        $client.EndConnect($async)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "    Undetectable Proxies Debugger           " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Start or verify Undetectable
try {
    Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds
}
catch {
    Write-Host "Error connecting to or starting Undetectable: $_" -ForegroundColor Red
    exit 1
}

# 2. Query the proxies list
Write-Host "`n[Step 2] Querying Proxies (/proxies/list)..." -ForegroundColor Yellow
try {
    $response = Invoke-RestMethod -Uri "$ApiUrl/proxies/list" -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 20
}
catch {
    Write-Host "Failed to query /proxies/list: $_" -ForegroundColor Red
    exit 1
}

if ($response.code -ne 0) {
    $detail = if ($response.data.error) { $response.data.error } else { $response.status }
    Write-Host "API returned an error: $detail" -ForegroundColor Red
    exit 1
}

$proxiesData = $response.data
$proxyIds = @()
if ($proxiesData) {
    $proxyIds = @($proxiesData.psobject.Properties.Name)
}

if ($proxyIds.Count -eq 0) {
    Write-Host "No proxies are configured in the Undetectable proxy manager." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($proxyIds.Count) proxies." -ForegroundColor Green

# 3. Build a structured view
$proxies = foreach ($id in $proxyIds) {
    $p = $proxiesData.$id
    [PSCustomObject]@{
        Id            = $id
        Name          = $p.name
        Type          = $p.type
        Host          = $p.host
        Port          = $p.port
        Login         = $p.login
        HasPassword   = -not [string]::IsNullOrWhiteSpace($p.password)
        IpChangeLink  = $p.ipchangelink
    }
}

Write-Host "`n[Step 3] Proxy Summary..." -ForegroundColor Yellow
$proxies |
    Format-Table Id, Name, Type, @{ Name = "Endpoint"; Expression = { "$($_.Host):$($_.Port)" } }, Login, HasPassword -AutoSize |
    Out-String |
    Write-Host

Write-Host "Breakdown by type:" -ForegroundColor Cyan
$proxies | Group-Object Type | ForEach-Object { Write-Host " - $($_.Name): $($_.Count)" }

$mobileProxies = @($proxies | Where-Object { -not [string]::IsNullOrWhiteSpace($_.IpChangeLink) })
if ($mobileProxies.Count -gt 0) {
    Write-Host "`nMobile proxies (with IP change link):" -ForegroundColor Cyan
    $mobileProxies | ForEach-Object { Write-Host " - $($_.Name) [$($_.Id)] -> $($_.IpChangeLink)" }
}

# 4. Optional TCP reachability test
if ($TestConnectivity) {
    Write-Host "`n[Step 4] Testing Connectivity (-TestConnectivity, timeout ${ConnectTimeoutSeconds}s)..." -ForegroundColor Yellow
    foreach ($proxy in $proxies) {
        $reachable = Test-ProxyReachable -ProxyHost $proxy.Host -Port ([int]$proxy.Port) -TimeoutSeconds $ConnectTimeoutSeconds
        if ($reachable) {
            Write-Host (" [OK]   {0} ({1}:{2})" -f $proxy.Name, $proxy.Host, $proxy.Port) -ForegroundColor Green
        }
        else {
            Write-Host (" [DEAD] {0} ({1}:{2})" -f $proxy.Name, $proxy.Host, $proxy.Port) -ForegroundColor Red
        }
    }
}
else {
    Write-Host "`nTip: re-run with -TestConnectivity to TCP-probe each proxy endpoint." -ForegroundColor DarkGray
}

Write-Host "`nDone." -ForegroundColor Cyan
