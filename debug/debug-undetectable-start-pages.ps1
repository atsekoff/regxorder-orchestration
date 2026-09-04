[CmdletBinding(DefaultParameterSetName = "ByName")]
param (
    [Parameter(Mandatory = $true, ParameterSetName = "ByName")]
    [string]$ProfileName,

    [Parameter(Mandatory = $true, ParameterSetName = "ById")]
    [string]$ProfileId,

    [string]$Url = "https://example.com/",
    [string]$ApiUrl = "http://localhost:25325",
    [switch]$InspectOnly
)

$ErrorActionPreference = "Stop"

function Find-StartPageProperty {
    param(
        [object]$Value,
        [string]$Path = "data"
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsPrimitive) {
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Management.Automation.PSCustomObject]) {
        $index = 0
        foreach ($item in $Value) {
            Find-StartPageProperty -Value $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    foreach ($property in $Value.PSObject.Properties) {
        $propertyPath = "$Path.$($property.Name)"
        if ($property.Name -match "(?i:start|page|home|url)") {
            [PSCustomObject]@{
                Path  = $propertyPath
                Value = $property.Value | ConvertTo-Json -Depth 10 -Compress
            }
        }
        Find-StartPageProperty -Value $property.Value -Path $propertyPath
    }
}

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

if ($InspectOnly) {
    $profileResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/getinfo/$ProfileId" -Method Get -TimeoutSec 20
    if ($profileResponse.code -ne 0 -or -not $profileResponse.data) {
        throw "Failed to retrieve profile '$ProfileId'."
    }

    $properties = @(Find-StartPageProperty -Value $profileResponse.data)
    if ($properties.Count -eq 0) {
        Write-Host "No start/page/home/url properties were exposed by /profile/getinfo/$ProfileId." -ForegroundColor Yellow
    }
    else {
        $properties | Format-Table -AutoSize | Out-String | Write-Host
    }
    return
}

$startUri = "$ApiUrl/profile/start/${ProfileId}?start-pages=$([uri]::EscapeDataString($Url))"
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