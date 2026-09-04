[CmdletBinding(DefaultParameterSetName = "ByName")]
param (
    [Parameter(Mandatory = $true, ParameterSetName = "ByName")]
    [string]$ProfileName,

    [Parameter(Mandatory = $true, ParameterSetName = "ById")]
    [string]$ProfileId,

    [string]$Url = "https://example.com/",
    [string]$ApiUrl = "http://localhost:25325"
)

$ErrorActionPreference = "Stop"

$profilesResponse = Invoke-RestMethod -Uri "$ApiUrl/list" -Method Get -TimeoutSec 20
if ($profilesResponse.code -ne 0 -or -not $profilesResponse.data) {
    throw "Failed to retrieve profiles from $ApiUrl/list."
}

if ($PSCmdlet.ParameterSetName -eq "ByName") {
    $matches = @($profilesResponse.data.PSObject.Properties | Where-Object { $_.Value.name -eq $ProfileName })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one profile named '$ProfileName'; found $($matches.Count)."
    }
    $ProfileId = $matches[0].Name
}

$startUri = "$ApiUrl/profile/start/$ProfileId?start-pages=$([uri]::EscapeDataString($Url))"
Write-Host "Request: GET $startUri" -ForegroundColor Cyan
$response = Invoke-RestMethod -Uri $startUri -Method Get -TimeoutSec 60
Write-Host "Response:" -ForegroundColor Cyan
$response | ConvertTo-Json -Depth 10 | Write-Host

if ($response.code -eq 0) {
    Write-Host "The API reported success. Check the opened profile now." -ForegroundColor Green
    Write-Host "If it remains blank instead of showing '$Url', Undetectable is ignoring start-pages." -ForegroundColor Yellow
}
else {
    Write-Host "The API rejected the request; start-pages may have changed or the profile may already be running." -ForegroundColor Red
}