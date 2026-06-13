param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [string]$NamePrefix = "Regxorder",
    [string]$Os,
    [string]$Browser,
    [ValidateSet("local", "cloud")]
    [string]$Type = "cloud",
    [int]$Cpu,
    [int]$Memory,
    [string]$Resolution,
    [switch]$RandomResolution,
    [string[]]$Languages,
    [string]$Timezone,
    [string]$Geolocation,
    [string]$Proxy,
    [string]$Folder,
    [string]$Group,
    [string[]]$Tags = @("regxorder", "random"),
    [string]$Notes,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\undetectable-app.ps1")

# Documented allowed values for POST /profile/create, further limited to even counts >= 4
# (0 is meaningless and odd core/memory counts are uncommon on real configurations).
$allowedCpu = @(4, 6, 8, 10, 12, 16, 20, 24, 32)
$allowedMemory = @(4, 8, 16, 32)
$allowedResolutions = @(
    "800x600", "960x540", "1024x768", "1152x864", "1280x720", "1280x768",
    "1280x800", "1280x1024", "1366x768", "1408x792", "1440x900", "1400x1050",
    "1440x1080", "1536x864", "1600x900", "1600x1024", "1600x1200", "1680x1050",
    "1920x1080", "1920x1200", "2048x1152", "2560x1080", "2560x1440", "3440x1440",
    "3840x2160", "5120x1440"
)
$languagePairs = @(
    "en-US, en",
    "en-GB, en",
    "en-CA, en",
    "en-AU, en",
    "es-ES, en-US",
    "fr-FR, en-US",
    "de-DE, en-US"
)

function Add-PayloadValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Payload,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if ($Value -is [array] -and $Value.Count -eq 0) {
        return
    }

    $Payload[$Name] = $Value
}

# Map of proxy country names (and common aliases) to an Accept-Language pair.
# Generic/region proxies (for example "Europe") are intentionally absent so they are skipped.
$countryLanguageMap = [ordered]@{
    "germany"        = "de-DE, en"
    "uk"             = "en-GB, en"
    "united kingdom" = "en-GB, en"
    "great britain"  = "en-GB, en"
    "england"        = "en-GB, en"
    "france"         = "fr-FR, en"
    "switzerland"    = "de-CH, en"
    "spain"          = "es-ES, en"
    "norway"         = "nb-NO, en"
    "italy"          = "it-IT, en"
    "finland"        = "fi-FI, en"
    "sweden"         = "sv-SE, en"
    "poland"         = "pl-PL, en"
    "canada"         = "en-CA, en"
    "nz"             = "en-NZ, en"
    "new zealand"    = "en-NZ, en"
    "australia"      = "en-AU, en"
    "usa"            = "en-US, en"
    "united states"  = "en-US, en"
    "netherlands"    = "nl-NL, en"
    "belgium"        = "nl-BE, en"
    "austria"        = "de-AT, en"
    "portugal"       = "pt-PT, en"
    "ireland"        = "en-IE, en"
    "denmark"        = "da-DK, en"
    "czechia"        = "cs-CZ, en"
    "czech republic" = "cs-CZ, en"
    "greece"         = "el-GR, en"
    "romania"        = "ro-RO, en"
    "japan"          = "ja-JP, en"
    "brazil"         = "pt-BR, en"
    "mexico"         = "es-MX, en"
}

function Resolve-ProxyCountryLanguage {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $false)][string]$ProxyName
    )

    if ([string]::IsNullOrWhiteSpace($ProxyName)) {
        return $null
    }

    $normalized = $ProxyName.Trim().ToLowerInvariant()

    # Exact name match first (keeps short aliases like "uk"/"nz" from matching inside other words).
    if ($Map.Contains($normalized)) {
        return $Map[$normalized]
    }

    # Whole-word match for longer country names (for example "Germany Premium").
    foreach ($alias in $Map.Keys) {
        if ($alias.Length -lt 4) {
            continue
        }

        if ($normalized -match ("\b" + [regex]::Escape($alias) + "\b")) {
            return $Map[$alias]
        }
    }

    return $null
}

function Add-EnglishLanguage {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Language
    )

    $tags = @($Language -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $hasEnglish = $tags | Where-Object { $_ -ieq "en" -or $_ -match "^en[-_]" }
    if (-not $hasEnglish) {
        $tags += "en"
    }

    return ($tags -join ", ")
}

Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds

$configsResponse = Invoke-RestMethod -Uri "$ApiUrl/configslist" -Method Get -TimeoutSec 20
if ($configsResponse.code -ne 0 -or -not $configsResponse.data) {
    throw "Failed to fetch Undetectable configurations from $ApiUrl/configslist."
}

$configs = @()
foreach ($id in $configsResponse.data.PSObject.Properties.Name) {
    $config = $configsResponse.data.$id
    $configs += [PSCustomObject]@{
        Id      = $id
        Os      = $config.os
        Browser = $config.browser
        Screen  = $config.screen
    }
}

if (-not [string]::IsNullOrWhiteSpace($Os)) {
    $configs = @($configs | Where-Object { $_.Os -like "*$Os*" })
}

if (-not [string]::IsNullOrWhiteSpace($Browser)) {
    $configs = @($configs | Where-Object { $_.Browser -like "*$Browser*" })
}

if ($configs.Count -eq 0) {
    throw "No configurations matched OS '$Os' and browser '$Browser'."
}

