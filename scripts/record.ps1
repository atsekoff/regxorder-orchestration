param (
    [switch]$WithBrowser
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot

. (Join-Path $PSScriptRoot "lib\profile-state.ps1")

function Read-SessionType {
    while ($true) {
        Write-Host ""
        Write-Host "Select the session type:"
        Write-Host "[1] pre-session"
        Write-Host "[2] main-session"
        Write-Host "[3] post-session"
        Write-Host ""

        $typeChoice = Read-Host "Enter choice (1, 2, or 3)"
        switch ($typeChoice) {
            "1" { return "pre-sessions" }
            "2" { return "main-sessions" }
            "3" { return "post-sessions" }
            default {
                Write-Host "[Error] Invalid choice! Please select 1, 2, or 3." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host "[Error] $ErrorMessage" -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
}

function Read-Device {
    while ($true) {
        Write-Host ""
        Write-Host "Select the profile device:"
        Write-Host "[1] desktop"
        Write-Host "[2] mobile"
        Write-Host ""

        $deviceChoice = Read-Host "Enter choice (1 or 2)"
        switch ($deviceChoice) {
            "1" { return "desktop" }
            "2" { return "mobile" }
            default {
                Write-Host "[Error] Invalid choice! Please select 1 or 2." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}

if ($WithBrowser) {
    & (Join-Path $PSScriptRoot "open-undetectable.ps1")
    if (-not $?) {
        exit 1
    }
}

Clear-Host
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "              REGXORDER RECORDING SESSION          " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

$sessionType = Read-SessionType
$sessionName = Read-RequiredValue -Prompt "Enter session name (e.g. google_search)" -ErrorMessage "Session name cannot be empty!"

$resolveArgs = @{
    SessionType = $sessionType
    SessionName = $sessionName
}

if ($WithBrowser) {
    $sessionResolution = Get-OrchestrationProfileResolution -StatePath (Join-Path $env:TEMP "orchestration-undetectable-profile.txt")
    if (-not [string]::IsNullOrWhiteSpace($sessionResolution)) {
        Write-Host "Detected recording resolution: $sessionResolution" -ForegroundColor Green
        $resolveArgs.Resolution = $sessionResolution
    }
    else {
        $sessionResolution = Read-RequiredValue -Prompt "Enter recording resolution (e.g. 1920x1080)" -ErrorMessage "Resolution cannot be empty!"
        $resolveArgs.Resolution = $sessionResolution
    }
}
else {
    $resolveArgs.Device = Read-Device
    $sessionResolution = Read-RequiredValue -Prompt "Enter recording resolution (e.g. 1920x1080)" -ErrorMessage "Resolution cannot be empty!"
    $resolveArgs.Resolution = $sessionResolution
}

try {
    $outputPath = & (Join-Path $PSScriptRoot "resolve-recording-output-path.ps1") @resolveArgs
}
catch {
    Write-Host "[Error] $_" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($outputPath)) {
    Write-Host "[Error] Could not create a recording path." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Target path: $outputPath"
Write-Host ""

if ($WithBrowser) {
    & (Join-Path $PSScriptRoot "run-record-with-focus.ps1") -OutputPath $outputPath -Title $sessionName
    exit $LASTEXITCODE
}

& (Join-Path $repoRoot "regxorder-cli.exe") @("record", "--output", $outputPath, "--title", $sessionName, "--start-hotkey", "ctrl+shift+f9", "--stop-hotkey", "ctrl+shift+f10")
exit $LASTEXITCODE