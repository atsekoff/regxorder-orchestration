param (
    [string]$MinimumInterval = "30",
    [string]$MaximumInterval = "60",
    [switch]$RunNow,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PlaybackArgs
)

$ErrorActionPreference = "Stop"

function ConvertTo-TaskArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\\"') + '"'
}

$TaskName = "Regxorder Random Undetectable Playback Intervals"
$intervalScriptPath = Join-Path $PSScriptRoot "run-random-undetectable-playback-intervals.ps1"
if (-not (Test-Path -LiteralPath $intervalScriptPath)) {
    throw "Intervals script not found at '$intervalScriptPath'."
}

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
    "-WindowStyle", "Hidden",
    "-File", $intervalScriptPath,
    "-MinimumInterval", $MinimumInterval,
    "-MaximumInterval", $MaximumInterval,
    "-RunNow:$($RunNow.IsPresent.ToString().ToLowerInvariant())"
)

if ($PlaybackArgs) {
    $argumentList += @($PlaybackArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$action = New-ScheduledTaskAction -Execute $powershellPath -Argument (($argumentList | ForEach-Object {
            ConvertTo-TaskArgument -Value ([string]$_)
        }) -join ' ')

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Description "Runs random undetectable playback intervals when $currentUser signs in." -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered for $currentUser logon." -ForegroundColor Green