param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [string]$Os,
    [string]$Browser,
    [ValidateSet("local", "cloud")]
    [string]$Type = "local",
    [int]$Cpu,
    [int]$Memory,
    [string]$Resolution,
    [switch]$RandomResolution,
    [string]$MinResolution,
    [string[]]$Languages,
    [string]$Timezone,
    [string]$Geolocation,
    [string]$Proxy,
    [string]$Folder = "Random",
    [string]$Group,
    [string[]]$Tags = @("random"),
    [string]$Notes,
    [string]$CookiesPath,
    [switch]$SkipProxyCheck,
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
$countryCodeLanguageMap = @{
    AD = "ca-AD"; AL = "sq-AL"; AT = "de-AT"; BA = "bs-BA"; BE = "nl-BE"
    BG = "bg-BG"; BY = "be-BY"; CH = "de-CH"; CY = "el-CY"; CZ = "cs-CZ"
    DE = "de-DE"; DK = "da-DK"; EE = "et-EE"; ES = "es-ES"; FI = "fi-FI"
    FR = "fr-FR"; GB = "en-GB"; GR = "el-GR"; HR = "hr-HR"; HU = "hu-HU"
    IE = "en-IE"; IS = "is-IS"; IT = "it-IT"; LI = "de-LI"; LT = "lt-LT"
    LU = "lb-LU"; LV = "lv-LV"; MC = "fr-MC"; MD = "ro-MD"; ME = "sr-Latn-ME"
    MK = "mk-MK"; MT = "mt-MT"; NL = "nl-NL"; NO = "nb-NO"; PL = "pl-PL"
    PT = "pt-PT"; RO = "ro-RO"; RS = "sr-Latn-RS"; SE = "sv-SE"; SI = "sl-SI"
    SK = "sk-SK"; SM = "it-SM"; TR = "tr-TR"; UA = "uk-UA"; VA = "it-VA"
    XK = "sq-XK"
}

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

function ConvertTo-ResolutionSize {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '^(?<Width>\d+)x(?<Height>\d+)$') {
        throw "Invalid resolution '$Value'. Expected WIDTHxHEIGHT."
    }

    return [PSCustomObject]@{
        Width  = [int]$Matches.Width
        Height = [int]$Matches.Height
    }
}

function Test-ResolutionBelowMinimum {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Minimum
    )

    $size = ConvertTo-ResolutionSize -Value $Value
    $minimumSize = ConvertTo-ResolutionSize -Value $Minimum
    return $size.Width -lt $minimumSize.Width -or $size.Height -lt $minimumSize.Height
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

function Get-ProxyCountry {
    param([Parameter(Mandatory = $true)][string]$IpAddress)

    $response = Invoke-RestMethod -Uri "https://ipwho.is/$IpAddress" -Method Get -TimeoutSec 20
    if (-not $response.success -or [string]::IsNullOrWhiteSpace($response.country_code)) {
        throw "Country lookup failed for proxy IP '$IpAddress'."
    }

    return [PSCustomObject]@{
        Code = $response.country_code.ToUpperInvariant()
        Name = $response.country
    }
}

function Get-RandomCountryCookies {
    param(
        [Parameter(Mandatory = $true)][string]$CookiesRoot,
        [Parameter(Mandatory = $false)][string]$CountryName
    )

    if ([string]::IsNullOrWhiteSpace($CountryName)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $CookiesRoot)) {
        return $null
    }

    $normalized = $CountryName.Trim().ToLowerInvariant()
    $countryDir = $null
    foreach ($dir in Get-ChildItem -LiteralPath $CookiesRoot -Directory -ErrorAction SilentlyContinue) {
        $folderName = $dir.Name.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($folderName)) {
            continue
        }

        if ($normalized -eq $folderName -or $normalized -match ("\b" + [regex]::Escape($folderName) + "\b")) {
            $countryDir = $dir
            break
        }
    }

    if ($null -eq $countryDir) {
        return $null
    }

    $cookieFiles = @(Get-ChildItem -LiteralPath $countryDir.FullName -Filter "*.json" -File -ErrorAction SilentlyContinue)
    if ($cookieFiles.Count -eq 0) {
        Write-Warning "No cookie files found in '$($countryDir.FullName)'."
        return $null
    }

    $cookieFile = $cookieFiles | Get-Random
    try {
        $rawCookies = Get-Content -LiteralPath $cookieFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to parse cookie file '$($cookieFile.FullName)': $_"
        return $null
    }

    $cookieArray = @($rawCookies | Where-Object { $null -ne $_ })
    if ($cookieArray.Count -eq 0) {
        Write-Warning "Cookie file '$($cookieFile.FullName)' contained no cookies."
        return $null
    }

    return [PSCustomObject]@{
        Country = $countryDir.Name
        File    = $cookieFile.FullName
        Cookies = $cookieArray
    }
}

