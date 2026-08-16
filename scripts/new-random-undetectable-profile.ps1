param (
    [string]$ApiUrl = "http://localhost:25325",
    [string]$UndetectablePath,
    [Nullable[int]]$StartupTimeoutSeconds,
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
    [string]$ProxyNamePattern,
    [Parameter(DontShow)]
    [ValidatePattern("^[A-Za-z]{2}$")]
    [string]$ExpectedProxyCountryCode,
    [string]$Folder = "Random",
    [string]$Group,
    [string[]]$Tags = @("random"),
    [string]$Notes,
    [string]$CookiesPath,
    [switch]$SkipProxyCheck,
    [switch]$DryRun,
    [int]$ConfigsTimeoutSeconds = 60
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
    AE = "ar-AE"; AR = "es-AR"; AU = "en-AU"; BR = "pt-BR"; CA = "en-CA"
    BG = "bg-BG"; BY = "be-BY"; CH = "de-CH"; CY = "el-CY"; CZ = "cs-CZ"
    CL = "es-CL"; CN = "zh-CN"; CO = "es-CO"; CR = "es-CR"; DO = "es-DO"
    DE = "de-DE"; DK = "da-DK"; EE = "et-EE"; ES = "es-ES"; FI = "fi-FI"
    EG = "ar-EG"; HK = "zh-HK"; ID = "id-ID"; IL = "he-IL"; IN = "hi-IN"
    FR = "fr-FR"; GB = "en-GB"; GR = "el-GR"; HR = "hr-HR"; HU = "hu-HU"
    IE = "en-IE"; IS = "is-IS"; IT = "it-IT"; LI = "de-LI"; LT = "lt-LT"
    JP = "ja-JP"; KR = "ko-KR"; MA = "ar-MA"; MX = "es-MX"; MY = "ms-MY"
    LU = "lb-LU"; LV = "lv-LV"; MC = "fr-MC"; MD = "ro-MD"; ME = "sr-Latn-ME"
    MK = "mk-MK"; MT = "mt-MT"; NL = "nl-NL"; NO = "nb-NO"; PL = "pl-PL"
    NG = "en-NG"; NZ = "en-NZ"; PE = "es-PE"; PH = "en-PH"; PK = "ur-PK"
    PT = "pt-PT"; RO = "ro-RO"; RS = "sr-Latn-RS"; SE = "sv-SE"; SI = "sl-SI"
    SK = "sk-SK"; SM = "it-SM"; TR = "tr-TR"; UA = "uk-UA"; VA = "it-VA"
    SA = "ar-SA"; SG = "en-SG"; TH = "th-TH"; TW = "zh-TW"; US = "en-US"
    UY = "es-UY"; VE = "es-VE"; VN = "vi-VN"; ZA = "en-ZA"
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

function Resolve-CountryLanguage {
    param([Parameter(Mandatory = $true)][string]$CountryCode)

    $normalizedCode = $CountryCode.ToUpperInvariant()
    $mappedLanguage = $countryCodeLanguageMap[$normalizedCode]
    if (-not [string]::IsNullOrWhiteSpace($mappedLanguage)) {
        return $mappedLanguage
    }

    $culture = [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures) |
    Where-Object {
        try { ([System.Globalization.RegionInfo]::new($_.Name)).TwoLetterISORegionName -eq $normalizedCode }
        catch { $false }
    } |
    Sort-Object Name |
    Select-Object -First 1

    if ($null -ne $culture) {
        return $culture.Name
    }
    return $null
}

function Test-ProxyNamePattern {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    try {
        return $Name -match $Pattern
    }
    catch {
        throw "Invalid proxy name pattern '$Pattern': $_"
    }
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

function Get-SavedProxyCountry {
    param([Parameter(Mandatory = $true)][object]$Proxy)

    if ([string]::IsNullOrWhiteSpace($Proxy.Host) -or [string]::IsNullOrWhiteSpace($Proxy.Port)) {
        throw "Saved proxy '$($Proxy.Name)' does not expose a host and port for geolocation lookup."
    }

    if ([string]$Proxy.Type -notmatch '^(?i:https?)$') {
        throw "Saved proxy '$($Proxy.Name)' has unsupported type '$($Proxy.Type)'; only HTTP proxies support automatic geolocation lookup."
    }

    $proxyUri = "http://$($Proxy.Host):$($Proxy.Port)"
    $request = @{ Uri = "https://ipwho.is/"; Method = "Get"; Proxy = $proxyUri; TimeoutSec = 30 }
    if (-not [string]::IsNullOrWhiteSpace($Proxy.Login)) {
        $request.ProxyCredential = [System.Management.Automation.PSCredential]::new(
            $Proxy.Login,
            (ConvertTo-SecureString -String $Proxy.Password -AsPlainText -Force)
        )
    }

    try {
        $response = Invoke-RestMethod @request
    }
    catch {
        throw "Failed to determine the country for saved proxy '$($Proxy.Name)': $_"
    }
    if (-not $response.success -or [string]::IsNullOrWhiteSpace($response.country_code)) {
        throw "Country lookup through saved proxy '$($Proxy.Name)' failed."
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
        [int]$TimeoutSeconds = 60
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

$configsResponse = Get-UndetectableConfigsResponse -ApiUrl $ApiUrl -TimeoutSeconds $ConfigsTimeoutSeconds
if ($configsResponse.code -ne 0 -or -not $configsResponse.data -or $configsResponse.data.PSObject.Properties.Count -eq 0) {
    throw "Failed to fetch Undetectable configurations from $ApiUrl/configslist after waiting up to $ConfigsTimeoutSeconds seconds."
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

$selectedProxy = $null
$availableProxies = @()
try {
    $proxiesResponse = Invoke-RestMethod -Uri "$ApiUrl/proxies/list" -Method Get -TimeoutSec 20
    if ($proxiesResponse.code -eq 0 -and $proxiesResponse.data) {
        foreach ($proxyId in $proxiesResponse.data.PSObject.Properties.Name) {
            $proxyEntry = $proxiesResponse.data.$proxyId
            $availableProxies += [PSCustomObject]@{
                Id       = $proxyId
                Name     = $proxyEntry.name
                Type     = $proxyEntry.type
                Host     = $proxyEntry.host
                Port     = $proxyEntry.port
                Login    = $proxyEntry.login
                Password = $proxyEntry.password
            }
        }
    }
}
catch {
    Write-Warning "Could not query proxies from $ApiUrl/proxies/list: $_"
}

$eligibleProxies = $availableProxies
if (-not [string]::IsNullOrWhiteSpace($ProxyNamePattern)) {
    $eligibleProxies = @($availableProxies | Where-Object { Test-ProxyNamePattern -Name $_.Name -Pattern $ProxyNamePattern })
    if ($eligibleProxies.Count -eq 0) {
        throw "No saved proxy name matched pattern '$ProxyNamePattern'."
    }
}

if ($eligibleProxies.Count -gt 0) {
    $selectedProxy = $eligibleProxies | Get-Random
    Write-Host "Selected proxy '$($selectedProxy.Name)'." -ForegroundColor Cyan
}
else {
    Write-Warning "No proxies found in the proxy manager; creating profile without an auto-selected proxy."
}

$profileCountry = $null
if ($null -ne $selectedProxy) {
    $profileCountry = Get-SavedProxyCountry -Proxy $selectedProxy
    Write-Host "Selected proxy country: $($profileCountry.Name) ($($profileCountry.Code))." -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($ExpectedProxyCountryCode) -and $profileCountry.Code -ne $ExpectedProxyCountryCode.ToUpperInvariant()) {
        throw "Selected proxy '$($selectedProxy.Name)' resolves to $($profileCountry.Code), expected $($ExpectedProxyCountryCode.ToUpperInvariant())."
    }
}

$languageValue = if ($null -ne $Languages -and $Languages.Count -gt 0) { $Languages -join ", " } else { "en-US, en" }
$profileName = $profileTimestamp
if ($null -ne $profileCountry) {
    $profileName = "$($profileCountry.Code)_$profileTimestamp"
    if ($null -eq $Languages -or $Languages.Count -eq 0) {
        $countryLanguage = Resolve-CountryLanguage -CountryCode $profileCountry.Code
        if (-not [string]::IsNullOrWhiteSpace($countryLanguage)) {
            $languageValue = Add-EnglishLanguage -Language $countryLanguage
        }
    }
}

if ([string]::IsNullOrWhiteSpace($CookiesPath)) {
    $CookiesPath = Join-Path (Split-Path -Parent $PSScriptRoot) "cookies"
}
$cookieResult = if ($null -ne $profileCountry) {
    Get-RandomCountryCookies -CookiesRoot $CookiesPath -CountryName $profileCountry.Name
}
else {
    $null
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
Add-PayloadValue -Payload $payload -Name "proxy" -Value $selectedProxy.Id
Add-PayloadValue -Payload $payload -Name "folder" -Value $Folder
Add-PayloadValue -Payload $payload -Name "group" -Value $Group
Add-PayloadValue -Payload $payload -Name "tags" -Value $Tags
Add-PayloadValue -Payload $payload -Name "notes" -Value $Notes
if ($null -ne $cookieResult) {
    $payload["cookies"] = $cookieResult.Cookies
    Write-Host "Loaded $($cookieResult.Cookies.Count) cookies for '$($cookieResult.Country)' from '$($cookieResult.File)'." -ForegroundColor Cyan
}

$payloadJson = $payload | ConvertTo-Json -Depth 10

Write-Host "Selected config $($selectedConfig.Id): $($selectedConfig.Os), $($selectedConfig.Browser), $($selectedConfig.Screen)" -ForegroundColor Cyan

if ($DryRun) {
    Write-Output $payloadJson
    return
}

$createResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/create" -Method Post -ContentType "application/json" -Body $payloadJson -TimeoutSec 60
if ($createResponse.code -ne 0) {
    if ($createResponse.data.error -like "*permissions to create profiles*") {
        throw "Undetectable rejected /profile/create before profile settings were applied. A minimal documented request with only a name returns the same permission error, so this is not caused by configid/type/cpu/memory/language. Check Undetectable role/plan/API permissions, or contact Undetectable support with: POST /profile/create => '$($createResponse.data.error)'."
    }

    $errorText = $createResponse | ConvertTo-Json -Depth 10 -Compress
    throw "Profile creation failed: $errorText"
}

Write-Host "Created profile '$profileName', language '$languageValue'." -ForegroundColor Green
$profileId = $createResponse.data.profile_id
if (-not [string]::IsNullOrWhiteSpace($profileId)) {
    Write-Host "Profile ID: $profileId" -ForegroundColor Green
}

if (-not $SkipProxyCheck -and $null -ne $selectedProxy -and -not [string]::IsNullOrWhiteSpace($profileId)) {
    $profileCountryMismatch = $null
    try {
        $checkResponse = Invoke-RestMethod -Uri "$ApiUrl/profile/checkconnection/$profileId" -Method Get -TimeoutSec 60
        if ($checkResponse.code -eq 0 -and -not [string]::IsNullOrWhiteSpace($checkResponse.data.ip)) {
            $verifiedCountry = Get-ProxyCountry -IpAddress $checkResponse.data.ip
            if ($null -ne $profileCountry -and $verifiedCountry.Code -ne $profileCountry.Code) {
                $profileCountryMismatch = "Created profile proxy resolved to $($verifiedCountry.Code), but resolved to $($profileCountry.Code) before creation."
            }
            else {
                Write-Host "Verified profile proxy: $($checkResponse.data.ip) ($($verifiedCountry.Code))." -ForegroundColor Green
            }

            $createResponse | Add-Member -NotePropertyName checked_proxy_ip -NotePropertyValue $checkResponse.data.ip -Force
            $createResponse | Add-Member -NotePropertyName checked_proxy_country -NotePropertyValue $verifiedCountry.Name -Force
            $createResponse | Add-Member -NotePropertyName checked_proxy_country_code -NotePropertyValue $verifiedCountry.Code -Force
        }
        else {
            $errorText = $checkResponse | ConvertTo-Json -Depth 10 -Compress
            Write-Warning "Profile proxy verification failed; continuing with the created profile: $errorText"
        }
    }
    catch {
        Write-Warning "Profile proxy verification failed; continuing with the created profile: $_"
    }
    if (-not [string]::IsNullOrWhiteSpace($profileCountryMismatch)) {
        throw $profileCountryMismatch
    }
}

$createResponse | Add-Member -NotePropertyName profile_name -NotePropertyValue $profileName -Force
$createResponse | Add-Member -NotePropertyName selected_os -NotePropertyValue $selectedConfig.Os -Force
if ($null -ne $selectedProxy) {
    $createResponse | Add-Member -NotePropertyName selected_proxy_name -NotePropertyValue $selectedProxy.Name -Force
}
if ($null -ne $profileCountry) {
    $createResponse | Add-Member -NotePropertyName selected_proxy_country -NotePropertyValue $profileCountry.Name -Force
    $createResponse | Add-Member -NotePropertyName selected_proxy_country_code -NotePropertyValue $profileCountry.Code -Force
}
$createResponse | ConvertTo-Json -Depth 10