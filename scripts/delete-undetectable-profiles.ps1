param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [string[]]$Id,
    [string[]]$Name,
    [string[]]$Tag,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\undetectable-app.ps1")

function ConvertTo-StringArray {
    param([object]$Value)

    $items = [System.Collections.Generic.List[string]]::new()

    function Add-StringValue {
        param([object]$Item)

        if ($null -eq $Item) {
            return
        }

        if ($Item -is [array]) {
            foreach ($nestedItem in $Item) {
                Add-StringValue -Item $nestedItem
            }

            return
        }

        foreach ($part in $Item.ToString() -split ",") {
            $text = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $items.Add($text)
            }
        }
    }

    if ($null -eq $Value) {
        return @()
    }

    Add-StringValue -Item $Value
    return @($items.ToArray())
}

function Test-AnyMatch {
    param(
        [string]$Value,
        [string[]]$Patterns
    )

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return $true
    }

    foreach ($pattern in $Patterns) {
        if ($Value -ieq $pattern -or $Value -like $pattern) {
            return $true
        }
    }

    return $false
}

function Test-TagMatch {
    param(
        [string[]]$ProfileTags,
        [string[]]$WantedTags
    )

    if ($null -eq $WantedTags -or $WantedTags.Count -eq 0) {
        return $true
    }

    foreach ($wantedTag in $WantedTags) {
        foreach ($profileTag in $ProfileTags) {
            if ($profileTag -ieq $wantedTag) {
                return $true
            }
        }
    }

    return $false
}

function Invoke-ProfileDelete {
    param([string]$ProfileId)

    $response = Invoke-RestMethod -Uri "$ApiUrl/profile/delete/$ProfileId" -Method Get -TimeoutSec 60
    if ($response -and $response.PSObject.Properties.Name -contains "code" -and $response.code -ne 0) {
        $errorText = $response | ConvertTo-Json -Depth 10 -Compress
        throw "Profile delete failed: $errorText"
    }

    return $response
}

$Id = ConvertTo-StringArray -Value $Id
$Name = ConvertTo-StringArray -Value $Name
$Tag = ConvertTo-StringArray -Value $Tag

if ($Id.Count -eq 0 -and $Name.Count -eq 0 -and $Tag.Count -eq 0) {
    throw "Pass at least one -Id, -Name, or -Tag filter. Wildcards are supported for -Name, e.g. -Name 'DE_*'."
}

Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds

$response = Invoke-RestMethod -Uri "$ApiUrl/list" -Method Get -TimeoutSec 20
if ($response.code -ne 0 -or -not $response.data) {
    throw "Failed to fetch profiles from $ApiUrl/list."
}

$profiles = [System.Collections.Generic.List[object]]::new()
foreach ($profileId in $response.data.PSObject.Properties.Name) {
    $profileData = $response.data.$profileId
    $profileTags = ConvertTo-StringArray -Value $profileData.tags

    $profiles.Add([PSCustomObject]@{
            Id   = $profileId
            Name = $profileData.name
            Tags = $profileTags
        })
}

$matches = [System.Collections.Generic.List[object]]::new()
foreach ($profile in $profiles) {
    if ((Test-AnyMatch -Value $profile.Id -Patterns $Id) -and (Test-AnyMatch -Value $profile.Name -Patterns $Name) -and (Test-TagMatch -ProfileTags $profile.Tags -WantedTags $Tag)) {
        $matches.Add($profile)
    }
}

if ($matches.Count -eq 0) {
    Write-Host "No matching profiles found." -ForegroundColor Yellow
    exit 0
}

Write-Host "Matching profiles:" -ForegroundColor Cyan
foreach ($profile in $matches) {
    $tagText = if ($profile.Tags.Count -gt 0) { $profile.Tags -join ", " } else { "no tags" }
    Write-Host " - $($profile.Name) [$($profile.Id)] ($tagText)"
}

if ($DryRun) {
    Write-Host "Dry run only. No profiles deleted." -ForegroundColor Yellow
    exit 0
}

foreach ($profile in $matches) {
    Invoke-ProfileDelete -ProfileId $profile.Id | Out-Null
    Write-Host "Deleted '$($profile.Name)' [$($profile.Id)]." -ForegroundColor Green
}

Write-Host "Deleted $($matches.Count) profile(s)." -ForegroundColor Green