function Get-UndetectableConfigsResponse {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastResponse = $null
    do {
        $lastResponse = Invoke-RestMethod -Uri "$ApiUrl/configslist" -Method Get -TimeoutSec 20
        if ($lastResponse.code -eq 0 -and $lastResponse.data -and $lastResponse.data.PSObject.Properties.Count -gt 0) {
            return $lastResponse
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $lastResponse
}

Start-UndetectableIfNeeded -ApiUrl $ApiUrl -UndetectablePath $UndetectablePath -TimeoutSeconds $StartupTimeoutSeconds

$configsResponse = Get-UndetectableConfigsResponse -ApiUrl $ApiUrl -TimeoutSeconds $StartupTimeoutSeconds
if ($configsResponse.code -ne 0 -or -not $configsResponse.data -or $configsResponse.data.PSObject.Properties.Count -eq 0) {
    throw "Failed to fetch Undetectable configurations from $ApiUrl/configslist after waiting up to $StartupTimeoutSeconds seconds."
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
$profileTimestamp = Get-Date -Format "yyyyMMdd_HHmm"

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

$hasMinResolution = -not [string]::IsNullOrWhiteSpace($MinResolution)
if ($hasMinResolution -and $allowedResolutions -notcontains $MinResolution) {
    throw "Invalid -MinResolution '$MinResolution'. Allowed values: $($allowedResolutions -join ', ')."
}

if (-not [string]::IsNullOrWhiteSpace($Resolution)) {
    if ($allowedResolutions -notcontains $Resolution) {
        throw "Invalid -Resolution '$Resolution'. Allowed values: $($allowedResolutions -join ', ')."
    }
}
elseif ($RandomResolution) {
    $Resolution = $allowedResolutions | Get-Random
}

if ($hasMinResolution -and -not [string]::IsNullOrWhiteSpace($Resolution)) {
    if (Test-ResolutionBelowMinimum -Value $Resolution -Minimum $MinResolution) {
        Write-Host "Clamped resolution '$Resolution' to minimum '$MinResolution'." -ForegroundColor Cyan
        $Resolution = $MinResolution
    }
}
elseif ($hasMinResolution -and -not [string]::IsNullOrWhiteSpace($selectedConfig.Screen)) {
    if (Test-ResolutionBelowMinimum -Value $selectedConfig.Screen -Minimum $MinResolution) {
        Write-Host "Clamped config screen '$($selectedConfig.Screen)' to minimum '$MinResolution'." -ForegroundColor Cyan
        $Resolution = $MinResolution
    }
}
# Otherwise leave $Resolution empty: the selected Config's own default screen is used by
# Undetectable (configs may report non-standard screens, e.g. 2056x1329, that aren't valid
# create-time resolutions).

# Auto-select any saved proxy unless one was passed. Its actual country is resolved from the
# checked connection after profile creation.
if ([string]::IsNullOrWhiteSpace($Proxy)) {
    $proxiesResponse = $null
    try {
        $proxiesResponse = Invoke-RestMethod -Uri "$ApiUrl/proxies/list" -Method Get -TimeoutSec 20
    }
    catch {
        Write-Warning "Could not query proxies from $ApiUrl/proxies/list: $_"
    }

    if ($proxiesResponse -and $proxiesResponse.code -eq 0 -and $proxiesResponse.data) {
        $availableProxies = @()
        foreach ($proxyId in $proxiesResponse.data.PSObject.Properties.Name) {
            $proxyEntry = $proxiesResponse.data.$proxyId
            $availableProxies += [PSCustomObject]@{
                Id   = $proxyId
                Name = $proxyEntry.name
            }
        }

        if ($availableProxies.Count -gt 0) {
            $selectedProxy = $availableProxies | Get-Random
            $Proxy = $selectedProxy.Id
            Write-Host "Selected proxy '$($selectedProxy.Name)'; country and language will be resolved after its connection check." -ForegroundColor Cyan
        }
        else {
            Write-Warning "No proxies found in the proxy manager; creating profile without an auto-selected proxy."
        }
    }
}

$languageValue = if ($null -ne $Languages -and $Languages.Count -gt 0) {
    $Languages -join ", "
}
else {
    "en-US, en"
}
$profileName = $profileTimestamp

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

# CookiesPath is resolved here so it is available to both the DryRun path and the post-check recreate.
if ([string]::IsNullOrWhiteSpace($CookiesPath)) {
    $CookiesPath = Join-Path (Split-Path -Parent $PSScriptRoot) "cookies"
}

$payloadJson = $payload | ConvertTo-Json -Depth 10

Write-Host "Selected config $($selectedConfig.Id): $($selectedConfig.Os), $($selectedConfig.Browser), $($selectedConfig.Screen)" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host $payloadJson
    exit 0
}

# Create a probe profile; if the proxy check succeeds this will be deleted and replaced
# with a new profile using the resolved country name, language, and cookies.
$createResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/create" -Method Post -ContentType "application/json" -Body $payloadJson -TimeoutSec 60
if ($createResponse.code -ne 0) {
    if ($createResponse.data.error -like "*permissions to create profiles*") {
        throw "Undetectable rejected /profile/create before profile settings were applied. A minimal documented request with only a name returns the same permission error, so this is not caused by configid/type/cpu/memory/language. Check Undetectable role/plan/API permissions, or contact Undetectable support with: POST /profile/create => '$($createResponse.data.error)'."
    }

    $errorText = $createResponse | ConvertTo-Json -Depth 10 -Compress
    throw "Profile creation failed: $errorText"
}

Write-Host "Created probe profile '$profileName'." -ForegroundColor Cyan
$profileId = $createResponse.data.profile_id
if (-not [string]::IsNullOrWhiteSpace($profileId)) {
    Write-Host "Profile ID: $profileId" -ForegroundColor Cyan
}

if (-not $SkipProxyCheck -and -not [string]::IsNullOrWhiteSpace($Proxy) -and -not [string]::IsNullOrWhiteSpace($profileId)) {
    try {
        $checkResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/checkconnection/$profileId" -Method Get -TimeoutSec 60
        if ($checkResponse.code -eq 0 -and -not [string]::IsNullOrWhiteSpace($checkResponse.data.ip)) {
            Write-Host "Checked proxy connection: $($checkResponse.data.ip)" -ForegroundColor Green

            $proxyCountry = Get-ProxyCountry -IpAddress $checkResponse.data.ip
            Write-Host "Proxy country: $($proxyCountry.Name) ($($proxyCountry.Code))" -ForegroundColor Cyan

            # profile/update does not apply the language field; delete and recreate so the
            # fingerprint is built with the correct locale from the start.
            $deleteResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/delete/$profileId" -Method Get -TimeoutSec 60
            if ($deleteResponse.code -ne 0) {
                $errorText = $deleteResponse | ConvertTo-Json -Depth 10 -Compress
                throw "Could not delete the probe profile before re-creating with the correct country settings: $errorText"
            }
            $profileId = $null

            $profileName = "$($proxyCountry.Code)_$profileTimestamp"

            if ($null -eq $Languages -or $Languages.Count -eq 0) {
                $countryLanguage = $countryCodeLanguageMap[$proxyCountry.Code]
                if (-not [string]::IsNullOrWhiteSpace($countryLanguage)) {
                    $languageValue = Add-EnglishLanguage -Language $countryLanguage
                }
                else {
                    Write-Warning "No language mapping exists for proxy country '$($proxyCountry.Code)'; keeping '$languageValue'."
                }
            }

            $cookieResult = Get-RandomCountryCookies -CookiesRoot $CookiesPath -CountryName $proxyCountry.Name

            $finalPayload = [ordered]@{
                name     = $profileName
                configid = $selectedConfig.Id
                type     = $Type
                cpu      = $Cpu
                memory   = $Memory
                language = $languageValue
            }
            Add-PayloadValue -Payload $finalPayload -Name "resolution" -Value $Resolution
            Add-PayloadValue -Payload $finalPayload -Name "timezone" -Value $Timezone
            Add-PayloadValue -Payload $finalPayload -Name "geolocation" -Value $Geolocation
            Add-PayloadValue -Payload $finalPayload -Name "proxy" -Value $Proxy
            Add-PayloadValue -Payload $finalPayload -Name "folder" -Value $Folder
            Add-PayloadValue -Payload $finalPayload -Name "group" -Value $Group
            Add-PayloadValue -Payload $finalPayload -Name "tags" -Value $Tags
            Add-PayloadValue -Payload $finalPayload -Name "notes" -Value $Notes
            if ($null -ne $cookieResult) {
                $finalPayload["cookies"] = $cookieResult.Cookies
                Write-Host "Loaded $($cookieResult.Cookies.Count) cookies for '$($cookieResult.Country)' from '$($cookieResult.File)'." -ForegroundColor Cyan
            }

            $createResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/create" -Method Post -ContentType "application/json" -Body ($finalPayload | ConvertTo-Json -Depth 10) -TimeoutSec 60
            if ($createResponse.code -ne 0) {
                $errorText = $createResponse | ConvertTo-Json -Depth 10 -Compress
                throw "Re-creation with country settings failed: $errorText"
            }

            $profileId = $createResponse.data.profile_id
            Write-Host "Created profile '$profileName' for $($proxyCountry.Name), language '$languageValue'." -ForegroundColor Green
            if (-not [string]::IsNullOrWhiteSpace($profileId)) {
                Write-Host "Profile ID: $profileId" -ForegroundColor Green
            }

            $createResponse | Add-Member -NotePropertyName checked_proxy_ip -NotePropertyValue $checkResponse.data.ip -Force
            $createResponse | Add-Member -NotePropertyName checked_proxy_country -NotePropertyValue $proxyCountry.Name -Force
            $createResponse | Add-Member -NotePropertyName checked_proxy_country_code -NotePropertyValue $proxyCountry.Code -Force
        }
        else {
            $errorText = $checkResponse | ConvertTo-Json -Depth 10 -Compress
            Write-Warning "Proxy connection check failed; keeping the probe profile as-is: $errorText"
        }
    }
    catch {
        Write-Warning "Proxy connection check or country-based re-creation failed: $_"
    }
}

$createResponse | Add-Member -NotePropertyName profile_name -NotePropertyValue $profileName -Force
$createResponse | Add-Member -NotePropertyName selected_os -NotePropertyValue $selectedConfig.Os -Force
$createResponse | ConvertTo-Json -Depth 10