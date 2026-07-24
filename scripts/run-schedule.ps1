param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateRange(1, 2147483647)]
    [int]$ScheduleNumber,
    [datetime]$From = (Get-Date).Date,
    [datetime]$To = (Get-Date).Date.AddDays(1),
    [string]$ScheduleApiUrl = "https://portal.bettingpair.com/api/clicks/schedule",
    [string]$ScheduleFetcherPath,
    [string]$ApiUrl = "http://localhost:25432",
    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt"),
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [ValidateRange(1, 86400)]
    [int]$OpenDurationSeconds = 120,
    [ValidateRange(1, 3600)]
    [int]$PreparationRetrySeconds = 10,
    [switch]$DryRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CreateProfileArgs
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScheduleFetcherPath)) {
    $ScheduleFetcherPath = Join-Path $repoRoot "bin\bettingpair-fetch.exe"
}

function Get-RequiredUserEnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, "User")
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "User environment variable '$Name' is not set."
    }
    return $value
}

function Invoke-ScheduleApiRequest {
    param([string]$FetcherPath, [string]$Url, [string]$FromDate, [string]$ToDate)

    if (-not (Test-Path -LiteralPath $FetcherPath -PathType Leaf)) {
        throw "Schedule fetcher not found at '$FetcherPath'."
    }

    $values = @{
        BETTINGPAIR_API_KEY           = Get-RequiredUserEnvironmentVariable -Name "BETTINGPAIR_API_KEY"
        BETTINGPAIR_CLOUDFLARE_ID     = Get-RequiredUserEnvironmentVariable -Name "BETTINGPAIR_CLOUDFLARE_ID"
        BETTINGPAIR_CLOUDFLARE_SECRET = Get-RequiredUserEnvironmentVariable -Name "BETTINGPAIR_CLOUDFLARE_SECRET"
    }
    $original = @{}
    try {
        foreach ($entry in $values.GetEnumerator()) {
            $original[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
        }
        $output = & $FetcherPath --from $FromDate --to $ToDate --url $Url 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($entry in $original.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
        }
    }

    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "Schedule fetcher failed with exit code ${exitCode}: $text"
    }
    return $text | ConvertFrom-Json -ErrorAction Stop
}

function ConvertTo-ParameterHashtable {
    param([string[]]$Arguments)

    $parameters = @{}
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ($Arguments[$index] -notmatch '^-{1,2}(.+)$') {
            throw "Unexpected profile argument '$($Arguments[$index])'. Expected -Name [value]."
        }
        $name = $Matches[1]
        $values = @()
        while ($index + 1 -lt $Arguments.Count -and $Arguments[$index + 1] -notmatch '^-') {
            $values += $Arguments[++$index]
        }
        $parameters[$name] = if ($values.Count -eq 0) { $true } elseif ($values.Count -eq 1) { $values[0] } else { $values }
    }
    return $parameters
}

function ConvertFrom-ScriptJsonOutput {
    param([object[]]$Output)

    $text = ($Output | Out-String).Trim()
    $jsonStart = $text.IndexOf("{")
    if ($jsonStart -lt 0) { throw "Profile creation script did not return JSON output." }
    return $text.Substring($jsonStart) | ConvertFrom-Json -ErrorAction Stop
}

function Get-CreatedProfileId {
    param([object]$Response)

    foreach ($candidate in @($Response.data.profile_id, $Response.data.profileId, $Response.profile_id, $Response.profileId, $Response.id)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { return [string]$candidate }
    }
    throw "Profile creation succeeded, but no profile id was returned."
}

function Stop-ProfileIfNeeded {
    param([string]$ProfileId)

    if ([string]::IsNullOrWhiteSpace($ProfileId)) { return }
    $lastError = $null
    foreach ($endpoint in @("profile/stop", "profile/close")) {
        try {
            $response = Invoke-RestMethod -Uri "$ApiUrl/$endpoint/$ProfileId" -Method Get -TimeoutSec 30
            if (-not $response -or -not ($response.PSObject.Properties.Name -contains "code") -or $response.code -eq 0) { return }
            $lastError = $response | ConvertTo-Json -Depth 10 -Compress
        }
        catch { $lastError = $_ }
    }
    throw "Failed to close profile '$ProfileId': $lastError"
}

function Remove-Profile {
    param([string]$ProfileId)

    if ([string]::IsNullOrWhiteSpace($ProfileId)) { return }
    $command = @{ ApiUrl = $ApiUrl; StartupTimeoutSeconds = $StartupTimeoutSeconds; Id = $ProfileId }
    if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) { $command.UndetectablePath = $UndetectablePath }
    & (Join-Path $PSScriptRoot "delete-undetectable-profiles.ps1") @command
    if (-not $?) { throw "Delete profile script failed." }
}

