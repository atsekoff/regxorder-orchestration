param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("pre-sessions", "main-sessions", "post-sessions")]
    [string]$SessionType,

    [Parameter(Mandatory = $true)]
    [string]$SessionName,

    [Parameter(Mandatory = $false)]
    [string]$Resolution,

    [Parameter(Mandatory = $false)]
    [ValidateSet("desktop", "mobile")]
    [string]$Device,

    [string]$ProfileStatePath = (Join-Path $env:TEMP "orchestration-undetectable-profile.txt")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\resolution.ps1")
. (Join-Path $PSScriptRoot "lib\device.ps1")
. (Join-Path $PSScriptRoot "lib\profile-state.ps1")

$resolutionWasProvided = $PSBoundParameters.ContainsKey("Resolution") -and -not [string]::IsNullOrWhiteSpace($Resolution)
$resolutionFolder = ConvertTo-ResolutionFolderName -Value $Resolution
$deviceFolder = ConvertTo-DeviceFolderName -Value $Device

if ($resolutionWasProvided -and [string]::IsNullOrWhiteSpace($resolutionFolder)) {
    throw "Invalid recording resolution '$Resolution'. Use widthxheight format, for example 1920x1080."
}

if (-not $resolutionWasProvided -and [string]::IsNullOrWhiteSpace($resolutionFolder)) {
    $resolutionFolder = Get-OrchestrationProfileResolution -StatePath $ProfileStatePath
}

if ([string]::IsNullOrWhiteSpace($resolutionFolder)) {
    throw "No recording resolution is available. Launch an Undetectable profile first or enter a resolution like 1920x1080."
}

if ([string]::IsNullOrWhiteSpace($deviceFolder)) {
    $deviceFolder = Get-OrchestrationProfileDevice -StatePath $ProfileStatePath
}

if ([string]::IsNullOrWhiteSpace($deviceFolder)) {
    $deviceFolder = "desktop"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetDirectory = Join-Path (Join-Path (Join-Path $repoRoot $SessionType) $deviceFolder) $resolutionFolder
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

Write-Output ".\$SessionType\$deviceFolder\$resolutionFolder\$SessionName.json"