$selectedConfig = $configs | Get-Random
$profileName = "{0}_{1}_{2}" -f $NamePrefix, (Get-Date -Format "yyyyMMdd-HHmmss"), (([guid]::NewGuid().ToString("N")).Substring(0, 8))

if ($Cpu -le 0) {
    $Cpu = $allowedCpu | Get-Random
}
elseif ($allowedCpu -notcontains $Cpu) {
    throw "Invalid -Cpu '$Cpu'. Allowed values: $($allowedCpu -join ', ')."
}

if ($Memory -le 0) {
    $Memory = $allowedMemory | Get-Random
}
elseif ($allowedMemory -notcontains $Memory) {
    throw "Invalid -Memory '$Memory'. Allowed values: $($allowedMemory -join ', ')."
}

if (-not [string]::IsNullOrWhiteSpace($Resolution)) {
    if ($allowedResolutions -notcontains $Resolution) {
        throw "Invalid -Resolution '$Resolution'. Allowed values: $($allowedResolutions -join ', ')."
    }
}
elseif ($RandomResolution) {
    $Resolution = $allowedResolutions | Get-Random
}
# Otherwise leave $Resolution empty: the selected Config's own default screen is used by
# Undetectable (configs may report non-standard screens, e.g. 2056x1329, that aren't valid
# create-time resolutions, and for mobile/Mac configs the resolution is locked anyway).

# Auto-select a country-named proxy (unless one was passed) and align language to its country.
$proxyCountryLanguage = $null
if ([string]::IsNullOrWhiteSpace($Proxy)) {
    $proxiesResponse = $null
    try {
        $proxiesResponse = Invoke-RestMethod -Uri "$ApiUrl/proxies/list" -Method Get -TimeoutSec 20
    }
    catch {
        Write-Warning "Could not query proxies from $ApiUrl/proxies/list: $_"
    }

    if ($proxiesResponse -and $proxiesResponse.code -eq 0 -and $proxiesResponse.data) {
        $countryProxies = @()
        foreach ($proxyId in $proxiesResponse.data.PSObject.Properties.Name) {
            $proxyEntry = $proxiesResponse.data.$proxyId
            $proxyLanguage = Resolve-ProxyCountryLanguage -Map $countryLanguageMap -ProxyName $proxyEntry.name
            if ($null -ne $proxyLanguage) {
                $countryProxies += [PSCustomObject]@{
                    Id       = $proxyId
                    Name     = $proxyEntry.name
                    Language = $proxyLanguage
                }
            }
        }

        if ($countryProxies.Count -gt 0) {
            $selectedProxy = $countryProxies | Get-Random
            $Proxy = $selectedProxy.Id
            $proxyCountryLanguage = Add-EnglishLanguage -Language $selectedProxy.Language
            Write-Host "Selected country proxy '$($selectedProxy.Name)' -> language '$proxyCountryLanguage'." -ForegroundColor Cyan
        }
        else {
            Write-Warning "No country-named proxies found in the proxy manager; creating profile without an auto-selected proxy."
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($proxyCountryLanguage) -and ($null -eq $Languages -or $Languages.Count -eq 0)) {
    $languageValue = $proxyCountryLanguage
}
elseif ($null -eq $Languages -or $Languages.Count -eq 0) {
    $languageValue = $languagePairs | Get-Random
}
else {
    $languageValue = $Languages -join ", "
}

$payload = [ordered]@{
    name     = $profileName
    configid = $selectedConfig.Id
    type     = $Type
    cpu      = $Cpu
    memory   = $Memory
    language = $languageValue
}

Add-PayloadValue -Payload $payload -Name "resolution" -Value $Resolution
Add-PayloadValue -Payload $payload -Name "timezone" -Value $Timezone
Add-PayloadValue -Payload $payload -Name "geolocation" -Value $Geolocation
Add-PayloadValue -Payload $payload -Name "proxy" -Value $Proxy
Add-PayloadValue -Payload $payload -Name "folder" -Value $Folder
Add-PayloadValue -Payload $payload -Name "group" -Value $Group
Add-PayloadValue -Payload $payload -Name "tags" -Value $Tags
Add-PayloadValue -Payload $payload -Name "notes" -Value $Notes

$payloadJson = $payload | ConvertTo-Json -Depth 10

Write-Host "Selected config $($selectedConfig.Id): $($selectedConfig.Os), $($selectedConfig.Browser), $($selectedConfig.Screen)" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host $payloadJson
    exit 0
}

$createResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/create" -Method Post -ContentType "application/json" -Body $payloadJson -TimeoutSec 60
if ($createResponse.code -ne 0) {
    if ($createResponse.data.error -like "*permissions to create profiles*") {
        throw "Undetectable rejected /profile/create before profile settings were applied. A minimal documented request with only a name returns the same permission error, so this is not caused by configid/type/cpu/memory/language. Check Undetectable role/plan/API permissions, or contact Undetectable support with: POST /profile/create => '$($createResponse.data.error)'."
    }

    $errorText = $createResponse | ConvertTo-Json -Depth 10 -Compress
    throw "Profile creation failed: $errorText"
}

Write-Host "Created profile '$profileName'." -ForegroundColor Green
$profileId = $createResponse.data.profile_id
if (-not [string]::IsNullOrWhiteSpace($profileId)) {
    Write-Host "Profile ID: $profileId" -ForegroundColor Green
}
$createResponse | ConvertTo-Json -Depth 10