function Invoke-ScheduledEvent {
    param([object]$Event)

    $profileId = $null
    $profileStarted = $false
    try {
        while ([string]::IsNullOrWhiteSpace($profileId)) {
            try {
                Write-Host "Preparing $($Event.Click.name)/$($Event.Click.country) profile for $($Event.Click.date) $($Event.Click.time)." -ForegroundColor Cyan
                $createCommand = @{
                    ApiUrl                = $ApiUrl
                    StartupTimeoutSeconds = $StartupTimeoutSeconds
                    CountryCode           = ([string]$Event.Click.country).ToUpperInvariant()
                    Tags                  = @("random", "schedule", "schedule-$ScheduleNumber")
                }
                if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) { $createCommand.UndetectablePath = $UndetectablePath }
                foreach ($parameter in (ConvertTo-ParameterHashtable -Arguments $CreateProfileArgs).GetEnumerator()) {
                    $createCommand[$parameter.Key] = $parameter.Value
                }
                $createCommand.CountryCode = ([string]$Event.Click.country).ToUpperInvariant()

                $createOutput = & (Join-Path $PSScriptRoot "new-random-undetectable-profile.ps1") @createCommand
                if (-not $?) { throw "Profile creation script failed." }
                $createResponse = ConvertFrom-ScriptJsonOutput -Output $createOutput
                $profileId = Get-CreatedProfileId -Response $createResponse
                $profileName = if ([string]::IsNullOrWhiteSpace([string]$createResponse.profile_name)) { $profileId } else { [string]$createResponse.profile_name }
            }
            catch {
                $remainingSeconds = ($Event.ScheduledUtc - [datetime]::UtcNow).TotalSeconds
                if ($remainingSeconds -le 0) { throw }
                $retryDelay = [math]::Min($PreparationRetrySeconds, [math]::Ceiling($remainingSeconds))
                Write-Warning "Profile preparation failed; retrying in $retryDelay seconds: $_"
                Start-Sleep -Seconds $retryDelay
            }
        }

        $delay = $Event.ScheduledUtc - [datetime]::UtcNow
        if ($delay.TotalMilliseconds -gt 0) {
            Write-Host "Profile '$profileName' is ready; waiting until $($Event.Click.date) $($Event.Click.time) $($response.timezone)." -ForegroundColor Green
            Start-Sleep -Milliseconds ([math]::Ceiling($delay.TotalMilliseconds))
        }
        elseif ($delay.TotalMinutes -lt -1) {
            Write-Warning "Launching $([math]::Round(-$delay.TotalMinutes, 1)) minutes late."
        }

        $openCommand = @{
            ApiUrl                = $ApiUrl
            ProfileStatePath      = $ProfileStatePath
            StartupTimeoutSeconds = $StartupTimeoutSeconds
            ProfileId             = $profileId
            StartPages            = @([string]$Event.Click.url)
        }
        if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) { $openCommand.UndetectablePath = $UndetectablePath }
        & (Join-Path $PSScriptRoot "open-undetectable.ps1") @openCommand
        if (-not $?) { throw "Profile launch script failed." }
        $profileStarted = $true

        & (Join-Path $PSScriptRoot "focus-undetectable-window.ps1") -WindowTitle $profileName -ProfileStatePath $ProfileStatePath
        if (-not $?) { throw "Profile window could not be focused." }
        Write-Host "Keeping '$profileName' open for $OpenDurationSeconds seconds." -ForegroundColor Cyan
        Start-Sleep -Seconds $OpenDurationSeconds
    }
    finally {
        if ($profileStarted) {
            try { Stop-ProfileIfNeeded -ProfileId $profileId } catch { Write-Warning $_ }
        }
        try { Remove-Profile -ProfileId $profileId } catch { Write-Warning $_ }
        Remove-Item -LiteralPath $ProfileStatePath -Force -ErrorAction SilentlyContinue
    }
}

if ($From.Date -gt $To.Date) { throw "-From cannot be later than -To." }
$response = Invoke-ScheduleApiRequest -FetcherPath $ScheduleFetcherPath -Url $ScheduleApiUrl -FromDate $From.ToString("yyyy-MM-dd") -ToDate $To.ToString("yyyy-MM-dd")
if ($null -eq $response.schedules) { throw "The API did not return the expected 'schedules' collection." }
$schedule = @($response.schedules | Where-Object { [int]$_.pc -eq $ScheduleNumber })
if ($schedule.Count -ne 1) {
    $available = @($response.schedules | ForEach-Object { $_.pc }) -join ", "
    throw "Schedule $ScheduleNumber was not found. Available schedule numbers: $available"
}

$timezone = [TimeZoneInfo]::FindSystemTimeZoneById([string]$response.timezone)
$events = @($schedule[0].clicks | ForEach-Object {
        $localTime = [datetime]::ParseExact("$($_.date) $($_.time)", "yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
        [PSCustomObject]@{ Click = $_; ScheduledUtc = [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($localTime, [DateTimeKind]::Unspecified), $timezone) }
    } | Sort-Object ScheduledUtc)
if ($events.Count -eq 0) { throw "Schedule $ScheduleNumber contains no events in the requested range." }

$minimumGap = [int]$response.machineGapMin
for ($index = 1; $index -lt $events.Count; $index++) {
    $gap = ($events[$index].ScheduledUtc - $events[$index - 1].ScheduledUtc).TotalMinutes
    if ($gap -lt $minimumGap) { throw "Schedule $ScheduleNumber has a $gap-minute conflict at $($events[$index].Click.date) $($events[$index].Click.time)." }
}

$remaining = @($events | Where-Object { $_.ScheduledUtc -gt [datetime]::UtcNow })
Write-Host "Schedule ${ScheduleNumber}: $($events.Count) events, $($remaining.Count) remaining, timezone $($response.timezone)." -ForegroundColor Cyan
if ($DryRun) {
    $remaining | ForEach-Object { [PSCustomObject]@{ At = "$($_.Click.date) $($_.Click.time)"; Market = $_.Click.name; Country = $_.Click.country; Url = $_.Click.url } } | Format-Table -AutoSize
    exit 0
}

$failures = 0
foreach ($event in $remaining) {
    try {
        Invoke-ScheduledEvent -Event $event
    }
    catch {
        $failures++
        Write-Warning "Scheduled event failed; continuing: $_"
    }
}

Write-Host "Schedule $ScheduleNumber is complete. Events attempted: $($remaining.Count); failures: $failures." -ForegroundColor $(if ($failures) { "Yellow" } else { "Green" })
if ($failures) { exit 1 }