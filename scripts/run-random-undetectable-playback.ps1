param (
    [string]$ApiUrl = "http://localhost:25432",
    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt"),
    [string]$UndetectablePath,
    [int]$StartupTimeoutSeconds = 60,
    [string]$SessionRoot,
    [string]$SessionPath,
    [switch]$KeepProfileOnFailure,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CreateProfileArgs
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\device.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SessionRoot)) {
    $SessionRoot = Join-Path $repoRoot "main-sessions"
}

$profileId = $null
$profileName = $null
$profileStarted = $false
$exitCode = 0

function Get-CreatedProfileId {
    param([Parameter(Mandatory = $true)][object]$CreateResponse)

    $candidates = @(
        $CreateResponse.data.profile_id,
        $CreateResponse.data.profileId,
        $CreateResponse.profile_id,
        $CreateResponse.profileId,
        $CreateResponse.id
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }

    throw "Profile creation succeeded, but no profile id was returned."
}

function ConvertFrom-ScriptJsonOutput {
    param([object[]]$Output)

    $text = ($Output | Out-String).Trim()
    $jsonStart = $text.IndexOf("{")
    if ($jsonStart -lt 0) {
        throw "Script did not return JSON output."
    }

    return $text.Substring($jsonStart) | ConvertFrom-Json -ErrorAction Stop
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

        if ($values.Count -eq 0) {
            $parameters[$name] = $true
        }
        elseif ($values.Count -eq 1) {
            $parameters[$name] = $values[0]
        }
        else {
            $parameters[$name] = $values
        }
    }

    return $parameters
}

function Resolve-PlaybackSession {
    param(
        [string]$Device,
        [string]$Root,
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) {
            throw "Session path '$ExplicitPath' does not exist."
        }

        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    if ([string]::IsNullOrWhiteSpace($Device)) {
        throw "Created profile device could not be detected. Expected mobile or desktop."
    }

    $deviceFolder = Join-Path $Root $Device
    if (-not (Test-Path -LiteralPath $deviceFolder)) {
        throw "No recording folder exists for device '$Device': $deviceFolder"
    }

    $sessions = @(Get-ChildItem -LiteralPath $deviceFolder -Filter "*.json" -File -Recurse)
    if ($sessions.Count -eq 0) {
        throw "No '$Device' recordings found under '$deviceFolder'."
    }

    $session = $sessions | Get-Random
    return $session.FullName
}

function Stop-ProfileIfNeeded {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return
    }

    $lastError = $null
    foreach ($endpoint in @("profile/stop", "profile/close")) {
        try {
            $response = Invoke-RestMethod -Uri "$ApiUrl/$endpoint/$Id" -Method Get -TimeoutSec 30
            if (-not $response -or -not ($response.PSObject.Properties.Name -contains "code") -or $response.code -eq 0) {
                Write-Host "Closed profile '$Id'." -ForegroundColor Green
                return
            }

            $lastError = $response | ConvertTo-Json -Depth 10 -Compress
        }
        catch {
            $lastError = $_
        }
    }

    throw "Failed to close profile '$Id': $lastError"
}

try {
    try {
        $cleanupCommand = @{
            ApiUrl                = $ApiUrl
            StartupTimeoutSeconds = $StartupTimeoutSeconds
            Tag                   = "random"
        }
        if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
            $cleanupCommand.UndetectablePath = $UndetectablePath
        }

        Write-Host "Cleaning up stale random profiles..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot "delete-undetectable-profiles.ps1") @cleanupCommand
        if (-not $?) {
            throw "Random profile cleanup script failed."
        }
    }
    catch {
        Write-Warning "Could not clean all stale random profiles; continuing: $_"
    }

    $createCommand = @{
        ApiUrl                = $ApiUrl
        StartupTimeoutSeconds = $StartupTimeoutSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
        $createCommand.UndetectablePath = $UndetectablePath
    }

    if ($CreateProfileArgs) {
        foreach ($parameter in (ConvertTo-ParameterHashtable -Arguments $CreateProfileArgs).GetEnumerator()) {
            $createCommand[$parameter.Key] = $parameter.Value
        }
    }

    Write-Host "Creating random profile..." -ForegroundColor Cyan
    $createOutput = & (Join-Path $PSScriptRoot "new-random-undetectable-profile.ps1") @createCommand
    if (-not $?) {
        throw "Profile creation script failed."
    }

    $createResponse = ConvertFrom-ScriptJsonOutput -Output $createOutput
    $profileId = Get-CreatedProfileId -CreateResponse $createResponse
    $profileName = $createResponse.profile_name
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        $profileName = $profileId
    }
    $profileDevice = ConvertTo-DeviceFolderName -Value $createResponse.selected_os
    $playbackSession = Resolve-PlaybackSession -Device $profileDevice -Root $SessionRoot -ExplicitPath $SessionPath

    Write-Host "Opening '$profileName' [$profileId] as $profileDevice." -ForegroundColor Cyan
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
        throw "Profile open script failed."
    }
    $profileStarted = $true

    Write-Host "Playing '$playbackSession'." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "play.ps1") -SessionPath $playbackSession
    $playExitCode = $LASTEXITCODE
    if ($playExitCode -ne 0) {
        $exitCode = $playExitCode
        throw "Playback failed with exit code $playExitCode."
    }
}
catch {
    if ($exitCode -eq 0) {
        $exitCode = 1
    }

    Write-Host "Workflow failed: $_" -ForegroundColor Red
}
finally {
    if ($profileStarted) {
        try {
            Stop-ProfileIfNeeded -Id $profileId
        }
        catch {
            Write-Warning $_
            if ($exitCode -eq 0) { $exitCode = 1 }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($profileId) -and (-not $KeepProfileOnFailure -or $exitCode -eq 0)) {
        try {
            $deleteCommand = @{
                ApiUrl                = $ApiUrl
                StartupTimeoutSeconds = $StartupTimeoutSeconds
                Id                    = $profileId
            }

            if (-not [string]::IsNullOrWhiteSpace($UndetectablePath)) {
                $deleteCommand.UndetectablePath = $UndetectablePath
            }

            & (Join-Path $PSScriptRoot "delete-undetectable-profiles.ps1") @deleteCommand
            if (-not $?) {
                throw "Delete profile script failed."
            }
        }
        catch {
            Write-Warning $_
            if ($exitCode -eq 0) { $exitCode = 1 }
        }
    }

    if (Test-Path -LiteralPath $ProfileStatePath) {
        Remove-Item -LiteralPath $ProfileStatePath -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode