param (
    [datetime]$From = (Get-Date).Date,
    [datetime]$To = (Get-Date).Date,
    [ValidatePattern("^[A-Za-z]{2}$")]
    [string]$CountryCode,
    [string]$ScheduleApiUrl = "https://portal.bettingpair.com/api/clicks/schedule",
    [string]$ApiUrl = "http://localhost:25432",
    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt"),
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [switch]$ScheduleOnly,
    [switch]$DryRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CreateProfileArgs
)

$ErrorActionPreference = "Stop"

function Get-RequiredUserEnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, "User")
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "User environment variable '$Name' is not set."
    }

    return $value
}

function ConvertFrom-ScriptJsonOutput {
    param([object[]]$Output)

    $text = ($Output | Out-String).Trim()
    $jsonStart = $text.IndexOf("{")
    if ($jsonStart -lt 0) {
        throw "Profile creation script did not return JSON output."
    }

    return $text.Substring($jsonStart) | ConvertFrom-Json -ErrorAction Stop
}

function Get-CreatedProfileId {
    param([Parameter(Mandatory = $true)][object]$CreateResponse)

    foreach ($candidate in @(
            $CreateResponse.data.profile_id,
            $CreateResponse.data.profileId,
            $CreateResponse.profile_id,
            $CreateResponse.profileId,
            $CreateResponse.id
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }

    throw "Profile creation succeeded, but no profile id was returned."
}

function ConvertTo-ParameterHashtable {
    param([string[]]$Arguments)

    $parameters = @{}
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($argument -notmatch '^-{1,2}(.+)$') {
            throw "Unexpected profile argument '$argument'. Expected -Name [value]."
        }

        $name = $Matches[1]
        $values = @()
        while ($index + 1 -lt $Arguments.Count -and $Arguments[$index + 1] -notmatch '^-') {
            $index++
            $values += $Arguments[$index]
        }

        $parameters[$name] = if ($values.Count -eq 0) { $true } elseif ($values.Count -eq 1) { $values[0] } else { $values }
    }

    return $parameters
}

$fromDate = $From.Date
$toDate = $To.Date
if ($fromDate -gt $toDate) {
    throw "-From cannot be later than -To."
}

$headers = @{
    "x-ads-token"             = Get-RequiredUserEnvironmentVariable -Name "BETTINGPAIR_API_KEY"
    "CF-Access-Client-Id"     = Get-RequiredUserEnvironmentVariable -Name "BETTINGPAIR_CLOUDFLARE_ID"
    "CF-Access-Client-Secret" = Get-RequiredUserEnvironmentVariable -Name "BETTINGPAIR_CLOUDFLARE_SECRET"
    Accept                    = "application/json"
}
$scheduleUri = "${ScheduleApiUrl}?from=$($fromDate.ToString('yyyy-MM-dd'))&to=$($toDate.ToString('yyyy-MM-dd'))"
$schedule = Invoke-RestMethod -Uri $scheduleUri -Method Get -Headers $headers -TimeoutSec 60

$requestedCountryCode = if ([string]::IsNullOrWhiteSpace($CountryCode)) { $null } else { $CountryCode.ToUpperInvariant() }
$markets = @($schedule.schedule | Where-Object {
        $_.country -match '^[A-Za-z]{2}$' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.url) -and
        @($_.events | Where-Object { @($_.times).Count -gt 0 }).Count -gt 0 -and
        ([string]::IsNullOrWhiteSpace($requestedCountryCode) -or $_.country -ieq $requestedCountryCode)
    })

if ($markets.Count -eq 0) {
    $countryMessage = if ($requestedCountryCode) { " for country '$requestedCountryCode'" } else { "" }
    throw "The schedule contains no markets with events$countryMessage between $($fromDate.ToString('yyyy-MM-dd')) and $($toDate.ToString('yyyy-MM-dd'))."
}

$market = $markets | Get-Random
$marketCountryCode = ([string]$market.country).ToUpperInvariant()
$marketUrl = [string]$market.url
$marketUri = $null
if (-not [uri]::TryCreate($marketUrl, [System.UriKind]::Absolute, [ref]$marketUri) -or $marketUri.Scheme -notin @("http", "https")) {
    throw "Schedule URL '$marketUrl' is not a valid HTTP or HTTPS URL."
}

$eventCount = (@($market.events | ForEach-Object { @($_.times).Count }) | Measure-Object -Sum).Sum
Write-Host "Selected '$($market.name)' in $marketCountryCode with $eventCount scheduled events; start page: $marketUrl" -ForegroundColor Cyan

if ($ScheduleOnly) {
    [PSCustomObject]@{
        Market    = $market.name
        Country   = $marketCountryCode
        StartPage = $marketUrl
        Events    = $eventCount
        From      = $fromDate.ToString("yyyy-MM-dd")
        To        = $toDate.ToString("yyyy-MM-dd")
        Timezone  = $schedule.timezone
    } | ConvertTo-Json
    exit 0
}

$createCommand = @{
    ApiUrl                = $ApiUrl
    StartupTimeoutSeconds = $StartupTimeoutSeconds
    Tags                  = @("random", "schedule")
    DryRun                = $DryRun
}
if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
    $createCommand.UndetectablePath = $UndetectablePath
}
if ($CreateProfileArgs) {
    foreach ($parameter in (ConvertTo-ParameterHashtable -Arguments $CreateProfileArgs).GetEnumerator()) {
        $createCommand[$parameter.Key] = $parameter.Value
    }
}
$createCommand.CountryCode = $marketCountryCode
$createCommand.StartPage = $marketUrl

$createOutput = & (Join-Path $PSScriptRoot "new-random-undetectable-profile.ps1") @createCommand
if (-not $?) {
    throw "Profile creation script failed."
}
if ($DryRun) {
    $createOutput
    exit 0
}

$createResponse = ConvertFrom-ScriptJsonOutput -Output $createOutput
$profileId = Get-CreatedProfileId -CreateResponse $createResponse
$profileName = [string]$createResponse.profile_name

$openCommand = @{
    ApiUrl                = $ApiUrl
    ProfileStatePath      = $ProfileStatePath
    StartupTimeoutSeconds = $StartupTimeoutSeconds
    ProfileId             = $profileId
}
if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
    $openCommand.UndetectablePath = $UndetectablePath
}

& (Join-Path $PSScriptRoot "open-undetectable.ps1") @openCommand
if (-not $?) {
    throw "Profile launch script failed."
}

& (Join-Path $PSScriptRoot "focus-undetectable-window.ps1") -WindowTitle $profileName -ProfileStatePath $ProfileStatePath
if (-not $?) {
    throw "Profile window could not be maximized and focused."
}

[PSCustomObject]@{
    ProfileId   = $profileId
    ProfileName = $profileName
    Market      = $market.name
    Country     = $marketCountryCode
    StartPage   = $marketUrl
    From        = $fromDate.ToString("yyyy-MM-dd")
    To          = $toDate.ToString("yyyy-MM-dd")
} | ConvertTo-Json