param (
    [string]$MinimumInterval,
    [string]$MaximumInterval,
    [switch]$RunNow,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PlaybackArgs
)

$ErrorActionPreference = "Stop"

function ConvertTo-IntervalSeconds {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed -match '^\d+$') {
        return [int]$trimmed * 60
    }

    $timeSpan = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse($trimmed, [ref]$timeSpan) -and $timeSpan.TotalSeconds -ge 1) {
        return [int][Math]::Ceiling($timeSpan.TotalSeconds)
    }

    throw "Enter minutes as a number, or a time like 00:30:00."
}

function Read-IntervalSeconds {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    while ($true) {
        try {
            return ConvertTo-IntervalSeconds -Value (Read-Host $Prompt)
        }
        catch {
            Write-Host "  $_" -ForegroundColor Red
        }
    }
}

function Read-YesNo {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host "  Please answer Y or N." -ForegroundColor Red
    }
}

function Format-Interval {
    param([Parameter(Mandatory = $true)][int]$Seconds)

    $timeSpan = [TimeSpan]::FromSeconds($Seconds)
    if ($timeSpan.TotalDays -ge 1) {
        return "{0}d {1:00}:{2:00}:{3:00}" -f [int]$timeSpan.TotalDays, $timeSpan.Hours, $timeSpan.Minutes, $timeSpan.Seconds
    }

    return "{0:00}:{1:00}:{2:00}" -f [int]$timeSpan.TotalHours, $timeSpan.Minutes, $timeSpan.Seconds
}

function Wait-WithCountdown {
    param([Parameter(Mandatory = $true)][int]$Seconds)

    for ($remaining = $Seconds; $remaining -gt 0; $remaining--) {
        Write-Host -NoNewline "`rNext run in $(Format-Interval -Seconds $remaining)   "
        Start-Sleep -Seconds 1
    }

    Write-Host "`rNext run in 00:00:00   "
}

function Invoke-Playback {
    $scriptPath = Join-Path $PSScriptRoot "run-random-undetectable-playback.ps1"
    $scriptArgs = @($PlaybackArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Write-Host "Starting playback run at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')." -ForegroundColor Cyan
    & $scriptPath @scriptArgs
    $runExitCode = $LASTEXITCODE
    if ($runExitCode -ne 0) {
        Write-Host "Playback run exited with code $runExitCode." -ForegroundColor Red
    }
    else {
        Write-Host "Playback run completed." -ForegroundColor Green
    }
}

$minimumSeconds = if ($PSBoundParameters.ContainsKey('MinimumInterval')) {
    ConvertTo-IntervalSeconds -Value $MinimumInterval
}
else {
    Read-IntervalSeconds -Prompt "Minimum time between runs (minutes, or hh:mm:ss)"
}

$maximumSeconds = if ($PSBoundParameters.ContainsKey('MaximumInterval')) {
    ConvertTo-IntervalSeconds -Value $MaximumInterval
}
else {
    Read-IntervalSeconds -Prompt "Maximum time between runs (minutes, or hh:mm:ss)"
}

if ($minimumSeconds -gt $maximumSeconds) {
    throw "Minimum interval cannot be greater than maximum interval."
}

$runNow = if ($PSBoundParameters.ContainsKey('RunNow')) {
    $RunNow.IsPresent
}
else {
    Read-YesNo -Prompt "Start with a playback run now? Y/N"
}

Write-Host "Press Ctrl+C to stop." -ForegroundColor Yellow

while ($true) {
    if ($runNow) {
        Invoke-Playback
        $runNow = $false
    }

    $delaySeconds = if ($minimumSeconds -eq $maximumSeconds) {
        $minimumSeconds
    }
    else {
        Get-Random -Minimum $minimumSeconds -Maximum ($maximumSeconds + 1)
    }

    $nextRun = (Get-Date).AddSeconds($delaySeconds)
    Write-Host "Next playback run scheduled for $($nextRun.ToString('yyyy-MM-dd HH:mm:ss'))." -ForegroundColor Cyan
    Wait-WithCountdown -Seconds $delaySeconds
    Invoke-Playback
}