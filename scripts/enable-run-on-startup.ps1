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

$TaskName = "Regxorder Random Undetectable Playback Intervals"
$intervalScriptPath = Join-Path $PSScriptRoot "run-random-undetectable-playback-intervals.ps1"

if (-not (Test-Path -LiteralPath $intervalScriptPath)) {
    throw "Intervals script not found at '$intervalScriptPath'."
}

$minimumSeconds = Read-IntervalSeconds -Prompt "Minimum time between runs (minutes, or hh:mm:ss)"
$maximumSeconds = Read-IntervalSeconds -Prompt "Maximum time between runs (minutes, or hh:mm:ss)"

if ($minimumSeconds -gt $maximumSeconds) {
    throw "Minimum interval cannot be greater than maximum interval."
}

$runNow = Read-YesNo -Prompt "Start with a playback run immediately at logon? Y/N"

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$powershellPath = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
Select-Object -First 1 -ExpandProperty Source
if ([string]::IsNullOrWhiteSpace($powershellPath)) {
    $powershellPath = Get-Command powershell.exe -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
}

$argumentList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$intervalScriptPath`"",
    "-MinimumInterval", $minimumSeconds.ToString(),
    "-MaximumInterval", $maximumSeconds.ToString(),
    "-RunNow:`$$($runNow.ToString().ToLowerInvariant())"
)

$action = New-ScheduledTaskAction -Execute $powershellPath -Argument ($argumentList -join ' ')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Description "Runs random undetectable playback intervals when $currentUser signs in." -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "✓ Playback intervals enabled at logon." -ForegroundColor Green
Write-Host "  Task: $TaskName" -ForegroundColor Gray
Write-Host "  Interval: $minimumSeconds–$maximumSeconds seconds" -ForegroundColor Gray
